// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "fixtures/layered_vectors.hpp"
#include "fixtures/profiles_vectors.hpp"
#include "fixtures/public_vectors.hpp"
#include "hdmaxdec.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <vector>
namespace fs = std::filesystem;
using File = std::unique_ptr<hdmaxdec_file, decltype(&hdmaxdec_file_close)>;
static void check(bool value, const char *message) {
  if (!value) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
}
struct Range {
  uint64_t start, end;
  std::vector<std::vector<int32_t>> planes;
};
static void verify(const fs::path &path) {
  File reference(hdmaxdec_file_open(path.u8string().c_str()),
                 hdmaxdec_file_close);
  File indexed(hdmaxdec_file_open(path.u8string().c_str()),
               hdmaxdec_file_close);
  check(reference && indexed, "seek fixture open");
  check(hdmaxdec_file_measure(reference.get(), nullptr, nullptr) == HD_OK &&
            hdmaxdec_file_measure(indexed.get(), nullptr, nullptr) == HD_OK,
        "seek fixture duration");
  uint64_t total = hdmaxdec_file_sample_count(reference.get());
  check(total >= 48000, "multiple history intervals");
  std::vector<Range> ranges;
  auto add = [&](uint64_t at) {
    if (at <= total)
      ranges.push_back({at, std::min(total, at + 1537), {}});
  };
  for (uint64_t at : {0u, 1u, 511u, 512u, 513u, 12287u, 12288u, 12289u})
    add(at);
  add(total - 1024);
  add(total - 1);
  add(total);
  uint32_t random = 0x12345678;
  for (int i = 0; i < 32; ++i) {
    random = random * 1664525u + 1013904223u;
    add(random % total);
  }
  hdmaxdec_frame frame{};
  hdmaxdec_layout layout{};
  uint64_t cursor = 0;
  int status;
  while ((status = hdmaxdec_file_read(reference.get(), &frame)) == HD_OK) {
    layout = frame.layout;
    for (auto &r : ranges) {
      if (r.planes.empty())
        r.planes.resize(layout.count);
      uint64_t begin = std::max(cursor, r.start);
      uint64_t end = std::min(cursor + frame.sample_count, r.end);
      if (begin < end)
        for (unsigned c = 0; c < layout.count; ++c)
          r.planes[c].insert(r.planes[c].end(),
                             frame.planes[c] + begin - cursor,
                             frame.planes[c] + end - cursor);
    }
    cursor += frame.sample_count;
  }
  check(status == HD_NEED_MORE && cursor == total,
        "sequential reference closure");
  check(hdmaxdec_file_seek(indexed.get(), 17) == HD_OK, "pending partial AU");
  unsigned callbacks = 0;
  auto cancel = [](void *p, uint64_t, uint64_t) -> int {
    return ++*static_cast<unsigned *>(p) < 16;
  };
  check(hdmaxdec_file_prepare_seek(indexed.get(), cancel, &callbacks) ==
            HD_CANCELLED,
        "cancel partial history preparation");
  check(hdmaxdec_file_prepare_seek(indexed.get(), nullptr, nullptr) == HD_OK,
        "prepare full Core history index");
  check(hdmaxdec_file_read(indexed.get(), &frame) == HD_OK,
        "preparation preserves pending PCM");
  for (unsigned c = 0; c < frame.layout.count; ++c)
    for (unsigned i = 0; i < std::min<unsigned>(frame.sample_count, 495); ++i)
      check(frame.planes[c][i] == ranges[0].planes[c][17 + i],
            "cancel/preparation preserves PCM and logical position");
  double worst = 0;
  for (auto it = ranges.rbegin(); it != ranges.rend(); ++it) {
    auto &r = *it;
    auto begin = std::chrono::steady_clock::now();
    check(hdmaxdec_file_seek(indexed.get(), r.start) == HD_OK, "indexed seek");
    worst = std::max(worst, std::chrono::duration<double, std::milli>(
                                std::chrono::steady_clock::now() - begin)
                                .count());
    uint64_t done = 0;
    while (done < r.end - r.start) {
      check(hdmaxdec_file_read(indexed.get(), &frame) == HD_OK &&
                frame.layout.count == layout.count,
            "indexed PCM dimensions");
      unsigned count = unsigned(
          std::min<uint64_t>(frame.sample_count, r.end - r.start - done));
      for (unsigned c = 0; c < layout.count; ++c)
        for (unsigned i = 0; i < count; ++i)
          check(frame.planes[c][i] == r.planes[c][size_t(done) + i],
                "indexed PCM matches sequential Core/public/private history");
      done += count;
    }
    if (r.start == total)
      check(hdmaxdec_file_read(indexed.get(), &frame) == HD_NEED_MORE,
            "indexed EOF boundary");
  }
  std::printf("%s: %zu exact seek windows, worst %.3f ms\n",
              path.filename().u8string().c_str(), ranges.size(), worst);
}
int main(int argc, char **argv) {
  if (argc > 1) {
    for (int i = 1; i < argc; ++i)
      verify(fs::u8path(argv[i]));
    return 0;
  }
  auto dir = fs::temp_directory_path() /
             ("hdmaxdec-seek-" +
              std::to_string(
                  std::chrono::steady_clock::now().time_since_epoch().count()));
  fs::create_directories(dir);
  auto fixture = [&](const char *name, const uint8_t *bytes, size_t size) {
    auto path = dir / name;
    {
      std::ofstream out(path, std::ios::binary);
      for (int n = 0; n < 120; ++n)
        out.write(reinterpret_cast<const char *>(bytes), std::streamsize(size));
      check(bool(out), "seek fixture write");
    }
    verify(path);
  };
  fixture("core.dts", core_vector, sizeof(core_vector));
  fixture("public.dts", sevenone, sizeof(sevenone));
  fixture("private.dts", private_sine, sizeof(private_sine));
  auto objects = profileBytes(dynamic_4_auto);
  fixture("四对象.dts", objects.data(), objects.size());
  auto imax = profileBytes(dynamic_5_auto);
  fixture("imax-objects.dts", imax.data(), imax.size());
  fs::remove_all(dir);
}
