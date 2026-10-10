// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "hdmaxdec.h"
#ifdef __APPLE__
#include "macos/qc_player.h"
#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;

#endif
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif
#ifdef __APPLE__
int launchQC(int argc, char **argv) {
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::vector<char> path(size);
  if (_NSGetExecutablePath(path.data(), &size))
    return 1;
  std::filesystem::path executable = std::filesystem::canonical(path.data());
  if (executable.string().find(".app/Contents/MacOS/") != std::string::npos)
    return hdmaxdec_qc_main(argc, argv);
  auto host = executable.parent_path() / "hdmaxdec QC.app" / "Contents" /
              "MacOS" / "hdmaxdec";
  if (!std::filesystem::exists(host))
    return hdmaxdec_qc_main(argc, argv);
  std::vector<char *> arguments;
  std::string hostPath = host.string();
  arguments.push_back(hostPath.data());
  for (int i = 1; i < argc; ++i)
    arguments.push_back(argv[i]);
  arguments.push_back(nullptr);
  pid_t child = 0;
  int status = posix_spawn(&child, hostPath.c_str(), nullptr, nullptr,
                           arguments.data(), environ);
  if (status)
    return status;
  int result = 0;
  while (waitpid(child, &result, 0) < 0 && errno == EINTR) {
  }
  return WIFEXITED(result) ? WEXITSTATUS(result) : 1;
}
#endif
namespace {
struct FileCloser {
  void operator()(FILE *f) const {
    if (f)
      std::fclose(f);
  }
};
void check(bool ok, const char *message) {
  if (!ok)
    throw std::runtime_error(message);
}
void put(FILE *f, const void *p, size_t n) {
  check(std::fwrite(p, 1, n, f) == n, "output write failed");
}
void u16(FILE *f, uint16_t v) {
  uint8_t b[] = {uint8_t(v), uint8_t(v >> 8)};
  put(f, b, 2);
}
void u32(FILE *f, uint32_t v) {
  uint8_t b[] = {uint8_t(v), uint8_t(v >> 8), uint8_t(v >> 16),
                 uint8_t(v >> 24)};
  put(f, b, 4);
}
void u64(FILE *f, uint64_t v) {
  u32(f, uint32_t(v));
  u32(f, uint32_t(v >> 32));
}
void seek(FILE *f, int64_t at) {
#ifdef _WIN32
  check(!_fseeki64(f, at, SEEK_SET), "output seek failed");
#else
  check(!fseeko(f, off_t(at), SEEK_SET), "output seek failed");
#endif
}
void waveHeader(FILE *f, const hdmaxdec_layout &layout, uint64_t samples) {
  uint32_t mask = 0;
  for (uint32_t c = 0; c < layout.count; ++c) {
    int s = layout.speakers[c];
    check(s >= 0 && s < 18,
          "WAVE cannot label this speaker position; use --format f32 with an "
          "explicit layout or the C API");
    mask |= 1u << s;
  }
  uint64_t bytes = samples * layout.count * 3;
  put(f, "RF64", 4);
  u32(f, UINT32_MAX);
  put(f, "WAVEds64", 8);
  u32(f, 28);
  u64(f, 96 + bytes + (bytes & 1));
  u64(f, bytes);
  u64(f, samples);
  u32(f, 0);
  put(f, "fmt ", 4);
  u32(f, 40);
  u16(f, 0xfffe);
  u16(f, uint16_t(layout.count));
  u32(f, 48000);
  u32(f, 48000 * layout.count * 3);
  u16(f, uint16_t(layout.count * 3));
  u16(f, 24);
  u16(f, 22);
  u16(f, 24);
  u32(f, mask);
  const uint8_t guid[] = {1,    0, 0, 0,    0, 0,    0x10, 0,
                          0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71};
  put(f, guid, 16);
  put(f, "data", 4);
  u32(f, UINT32_MAX);
}
void describe(const hdmaxdec_layout &l) {
  for (uint32_t c = 0; c < l.count; ++c)
    std::fprintf(stderr, "%s%s", c ? "," : "",
                 hdmaxdec_speaker_name(l.speakers[c]));
}
struct Stats {
  double square = 0, peak = 0, jump = 0;
  float previous = 0;
  uint64_t count = 0, clipped = 0, fullScale = 0;
  void add(float v, bool wasClipped) {
    double a = std::abs(double(v));
    peak = std::max(peak, a);
    if (count)
      jump = std::max(jump, std::abs(double(v) - previous));
    previous = v;
    square += double(v) * v;
    ++count;
    if (wasClipped)
      ++clipped;
    if (a >= 8388607.0 / 8388608)
      ++fullScale;
  }
};
void usage() {
  std::puts(
      "hdmaxdec devices [--device ID]\n"
      "hdmaxdec --play [INPUT] [--layout LAYOUT] [--device ID] (macOS QC GUI)\n"
      "hdmaxdec export-pcm INPUT OUTPUT [--format wav|s24|s32|f32] [--layout "
      "native|LAYOUT]\n"
      "hdmaxdec decode INPUT OUTPUT [--layout "
      "native|2.0|5.1|7.1|5.1.2|5.1.4|7.1.2|7.1.4|7.1.5|7.1.6|9.1.6] "
      "[--format wav|f32] [--gain VALUE] [--seek SAMPLE]\n"
      "hdmaxdec play INPUT [--device ID] [--layout LAYOUT] [--gain "
      "VALUE] [--seek SAMPLE]\n"
      "Playback uses the endpoint's reported order. --layout overrides "
      "an unknown device map with the same channel count.\n"
      "f32 output is little endian interleaved PCM; speaker order is "
      "printed to stderr.\n"
      "Named layouts with two heights use TFL/TFR. Native output "
      "preserves all decoded feeds.\n"
      "Decode/play stream in bounded frames; no external codec process "
      "is used.");
}
} // namespace
int runMain(int argc, char **argv) {
  try {
    for (int i = 1; i < argc; ++i)
      if (!std::strcmp(argv[i], "--play")) {
#ifdef __APPLE__
        return launchQC(argc, argv);
#else
        throw std::runtime_error(
            "--play QC GUI requires macOS; use play for CLI playback");
#endif
      }
    if (argc < 2 || !std::strcmp(argv[1], "--help")) {
#ifdef __APPLE__
      if (argc < 2) {
        uint32_t n = 0;
        _NSGetExecutablePath(nullptr, &n);
        std::vector<char> p(n);
        _NSGetExecutablePath(p.data(), &n);
        if (std::string(p.data()).find(".app/Contents/MacOS/") !=
            std::string::npos)
          return hdmaxdec_qc_main(argc, argv);
      }
#endif
      usage();
      return 0;
    }
    if (!std::strcmp(argv[1], "--version")) {
      std::puts(hdmaxdec_version());
      return 0;
    }
    std::string command = argv[1], layoutName = "native", format = "wav",
                device;
    float requestedGain = 1;
    uint64_t seekSample = 0;
    bool explicitGain = false;
    std::vector<std::string> args;
    for (int i = 2; i < argc; ++i) {
      std::string a = argv[i];
      if (a.rfind("--", 0) == 0) {
        check(i + 1 < argc, "option requires a value");
        std::string value = argv[++i];
        if (a == "--layout")
          layoutName = value;
        else if (a == "--format")
          format = value;
        else if (a == "--device")
          device = value;
        else if (a == "--gain") {
          size_t used = 0;
          requestedGain = std::stof(value, &used);
          check(used == value.size() && std::isfinite(requestedGain) &&
                    requestedGain >= 0,
                "invalid gain");
          explicitGain = true;
        } else if (a == "--seek") {
          size_t used = 0;
          check(!value.empty() && value[0] != '-', "invalid sample offset");
          seekSample = std::stoull(value, &used);
          check(used == value.size(), "invalid sample offset");
        } else
          throw std::runtime_error("unknown option: " + a);
      } else
        args.push_back(a);
    }
    if (command == "devices") {
      check(args.empty(), "devices takes no file arguments");
      hdmaxdec_device_info info{};
      check(hdmaxdec_device_query(device.empty() ? nullptr : device.c_str(),
                                  &info) == HD_OK,
            "device query failed");
      std::fprintf(stderr,
                   "%s\nID: %s\n%u Hz, %u channels, positions %s: ", info.name,
                   info.id, info.sample_rate, info.layout.count,
                   info.positions_known ? "known" : "unknown");
      describe(info.layout);
      std::fputc('\n', stderr);
      return 0;
    }
    if (command == "export-pcm") {
      check(args.size() == 2, "export-pcm requires INPUT OUTPUT");
      hdmaxdec_export_options options{};
      options.gain = requestedGain;
      if (layoutName != "native")
        check(hdmaxdec_layout_named(layoutName.c_str(), &options.layout) ==
                  HD_OK,
              "unknown PCM export layout");
      if (format == "wav")
        options.format = HD_PCM_WAV24;
      else if (format == "s24")
        options.format = HD_PCM_S24LE;
      else if (format == "s32")
        options.format = HD_PCM_S32LE;
      else if (format == "f32")
        options.format = HD_PCM_F32LE;
      else
        throw std::runtime_error("unsupported PCM export format");
      hdmaxdec_export_result result{};
      check(hdmaxdec_export_pcm(args[0].c_str(), args[1].c_str(), &options,
                                nullptr, nullptr, &result) == HD_OK,
            result.error);
      std::fprintf(stderr,
                   "Exported %llu samples/channel, %u channels, clipped=%llu\n",
                   (unsigned long long)result.samples, result.layout.count,
                   (unsigned long long)result.clipped_samples);
      describe(result.layout);
      std::fputc('\n', stderr);
      return 0;
    }
    bool play = command == "play";
    check(play || command == "decode", "unknown command");
    check(args.size() == (play ? 1 : 2), "invalid file arguments");
    check(play || args[0] != args[1], "input and output must differ");
    check(format == "wav" || format == "f32", "unsupported output format");
    std::unique_ptr<hdmaxdec_file, decltype(&hdmaxdec_file_close)> input(
        hdmaxdec_file_open(args[0].c_str()), hdmaxdec_file_close);
    check(bool(input), "input open/container parse failed");
    if (seekSample)
      check(hdmaxdec_file_seek(input.get(), seekSample) == HD_OK,
            "input seek/decode failed");
    hdmaxdec_frame frame{};
    int status = hdmaxdec_file_read(input.get(), &frame);
    check(status == HD_OK, hdmaxdec_file_error(input.get()));
    hdmaxdec_layout output = frame.layout;
    bool native = layoutName == "native";
    if (!native)
      check(hdmaxdec_layout_named(layoutName.c_str(), &output) == HD_OK,
            "unknown output layout");
    std::unique_ptr<hdmaxdec_player, decltype(&hdmaxdec_player_close)> player(
        nullptr, hdmaxdec_player_close);
    if (play) {
      player.reset(
          hdmaxdec_player_open(device.empty() ? nullptr : device.c_str(),
                               native ? nullptr : &output));
      check(bool(player), "playback open failed; query device and provide its "
                          "exact channel layout when positions are unknown");
      output = hdmaxdec_player_info(player.get())->layout;
    } else if (format == "wav")
      std::sort(output.speakers, output.speakers + output.count);
    std::fprintf(stderr,
                 "%u Hz, %u decoded channels, immersive profile %u; output: ",
                 frame.sample_rate, frame.layout.count, frame.immersive);
    describe(output);
    std::fputc('\n', stderr);
    std::unique_ptr<FILE, FileCloser> file;
    if (!play) {
      check(args[1] != "-" || format == "f32", "stdout supports f32 only");
      if (args[1] == "-") {
#ifdef _WIN32
        _setmode(_fileno(stdout), 0x8000);
#endif
        file.reset(nullptr);
      } else {
        std::error_code error;
        check(!std::filesystem::equivalent(std::filesystem::u8path(args[0]),
                                           std::filesystem::u8path(args[1]),
                                           error),
              "input and output identify the same file");
#ifdef _WIN32
        file.reset(_wfopen(std::filesystem::u8path(args[1]).c_str(), L"wb"));
#else
        file.reset(std::fopen(args[1].c_str(), "wb"));
#endif
        check(bool(file), "output open failed");
      }
      if (format == "wav")
        waveHeader(file.get(), output, 0);
    }
    std::vector<Stats> stats(output.count);
    std::vector<float> pcm;
    uint64_t count = 0;
    float gain = 0;
    hdmaxdec_layout source = frame.layout;
    uint32_t immersive = frame.immersive;
    do {
      check(frame.sample_rate == 48000 && frame.immersive == immersive &&
                frame.layout.count == source.count &&
                std::equal(source.speakers, source.speakers + source.count,
                           frame.layout.speakers),
            "programme format changes unsupported");
      float matrix[32 * 32];
      check(hdmaxdec_frame_mix_matrix(&frame, &output, matrix) == HD_OK,
            "output layout cannot render input");
      float bound = 1;
      for (uint32_t o = 0; o < output.count; ++o) {
        float sum = 0;
        for (uint32_t c = 0; c < frame.layout.count; ++c)
          sum += std::abs(matrix[o * frame.layout.count + c]);
        bound = std::max(bound, sum);
      }
      float currentGain = explicitGain ? requestedGain : requestedGain / bound;
      if (!count) {
        gain = currentGain;
        std::fprintf(stderr, "Master gain %.9g\n", gain);
      } else
        check(currentGain == gain, "mix gain changes unsupported");
      pcm.resize(size_t(frame.sample_count) * output.count);
      check(hdmaxdec_render_float(&frame, &output, gain, pcm.data(),
                                  pcm.size()) == HD_OK,
            "PCM render failed");
      for (uint32_t i = 0; i < frame.sample_count; ++i)
        for (uint32_t c = 0; c < output.count; ++c) {
          bool clipped = false;
          if (double(bound) * gain > 1) {
            double value = 0;
            for (uint32_t sc = 0; sc < frame.layout.count; ++sc)
              value += double(frame.planes[sc][i]) *
                       matrix[c * frame.layout.count + sc];
            value *= gain;
            clipped = value < -8388608 || value > 8388607;
          }
          stats[c].add(pcm[size_t(i) * output.count + c], clipped);
        }
      if (play)
        check(hdmaxdec_player_write(player.get(), &frame, gain) == HD_OK,
              "audio device write/disconnect failed");
      else {
        FILE *dest = file ? file.get() : stdout;
        std::vector<uint8_t> bytes;
        bytes.reserve(pcm.size() * (format == "wav" ? 3 : 4));
        for (float v : pcm) {
          uint32_t raw = 0;
          if (format == "wav") {
            int32_t q = int32_t(std::clamp<int64_t>(
                int64_t(std::llround(double(v) * 8388608)), -8388608, 8388607));
            raw = uint32_t(q);
          } else
            std::memcpy(&raw, &v, 4);
          for (int b = 0; b < (format == "wav" ? 3 : 4); ++b)
            bytes.push_back(uint8_t(raw >> (b * 8)));
        }
        put(dest, bytes.data(), bytes.size());
      }
      count += frame.sample_count;
      status = hdmaxdec_file_read(input.get(), &frame);
    } while (status == HD_OK);
    check(status == HD_NEED_MORE, hdmaxdec_file_error(input.get()));
    if (play)
      check(hdmaxdec_player_drain(player.get()) == HD_OK,
            "audio device drain failed");
    else if (format == "wav") {
      if ((count * output.count * 3) & 1) {
        uint8_t pad = 0;
        put(file.get(), &pad, 1);
      }
      seek(file.get(), 0);
      waveHeader(file.get(), output, count);
    }
    if (file)
      check(!std::fflush(file.get()), "output flush failed");
    else if (!play)
      check(!std::fflush(stdout), "stdout flush failed");
    std::fprintf(stderr, "Decoded %llu samples/channel (%.6f s)\n",
                 (unsigned long long)count, double(count) / 48000);
    for (uint32_t c = 0; c < output.count; ++c) {
      auto &s = stats[c];
      std::fprintf(
          stderr,
          "%s peak=%.9g rms=%.9g max_jump=%.9g clipped=%llu full_scale=%llu\n",
          hdmaxdec_speaker_name(output.speakers[c]), s.peak,
          std::sqrt(s.square / double(s.count)), s.jump,
          (unsigned long long)s.clipped, (unsigned long long)s.fullScale);
    }
    return 0;
  } catch (const std::exception &e) {
    std::fprintf(stderr, "hdmaxdec: %s\n", e.what());
    return 1;
  }
}
#ifdef _WIN32
int wmain(int argc, wchar_t **argv) {
  try {
    std::vector<std::string> utf8;
    utf8.reserve(size_t(argc));
    for (int i = 0; i < argc; ++i) {
      int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i],
                                      -1, nullptr, 0, nullptr, nullptr);
      check(count > 0, "invalid command line Unicode");
      std::string s(size_t(count), '\0');
      WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, s.data(),
                          count, nullptr, nullptr);
      s.resize(size_t(count - 1));
      utf8.push_back(std::move(s));
    }
    std::vector<char *> pointers;
    for (auto &s : utf8)
      pointers.push_back(s.data());
    return runMain(argc, pointers.data());
  } catch (const std::exception &e) {
    std::fprintf(stderr, "hdmaxdec: %s\n", e.what());
    return 1;
  }
}
#else
int main(int argc, char **argv) { return runMain(argc, argv); }
#endif
