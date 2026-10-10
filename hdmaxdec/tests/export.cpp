// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "fixtures/public_vectors.hpp"
#include "hdmaxdec.h"
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>
namespace fs = std::filesystem;
static void check(bool ok, const char *m) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", m);
    std::exit(1);
  }
}
static std::vector<uint8_t> read(const fs::path &p) {
  std::ifstream f(p, std::ios::binary);
  return {std::istreambuf_iterator<char>(f), {}};
}
static int32_t sample(unsigned channel, unsigned i) {
  uint32_t state = 0x243f6a88u + channel * 0x9e37u;
  for (unsigned j = 0; j <= i; ++j)
    state = state * 1664525u + 1013904223u;
  int32_t v = int32_t(state & 0xffffffu);
  if (v & 0x800000)
    v -= 0x1000000;
  if (i == 0)
    v = -8388608 + int32_t(channel);
  if (i == 1)
    v = 8388607 - int32_t(channel);
  if (i == 2)
    v = 0;
  if (i == 3)
    v = 1 << channel;
  return v;
}
int main() {
  auto dir =
      fs::temp_directory_path() /
      fs::u8path(
          "hdmaxdec-QC-通道-" +
          std::to_string(
              std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(dir);
  auto input = dir / "input.dts";
  {
    std::ofstream f(input, std::ios::binary);
    f.write(reinterpret_cast<const char *>(stereo), sizeof(stereo));
  }
  for (int format = 0; format < 4; ++format) {
    auto output = dir / ("output-" + std::to_string(format));
    hdmaxdec_export_options options{};
    options.gain = 1;
    options.format = hdmaxdec_pcm_format(format);
    hdmaxdec_export_result result{};
    check(hdmaxdec_export_pcm(input.u8string().c_str(),
                              output.u8string().c_str(), &options, nullptr,
                              nullptr, &result) == HD_OK,
          result.error);
    check(result.samples == 1024 && result.layout.count == 2 &&
              !result.clipped_samples,
          "native export metadata");
    auto bytes = read(output);
    unsigned width = format <= 1 ? 3 : 4;
    size_t offset = format == 0 ? 104 : 0;
    check(bytes.size() == offset + 1024 * 2 * width, "PCM byte count");
    for (unsigned i = 0; i < 1024; ++i)
      for (unsigned c = 0; c < 2; ++c) {
        int32_t v = sample(c, i);
        uint32_t raw = uint32_t(v);
        if (format == 2)
          raw = uint32_t(int64_t(v) * 256);
        if (format == 3) {
          float x = float(v) / 8388608;
          std::memcpy(&raw, &x, 4);
        }
        for (unsigned b = 0; b < width; ++b)
          check(bytes[offset + (i * 2 + c) * width + b] ==
                    uint8_t(raw >> (8 * b)),
                "export sample precision and interleave");
      }
  }
  auto output = dir / "existing.pcm";
  {
    std::ofstream f(output);
    f << "keep";
  }
  hdmaxdec_export_options options{};
  options.gain = 1;
  options.format = HD_PCM_S24LE;
  hdmaxdec_export_result result{};
  auto cancel = [](void *, uint64_t, uint64_t) { return 0; };
  check(hdmaxdec_export_pcm(input.u8string().c_str(), output.u8string().c_str(),
                            &options, cancel, nullptr, &result) == HD_CANCELLED,
        "cancelled export status");
  check(read(output) == std::vector<uint8_t>({'k', 'e', 'e', 'p'}),
        "cancellation preserves existing output");
  for (auto &e : fs::directory_iterator(dir))
    check(e.path().extension() != ".tmp", "cancelled temporary removed");
  check(hdmaxdec_export_pcm(input.u8string().c_str(), input.u8string().c_str(),
                            &options, nullptr, nullptr, &result) == HD_INVALID,
        "input overwrite rejected");
  options.layout.count = 33;
  check(hdmaxdec_export_pcm(input.u8string().c_str(), output.u8string().c_str(),
                            &options, nullptr, nullptr, &result) == HD_INVALID,
        "oversized export layout");
  auto *f = hdmaxdec_file_open(input.u8string().c_str());
  check(f, "raw file open");
  check(hdmaxdec_file_measure(f, nullptr, nullptr) == HD_OK &&
            hdmaxdec_file_sample_count(f) == 1024,
        "raw header duration");
  check(hdmaxdec_file_seek_progress(f, 600, cancel, nullptr) == HD_CANCELLED,
        "seek cancellation");
  check(hdmaxdec_file_seek(f, 600) == HD_OK, "seek after cancellation");
  hdmaxdec_frame frame{};
  check(hdmaxdec_file_read(f, &frame) == HD_OK &&
            frame.planes[0][0] == sample(0, 600),
        "seek exact sample");
  hdmaxdec_file_close(f);
  fs::remove_all(dir);
  std::puts("PCM export, Unicode paths, cancellation and seek passed");
}
