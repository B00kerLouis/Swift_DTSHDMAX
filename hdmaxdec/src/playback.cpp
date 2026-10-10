// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "internal.hpp"
#include <chrono>
#include <memory>
#include <thread>
#if defined(__APPLE__)
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <condition_variable>
#include <mutex>
struct hdmaxdec_player {
  hdmaxdec_device_info info{};
  AudioQueueRef queue = nullptr;
  std::mutex mutex;
  std::condition_variable available;
  std::vector<AudioQueueBufferRef> free;
  size_t queued = 0;
  bool started = false;
  ~hdmaxdec_player() {
    if (queue)
      AudioQueueDispose(queue, true);
  }
};
namespace {
hdmaxdec_speaker fromApple(AudioChannelLabel label) {
  switch (label) {
  case 1:
    return HD_FL;
  case 2:
    return HD_FR;
  case 3:
  case 42:
    return HD_FC;
  case 4:
    return HD_LFE;
  case 5:
  case 10:
  case 55:
    return HD_SL;
  case 6:
  case 11:
  case 56:
    return HD_SR;
  case 7:
    return HD_FLC;
  case 8:
    return HD_FRC;
  case 9:
    return HD_BC;
  case 12:
    return HD_TC;
  case 13:
    return HD_TFL;
  case 14:
    return HD_TFC;
  case 15:
    return HD_TFR;
  case 16:
  case 52:
    return HD_TBL;
  case 17:
  case 53:
    return HD_TBC;
  case 18:
  case 54:
    return HD_TBR;
  case 33:
  case 63:
    return HD_BL;
  case 34:
  case 64:
    return HD_BR;
  case 35:
    return HD_WL;
  case 36:
    return HD_WR;
  case 49:
    return HD_TSL;
  case 51:
    return HD_TSR;
  default:
    return HD_UNKNOWN;
  }
}
AudioChannelLabel toApple(hdmaxdec_speaker s) {
  switch (s) {
  case HD_SL:
    return 55;
  case HD_SR:
    return 56;
  case HD_BL:
    return 33;
  case HD_BR:
    return 34;
  case HD_WL:
    return 35;
  case HD_WR:
    return 36;
  case HD_TSL:
    return 49;
  case HD_TSR:
    return 51;
  default:
    return s <= 17 ? AudioChannelLabel(s + 1) : kAudioChannelLabel_Unknown;
  }
}
bool property(
    AudioObjectID device, AudioObjectPropertySelector selector, void *p,
    UInt32 &size,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal) {
  AudioObjectPropertyAddress address{selector, scope,
                                     kAudioObjectPropertyElementMain};
  return AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, p) ==
         noErr;
}
AudioDeviceID appleDevice(const char *id) {
  AudioDeviceID device = kAudioObjectUnknown;
  if (!id || !*id) {
    UInt32 size = sizeof(device);
    if (!property(kAudioObjectSystemObject,
                  kAudioHardwarePropertyDefaultOutputDevice, &device, size))
      return kAudioObjectUnknown;
    return device;
  }
  CFStringRef uid =
      CFStringCreateWithCString(nullptr, id, kCFStringEncodingUTF8);
  if (!uid)
    return kAudioObjectUnknown;
  AudioValueTranslation value{&uid, sizeof(uid), &device, sizeof(device)};
  UInt32 size = sizeof(value);
  bool ok = property(kAudioObjectSystemObject,
                     kAudioHardwarePropertyTranslateUIDToDevice, &value, size);
  CFRelease(uid);
  return ok ? device : kAudioObjectUnknown;
}
void stringProperty(AudioDeviceID d, AudioObjectPropertySelector selector,
                    char *out, size_t capacity) {
  CFStringRef s = nullptr;
  UInt32 size = sizeof(s);
  if (property(d, selector, &s, size) && s) {
    CFStringGetCString(s, out, CFIndex(capacity), kCFStringEncodingUTF8);
    CFRelease(s);
  }
}
int queryApple(const char *id, hdmaxdec_device_info *out) {
  *out = {};
  AudioDeviceID d = appleDevice(id);
  if (d == kAudioObjectUnknown)
    return HD_DEVICE;
  stringProperty(d, kAudioDevicePropertyDeviceUID, out->id, sizeof(out->id));
  stringProperty(d, kAudioObjectPropertyName, out->name, sizeof(out->name));
  Float64 rate = 0;
  UInt32 size = sizeof(rate);
  if (property(d, kAudioDevicePropertyNominalSampleRate, &rate, size))
    out->sample_rate = uint32_t(rate);
  AudioObjectPropertyAddress address{kAudioDevicePropertyPreferredChannelLayout,
                                     kAudioDevicePropertyScopeOutput,
                                     kAudioObjectPropertyElementMain};
  size = 0;
  std::vector<uint8_t> bytes;
  if (AudioObjectGetPropertyDataSize(d, &address, 0, nullptr, &size) == noErr &&
      size >= offsetof(AudioChannelLayout, mChannelDescriptions) &&
      size < 65536) {
    bytes.resize(size);
    if (AudioObjectGetPropertyData(d, &address, 0, nullptr, &size,
                                   bytes.data()) != noErr)
      bytes.clear();
  }
  if (!bytes.empty()) {
    auto *l = reinterpret_cast<AudioChannelLayout *>(bytes.data());
    if (l->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions) {
      AudioFormatPropertyID selector =
          l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
              ? kAudioFormatProperty_ChannelLayoutForBitmap
              : kAudioFormatProperty_ChannelLayoutForTag;
      UInt32 spec =
          l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap
              ? l->mChannelBitmap
              : l->mChannelLayoutTag;
      UInt32 expanded = 0;
      if (AudioFormatGetPropertyInfo(selector, sizeof(spec), &spec,
                                     &expanded) == noErr &&
          expanded < 65536) {
        std::vector<uint8_t> b(expanded);
        if (AudioFormatGetProperty(selector, sizeof(spec), &spec, &expanded,
                                   b.data()) == noErr)
          bytes.swap(b);
      }
    }
    l = reinterpret_cast<AudioChannelLayout *>(bytes.data());
    if (l->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions &&
        l->mNumberChannelDescriptions <= 32 &&
        offsetof(AudioChannelLayout, mChannelDescriptions) +
                l->mNumberChannelDescriptions *
                    sizeof(AudioChannelDescription) <=
            bytes.size()) {
      out->layout.count = l->mNumberChannelDescriptions;
      out->positions_known = 1;
      for (uint32_t c = 0; c < out->layout.count; ++c) {
        out->layout.speakers[c] =
            fromApple(l->mChannelDescriptions[c].mChannelLabel);
        if (out->layout.speakers[c] == HD_UNKNOWN)
          out->positions_known = 0;
      }
    }
  }
  if (!out->layout.count) {
    address.mSelector = kAudioDevicePropertyStreamConfiguration;
    if (AudioObjectGetPropertyDataSize(d, &address, 0, nullptr, &size) !=
            noErr ||
        size > 65536)
      return HD_DEVICE;
    bytes.resize(size);
    if (AudioObjectGetPropertyData(d, &address, 0, nullptr, &size,
                                   bytes.data()) != noErr)
      return HD_DEVICE;
    auto *b = reinterpret_cast<AudioBufferList *>(bytes.data());
    for (UInt32 j = 0; j < b->mNumberBuffers; ++j)
      out->layout.count += b->mBuffers[j].mNumberChannels;
    if (out->layout.count > 32)
      return HD_UNSUPPORTED;
    std::fill(out->layout.speakers, out->layout.speakers + out->layout.count,
              HD_UNKNOWN);
  }
  if (out->layout.count == 2 && !out->positions_known) {
    out->layout.speakers[0] = HD_FL;
    out->layout.speakers[1] = HD_FR;
    out->positions_known = 1;
  }
  return out->layout.count ? HD_OK : HD_DEVICE;
}
void completed(void *ctx, AudioQueueRef, AudioQueueBufferRef buffer) {
  auto *p = static_cast<hdmaxdec_player *>(ctx);
  std::lock_guard<std::mutex> lock(p->mutex);
  p->free.push_back(buffer);
  if (p->queued)
    --p->queued;
  p->available.notify_all();
}
} // namespace
#elif defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <audioclient.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <initguid.h>
#include <propkeydef.h>
#include <functiondiscoverykeys_devpkey.h>
struct hdmaxdec_player {
  hdmaxdec_device_info info{};
  IMMDeviceEnumerator *enumerator = nullptr;
  IMMDevice *device = nullptr;
  IAudioClient *client = nullptr;
  IAudioRenderClient *render = nullptr;
  UINT32 frames = 0;
  bool com = false, started = false;
  DWORD thread = GetCurrentThreadId();
  ~hdmaxdec_player() {
    if (client && started)
      client->Stop();
    if (render)
      render->Release();
    if (client)
      client->Release();
    if (device)
      device->Release();
    if (enumerator)
      enumerator->Release();
    if (com)
      CoUninitialize();
  }
};
namespace {
bool windowsEndpoint(hdmaxdec_player &p, const char *id) {
  HRESULT status = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  p.com = SUCCEEDED(status);
  if (FAILED(status) && status != RPC_E_CHANGED_MODE)
    return false;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                              __uuidof(IMMDeviceEnumerator),
                              reinterpret_cast<void **>(&p.enumerator))))
    return false;
  if (id && *id) {
    int count = MultiByteToWideChar(CP_UTF8, 0, id, -1, nullptr, 0);
    if (count <= 0)
      return false;
    std::vector<wchar_t> wide(size_t(count), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, id, -1, wide.data(), count);
    status = p.enumerator->GetDevice(wide.data(), &p.device);
  } else
    status =
        p.enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &p.device);
  if (FAILED(status) ||
      FAILED(p.device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                                reinterpret_cast<void **>(&p.client))))
    return false;
  LPWSTR uid = nullptr;
  if (SUCCEEDED(p.device->GetId(&uid))) {
    WideCharToMultiByte(CP_UTF8, 0, uid, -1, p.info.id, sizeof(p.info.id),
                        nullptr, nullptr);
    CoTaskMemFree(uid);
  }
  std::strncpy(p.info.name, "WASAPI output", sizeof(p.info.name) - 1);
  IPropertyStore *props = nullptr;
  if (SUCCEEDED(p.device->OpenPropertyStore(STGM_READ, &props))) {
    PROPVARIANT v;
    PropVariantInit(&v);
    if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &v)) &&
        v.vt == VT_LPWSTR)
      WideCharToMultiByte(CP_UTF8, 0, v.pwszVal, -1, p.info.name,
                          sizeof(p.info.name), nullptr, nullptr);
    PropVariantClear(&v);
    props->Release();
  }
  WAVEFORMATEX *format = nullptr;
  if (FAILED(p.client->GetMixFormat(&format)))
    return false;
  p.info.sample_rate = format->nSamplesPerSec;
  p.info.layout.count = format->nChannels;
  DWORD mask = 0;
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE && format->cbSize >= 22)
    mask = reinterpret_cast<WAVEFORMATEXTENSIBLE *>(format)->dwChannelMask;
  CoTaskMemFree(format);
  if (!p.info.layout.count || p.info.layout.count > 32)
    return false;
  uint32_t c = 0;
  for (int b = 0; b < 18; ++b)
    if (mask & (1u << b) && c < p.info.layout.count)
      p.info.layout.speakers[c++] = hdmaxdec_speaker(b);
  p.info.positions_known = c == p.info.layout.count;
  if (!p.info.positions_known) {
    std::fill(p.info.layout.speakers,
              p.info.layout.speakers + p.info.layout.count, HD_UNKNOWN);
    if (p.info.layout.count == 2) {
      p.info.layout.speakers[0] = HD_FL;
      p.info.layout.speakers[1] = HD_FR;
      p.info.positions_known = 1;
    }
  }
  return true;
}
} // namespace
#elif defined(__linux__)
#include <alsa/asoundlib.h>
struct hdmaxdec_player {
  hdmaxdec_device_info info{};
  snd_pcm_t *pcm = nullptr;
  ~hdmaxdec_player() {
    if (pcm)
      snd_pcm_close(pcm);
  }
};
namespace {
hdmaxdec_speaker fromAlsa(unsigned v) {
  switch (v & SND_CHMAP_POSITION_MASK) {
  case SND_CHMAP_FL:
    return HD_FL;
  case SND_CHMAP_FR:
    return HD_FR;
  case SND_CHMAP_FC:
    return HD_FC;
  case SND_CHMAP_LFE:
    return HD_LFE;
  case SND_CHMAP_RL:
    return HD_BL;
  case SND_CHMAP_RR:
    return HD_BR;
  case SND_CHMAP_SL:
    return HD_SL;
  case SND_CHMAP_SR:
    return HD_SR;
  case SND_CHMAP_FLC:
    return HD_FLC;
  case SND_CHMAP_FRC:
    return HD_FRC;
  case SND_CHMAP_RC:
    return HD_BC;
  case SND_CHMAP_FLW:
    return HD_WL;
  case SND_CHMAP_FRW:
    return HD_WR;
  case SND_CHMAP_TFL:
    return HD_TFL;
  case SND_CHMAP_TFR:
    return HD_TFR;
  case SND_CHMAP_TFC:
    return HD_TFC;
  case SND_CHMAP_TRL:
    return HD_TBL;
  case SND_CHMAP_TRR:
    return HD_TBR;
  case SND_CHMAP_TRC:
    return HD_TBC;
  case SND_CHMAP_TSL:
    return HD_TSL;
  case SND_CHMAP_TSR:
    return HD_TSR;
  case SND_CHMAP_TC:
    return HD_TC;
  default:
    return HD_UNKNOWN;
  }
}
unsigned toAlsa(hdmaxdec_speaker s) {
  for (unsigned v = SND_CHMAP_FL; v <= SND_CHMAP_BRC; ++v)
    if (fromAlsa(v) == s)
      return v;
  return SND_CHMAP_UNKNOWN;
}
bool alsaEndpoint(hdmaxdec_player &p, const char *id) {
  const char *name = id && *id ? id : "default";
  if (snd_pcm_open(&p.pcm, name, SND_PCM_STREAM_PLAYBACK, 0) < 0)
    return false;
  std::strncpy(p.info.id, name, sizeof(p.info.id) - 1);
  std::strncpy(p.info.name, snd_pcm_name(p.pcm), sizeof(p.info.name) - 1);
  p.info.sample_rate = 48000;
  snd_pcm_chmap_t *map = snd_pcm_get_chmap(p.pcm);
  snd_pcm_chmap_query_t **maps = nullptr;
  if (!map) {
    maps = snd_pcm_query_chmaps(p.pcm);
    if (maps)
      for (size_t j = 0; maps[j]; ++j)
        if (maps[j]->map.channels <= 32 &&
            (!map || maps[j]->map.channels > map->channels))
          map = &maps[j]->map;
  }
  if (map && map->channels <= 32) {
    p.info.layout.count = map->channels;
    p.info.positions_known = 1;
    for (uint32_t c = 0; c < map->channels; ++c) {
      p.info.layout.speakers[c] = fromAlsa(map->pos[c]);
      if (p.info.layout.speakers[c] == HD_UNKNOWN)
        p.info.positions_known = 0;
    }
  }
  if (maps)
    snd_pcm_free_chmaps(maps);
  else
    std::free(map);
  if (!p.info.layout.count) {
    snd_pcm_hw_params_t *params = nullptr;
    snd_pcm_hw_params_alloca(&params);
    unsigned min = 0, max = 0;
    if (snd_pcm_hw_params_any(p.pcm, params) < 0 ||
        snd_pcm_hw_params_get_channels_min(params, &min) < 0 ||
        snd_pcm_hw_params_get_channels_max(params, &max) < 0)
      return false;
    // Flexible virtual PCM capabilities do not identify the server's speakers.
    p.info.layout.count = min == max && max <= 32 ? max : 0;
    std::fill(p.info.layout.speakers,
              p.info.layout.speakers + p.info.layout.count, HD_UNKNOWN);
  }
  if (p.info.layout.count == 2 && !p.info.positions_known) {
    p.info.layout.speakers[0] = HD_FL;
    p.info.layout.speakers[1] = HD_FR;
    p.info.positions_known = 1;
  }
  return true;
}
} // namespace
#else
struct hdmaxdec_player {
  hdmaxdec_device_info info{};
};
#endif
extern "C" {
int hdmaxdec_device_query(const char *id, hdmaxdec_device_info *out) {
  if (!out)
    return HD_INVALID;
  try {
#if defined(__APPLE__)
    return queryApple(id, out);
#elif defined(_WIN32)
    hdmaxdec_player p;
    if (!windowsEndpoint(p, id))
      return HD_DEVICE;
    *out = p.info;
    return HD_OK;
#elif defined(__linux__)
    hdmaxdec_player p;
    if (!alsaEndpoint(p, id))
      return HD_DEVICE;
    *out = p.info;
    return HD_OK;
#else
    (void)id;
    return HD_UNSUPPORTED;
#endif
  } catch (...) {
    return HD_MEMORY;
  }
}
hdmaxdec_player *hdmaxdec_player_open(const char *id,
                                      const hdmaxdec_layout *layout) {
  try {
    auto p = std::make_unique<hdmaxdec_player>();
#if defined(__APPLE__)
    if (queryApple(id, &p->info))
      return nullptr;
#elif defined(_WIN32)
    if (!windowsEndpoint(*p, id))
      return nullptr;
#elif defined(__linux__)
    if (!alsaEndpoint(*p, id))
      return nullptr;
#else
    (void)id;
    (void)layout;
    return nullptr;
#endif
    if (layout) {
      float validation[32 * 32];
      if (hdmaxdec_mix_matrix(layout, layout, validation))
        return nullptr;
      if (p->info.layout.count && layout->count != p->info.layout.count)
        return nullptr;
      if (p->info.positions_known) {
        for (uint32_t c = 0; c < layout->count; ++c)
          if (std::find(p->info.layout.speakers,
                        p->info.layout.speakers + p->info.layout.count,
                        layout->speakers[c]) ==
              p->info.layout.speakers + p->info.layout.count)
            return nullptr;
      } else
        p->info.layout = *layout;
      p->info.positions_known = 1;
    }
    if (!p->info.positions_known)
      return nullptr;
    float matrix[32 * 32];
    if (hdmaxdec_mix_matrix(&p->info.layout, &p->info.layout, matrix))
      return nullptr;
#if defined(__APPLE__)
    AudioStreamBasicDescription format{};
    format.mSampleRate = 48000;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mChannelsPerFrame = p->info.layout.count;
    format.mBitsPerChannel = 32;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = format.mBytesPerPacket =
        4 * format.mChannelsPerFrame;
    if (AudioQueueNewOutput(&format, completed, p.get(), nullptr, nullptr, 0,
                            &p->queue))
      return nullptr;
    CFStringRef uid =
        CFStringCreateWithCString(nullptr, p->info.id, kCFStringEncodingUTF8);
    if (!uid)
      return nullptr;
    OSStatus status = AudioQueueSetProperty(
        p->queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
    CFRelease(uid);
    if (status)
      return nullptr;
    size_t count = p->info.layout.count;
    std::vector<uint8_t> bytes(
        offsetof(AudioChannelLayout, mChannelDescriptions) +
        count * sizeof(AudioChannelDescription));
    auto *l = reinterpret_cast<AudioChannelLayout *>(bytes.data());
    l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    l->mNumberChannelDescriptions = UInt32(count);
    for (size_t c = 0; c < count; ++c)
      l->mChannelDescriptions[c].mChannelLabel =
          toApple(p->info.layout.speakers[c]);
    if (AudioQueueSetProperty(p->queue, kAudioQueueProperty_ChannelLayout, l,
                              UInt32(bytes.size())))
      return nullptr;
    for (int j = 0; j < 3; ++j) {
      AudioQueueBufferRef b = nullptr;
      if (AudioQueueAllocateBuffer(p->queue, 65536 * format.mBytesPerFrame, &b))
        return nullptr;
      p->free.push_back(b);
    }
#elif defined(_WIN32)
    WAVEFORMATEXTENSIBLE f{};
    f.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    f.Format.nChannels = WORD(p->info.layout.count);
    f.Format.nSamplesPerSec = 48000;
    f.Format.wBitsPerSample = 32;
    f.Format.nBlockAlign = WORD(f.Format.nChannels * 4);
    f.Format.nAvgBytesPerSec = f.Format.nBlockAlign * 48000;
    f.Format.cbSize = 22;
    f.Samples.wValidBitsPerSample = 32;
    f.SubFormat = GUID{3, 0, 0x0010, {0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71}};
    bool representable = true;
    for (uint32_t c = 0; c < p->info.layout.count; ++c) {
      int s = p->info.layout.speakers[c];
      if (s >= 0 && s < 18)
        f.dwChannelMask |= 1u << s;
      else
        representable = false;
    }
    if (!representable)
      f.dwChannelMask = 0;
    if (FAILED(
            p->client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                  AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                      AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                  1000000, 0, &f.Format, nullptr)) ||
        FAILED(p->client->GetBufferSize(&p->frames)) ||
        FAILED(p->client->GetService(__uuidof(IAudioRenderClient),
                                     reinterpret_cast<void **>(&p->render))))
      return nullptr;
#elif defined(__linux__)
    if (snd_pcm_set_params(p->pcm, SND_PCM_FORMAT_FLOAT,
                           SND_PCM_ACCESS_RW_INTERLEAVED, p->info.layout.count,
                           48000, 1, 100000) < 0)
      return nullptr;
    std::vector<unsigned> bytes(1 + p->info.layout.count);
    auto *m = reinterpret_cast<snd_pcm_chmap_t *>(bytes.data());
    m->channels = p->info.layout.count;
    for (uint32_t c = 0; c < m->channels; ++c)
      m->pos[c] = toAlsa(p->info.layout.speakers[c]);
    int status = snd_pcm_set_chmap(p->pcm, m);
    if (status < 0 && layout == nullptr) {
      snd_pcm_chmap_t *actual = snd_pcm_get_chmap(p->pcm);
      bool match = actual && actual->channels == m->channels;
      if (match)
        for (uint32_t c = 0; c < m->channels; ++c)
          match &= fromAlsa(actual->pos[c]) == p->info.layout.speakers[c];
      std::free(actual);
      if (!match)
        return nullptr;
    }
#endif
    return p.release();
  } catch (...) {
    return nullptr;
  }
}
const hdmaxdec_device_info *hdmaxdec_player_info(const hdmaxdec_player *p) {
  return p ? &p->info : nullptr;
}
int hdmaxdec_player_write(hdmaxdec_player *p, const hdmaxdec_frame *f,
                          float gain) {
  if (!p || !f || f->sample_rate != 48000)
    return HD_INVALID;
  try {
    std::vector<float> samples(size_t(f->sample_count) * p->info.layout.count);
    int status = hdmaxdec_render_float(f, &p->info.layout, gain, samples.data(),
                                       samples.size());
    if (status)
      return status;
#if defined(__APPLE__)
    std::unique_lock<std::mutex> lock(p->mutex);
    if (!p->available.wait_for(lock, std::chrono::seconds(3),
                               [p] { return !p->free.empty(); }))
      return HD_DEVICE;
    AudioQueueBufferRef b = p->free.back();
    p->free.pop_back();
    ++p->queued;
    lock.unlock();
    std::memcpy(b->mAudioData, samples.data(), samples.size() * sizeof(float));
    b->mAudioDataByteSize = UInt32(samples.size() * sizeof(float));
    if (AudioQueueEnqueueBuffer(p->queue, b, 0, nullptr))
      return HD_DEVICE;
    if (!p->started) {
      if (AudioQueueStart(p->queue, nullptr))
        return HD_DEVICE;
      p->started = true;
    }
#elif defined(_WIN32)
    if (p->thread != GetCurrentThreadId())
      return HD_INVALID;
    size_t offset = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    while (offset < f->sample_count) {
      UINT32 padding = 0;
      if (FAILED(p->client->GetCurrentPadding(&padding)) || padding > p->frames)
        return HD_DEVICE;
      UINT32 count = UINT32(
          std::min<size_t>(p->frames - padding, f->sample_count - offset));
      if (!count) {
        if (std::chrono::steady_clock::now() > deadline)
          return HD_DEVICE;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        continue;
      }
      BYTE *buffer = nullptr;
      if (FAILED(p->render->GetBuffer(count, &buffer)))
        return HD_DEVICE;
      std::memcpy(buffer, samples.data() + offset * p->info.layout.count,
                  size_t(count) * p->info.layout.count * sizeof(float));
      if (FAILED(p->render->ReleaseBuffer(count, 0)))
        return HD_DEVICE;
      if (!p->started) {
        if (FAILED(p->client->Start()))
          return HD_DEVICE;
        p->started = true;
      }
      offset += count;
      deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    }
#elif defined(__linux__)
    size_t offset = 0;
    while (offset < f->sample_count) {
      snd_pcm_sframes_t count =
          snd_pcm_writei(p->pcm, samples.data() + offset * p->info.layout.count,
                         f->sample_count - offset);
      if (count == -EPIPE) {
        if (snd_pcm_prepare(p->pcm) < 0)
          return HD_DEVICE;
        continue;
      }
      if (count <= 0)
        return HD_DEVICE;
      offset += size_t(count);
    }
#else
    return HD_UNSUPPORTED;
#endif
    return HD_OK;
  } catch (...) {
    return HD_MEMORY;
  }
}
int hdmaxdec_player_drain(hdmaxdec_player *p) {
  if (!p)
    return HD_INVALID;
#if defined(__APPLE__)
  std::unique_lock<std::mutex> lock(p->mutex);
  return p->available.wait_for(lock, std::chrono::seconds(5),
                               [p] { return !p->queued; })
             ? HD_OK
             : HD_DEVICE;
#elif defined(_WIN32)
  if (p->thread != GetCurrentThreadId())
    return HD_INVALID;
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while (true) {
    UINT32 padding = 0;
    if (FAILED(p->client->GetCurrentPadding(&padding)))
      return HD_DEVICE;
    if (!padding)
      return HD_OK;
    if (std::chrono::steady_clock::now() > deadline)
      return HD_DEVICE;
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
#elif defined(__linux__)
  return snd_pcm_drain(p->pcm) >= 0 ? HD_OK : HD_DEVICE;
#else
  return HD_UNSUPPORTED;
#endif
}
void hdmaxdec_player_close(hdmaxdec_player *p) { delete p; }
}
