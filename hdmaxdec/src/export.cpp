// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "internal.hpp"
#include <atomic>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <memory>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif
namespace {
namespace fs = std::filesystem;
struct Close {
  void operator()(FILE *f) const {
    if (f)
      std::fclose(f);
  }
};
FILE *open(const fs::path &p) {
#ifdef _WIN32
  return _wfopen(p.c_str(), L"wb");
#else
  return std::fopen(p.c_str(), "wb");
#endif
}
void put(FILE *f, const void *p, size_t n) {
  hd::require(std::fwrite(p, 1, n, f) == n, "PCM output write failed", HD_IO);
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
void header(FILE *f, const hdmaxdec_layout &l, uint64_t samples) {
  uint32_t mask = 0;
  for (unsigned c = 0; c < l.count; ++c) {
    int s = l.speakers[c];
    hd::require(s >= 0 && s < 18,
                "WAV cannot label wide/top-side positions; select raw PCM",
                HD_UNSUPPORTED);
    mask |= 1u << s;
  }
  uint64_t bytes = samples * l.count * 3;
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
  u16(f, uint16_t(l.count));
  u32(f, 48000);
  u32(f, 48000 * l.count * 3);
  u16(f, uint16_t(l.count * 3));
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
void rewindFile(FILE *f) {
#ifdef _WIN32
  hd::require(!_fseeki64(f, 0, SEEK_SET), "PCM header seek", HD_IO);
#else
  hd::require(!fseeko(f, 0, SEEK_SET), "PCM header seek", HD_IO);
#endif
}
} // namespace
extern "C" int hdmaxdec_export_pcm(const char *input, const char *output,
                                   const hdmaxdec_export_options *options,
                                   hdmaxdec_progress progress, void *context,
                                   hdmaxdec_export_result *result) {
  if (!input || !output || !options || !result)
    return HD_INVALID;
  *result = {};
  fs::path temporary;
  try {
    hd::require(options->format >= HD_PCM_WAV24 &&
                    options->format <= HD_PCM_F32LE &&
                    std::isfinite(options->gain) && options->gain >= 0,
                "invalid PCM export options");
    hd::require(options->layout.count <= HDMAXDEC_MAX_CHANNELS,
                "export channel count exceeds bound");
    fs::path src = fs::u8path(input), dst = fs::u8path(output);
    std::error_code ec;
    hd::require(fs::absolute(src).lexically_normal() !=
                        fs::absolute(dst).lexically_normal() &&
                    !fs::equivalent(src, dst, ec),
                "PCM input and output must differ");
    std::unique_ptr<hdmaxdec_file, decltype(&hdmaxdec_file_close)> file(
        hdmaxdec_file_open(input), hdmaxdec_file_close);
    hd::require(bool(file), "input open or container parse failed", HD_IO);
    hdmaxdec_frame frame{};
    int status = hdmaxdec_file_read(file.get(), &frame);
    hd::require(status == HD_OK, hdmaxdec_file_error(file.get()), status);
    result->layout = options->layout.count ? options->layout : frame.layout;
    if (options->format == HD_PCM_WAV24)
      std::sort(result->layout.speakers,
                result->layout.speakers + result->layout.count);
    float m[32 * 32];
    hd::require(hdmaxdec_frame_mix_matrix(&frame, &result->layout, m) == HD_OK,
                "invalid export layout");
    static std::atomic<uint64_t> serial{0};
    temporary = dst;
    temporary += fs::u8path(
        ".hdmaxdec-" +
        std::to_string(
            std::chrono::steady_clock::now().time_since_epoch().count()) +
        "-" + std::to_string(serial++) + ".tmp");
    std::unique_ptr<FILE, Close> out(open(temporary));
    hd::require(bool(out), "PCM output open failed", HD_IO);
    if (options->format == HD_PCM_WAV24)
      header(out.get(), result->layout, 0);
    hdmaxdec_layout original = frame.layout;
    unsigned immersive = frame.immersive;
    uint64_t total = hdmaxdec_file_sample_count(file.get());
    std::vector<uint8_t> bytes;
    do {
      if (progress && !progress(context, result->samples, total))
        throw hd::Error(HD_CANCELLED, "PCM export cancelled");
      hd::require(frame.layout.count == original.count &&
                      frame.immersive == immersive &&
                      std::equal(original.speakers,
                                 original.speakers + original.count,
                                 frame.layout.speakers),
                  "PCM format changed", HD_UNSUPPORTED);
      hd::require(hdmaxdec_frame_mix_matrix(&frame, &result->layout, m) ==
                      HD_OK,
                  "PCM mix matrix");
      bytes.clear();
      unsigned width =
          options->format == HD_PCM_WAV24 || options->format == HD_PCM_S24LE
              ? 3
              : 4;
      bytes.reserve(size_t(frame.sample_count) * result->layout.count * width);
      for (unsigned i = 0; i < frame.sample_count; ++i)
        for (unsigned o = 0; o < result->layout.count; ++o) {
          double value = 0;
          for (unsigned c = 0; c < frame.layout.count; ++c)
            value += double(frame.planes[c][i]) * m[o * frame.layout.count + c];
          value *= options->gain;
          if (value < -8388608 || value > 8388607)
            ++result->clipped_samples;
          int32_t q = hd::clip(
              int64_t(std::llround(std::clamp(value, -8388608.0, 8388607.0))));
          uint32_t raw = uint32_t(q);
          if (options->format == HD_PCM_S32LE)
            raw = uint32_t(int64_t(q) * 256);
          else if (options->format == HD_PCM_F32LE) {
            float f = float(std::clamp(value / 8388608, -1.0, 1.0));
            std::memcpy(&raw, &f, 4);
          }
          for (unsigned b = 0; b < width; ++b)
            bytes.push_back(uint8_t(raw >> (b * 8)));
        }
      put(out.get(), bytes.data(), bytes.size());
      result->samples += frame.sample_count;
      status = hdmaxdec_file_read(file.get(), &frame);
    } while (status == HD_OK);
    hd::require(status == HD_NEED_MORE, hdmaxdec_file_error(file.get()),
                status);
    if (progress && !progress(context, result->samples, total))
      throw hd::Error(HD_CANCELLED, "PCM export cancelled");
    if (options->format == HD_PCM_WAV24) {
      if ((result->samples * result->layout.count * 3) & 1) {
        uint8_t pad = 0;
        put(out.get(), &pad, 1);
      }
      rewindFile(out.get());
      header(out.get(), result->layout, result->samples);
    }
    hd::require(!std::fflush(out.get()), "PCM output flush failed", HD_IO);
    FILE *closed = out.release();
    hd::require(!std::fclose(closed), "PCM output close failed", HD_IO);
#ifdef _WIN32
    hd::require(MoveFileExW(temporary.c_str(), dst.c_str(),
                            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH),
                "PCM output commit failed", HD_IO);
#else
    hd::require(!std::rename(temporary.c_str(), dst.c_str()),
                "PCM output commit failed", HD_IO);
#endif
    return HD_OK;
  } catch (const hd::Error &e) {
    std::snprintf(result->error, sizeof(result->error), "%s", e.what());
    std::error_code ec;
    if (!temporary.empty())
      fs::remove(temporary, ec);
    return e.status;
  } catch (const std::exception &e) {
    std::snprintf(result->error, sizeof(result->error), "%s", e.what());
    std::error_code ec;
    if (!temporary.empty())
      fs::remove(temporary, ec);
    return HD_INVALID;
  }
}
