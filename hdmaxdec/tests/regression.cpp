// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "fixtures/layered_vectors.hpp"
#include "fixtures/profiles_vectors.hpp"
#include "fixtures/public_vectors.hpp"
#include "hdmaxdec.h"
#include "internal.hpp"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
namespace {
void check(bool ok, const char *m) {
  if (!ok) {
    std::fprintf(stderr, "FAIL: %s\n", m);
    std::exit(1);
  }
}
void vector(const uint8_t *bytes, size_t size, int channels) {
  std::unique_ptr<hdmaxdec_decoder, decltype(&hdmaxdec_destroy)> decoder(
      hdmaxdec_create(), hdmaxdec_destroy);
  check(bool(decoder), "allocation");
  size_t at = 0;
  int offset = 0;
  while (at < size) {
    size_t used = 0;
    hdmaxdec_frame frame{};
    check(hdmaxdec_decode(decoder.get(), bytes + at, size - at, &used,
                          &frame) == HD_OK,
          hdmaxdec_error(decoder.get()));
    check(used > 0 && frame.layout.count == uint32_t(channels) &&
              frame.sample_count == 512,
          "decoded vector dimensions");
    for (int c = 0; c < channels; ++c) {
      uint32_t state = 0x243f6a88u + uint32_t(c) * 0x9e37u;
      for (int i = 0; i < offset + 512; ++i) {
        state = state * 1664525u + 1013904223u;
        int32_t value = int32_t(state & 0xffffffu);
        if (value & 0x800000)
          value -= 0x1000000;
        if (i == 0)
          value = -8388608 + c;
        else if (i == 1)
          value = 8388607 - c;
        else if (i == 2)
          value = 0;
        else if (i == 3)
          value = 1 << (c % 20);
        if (i >= offset)
          check(frame.planes[c][i - offset] == value,
                "independent deterministic PCM sample");
      }
    }
    at += used;
    offset += 512;
  }
  check(offset == 1024, "vector sample count");
  hdmaxdec_reset(decoder.get());
  for (size_t n = 0; n < 32; ++n) {
    size_t used = 123;
    hdmaxdec_frame f{};
    int status = hdmaxdec_decode(decoder.get(), bytes, n, &used, &f);
    check(status == HD_NEED_MORE && used == 0,
          "incomplete input must not consume bytes");
  }
  std::vector<uint8_t> corrupt(bytes, bytes + size);
  corrupt[6] ^= 1;
  size_t used = 0;
  hdmaxdec_frame f{};
  check(hdmaxdec_decode(decoder.get(), corrupt.data(), corrupt.size(), &used,
                        &f) < 0 &&
            used == 0,
        "header corruption rejected");
  hdmaxdec_reset(decoder.get());
  check(hdmaxdec_decode(decoder.get(), bytes, size, &used, &f) == HD_OK,
        "reset after corruption");
}
void layered() {
  auto *d = hdmaxdec_create();
  check(d, "layered context");
  size_t at = 0;
  uint64_t hashes[6];
  std::fill(std::begin(hashes), std::end(hashes), 14695981039346656037ULL);
  while (at < std::size(core_vector)) {
    size_t used = 0;
    hdmaxdec_frame f{};
    check(!hdmaxdec_decode_core(d, core_vector + at,
                                std::size(core_vector) - at, &used, &f),
          "standalone Core vector");
    for (unsigned c = 0; c < 6; ++c)
      for (unsigned i = 0; i < f.sample_count; ++i) {
        uint32_t v = uint32_t(f.planes[c][i]);
        for (unsigned b = 0; b < 4; ++b)
          hashes[c] = (hashes[c] ^ uint8_t(v >> (b * 8))) * 1099511628211ULL;
      }
    at += used;
  }
  for (unsigned c = 0; c < 6; ++c)
    check(hashes[c] == core_hashes[c],
          "independent Core synthesis/history golden");
  hdmaxdec_reset(d);
  at = 0;
  int timeline = -1024;
  while (at < std::size(private_sine)) {
    size_t used = 0;
    hdmaxdec_frame f{};
    check(!hdmaxdec_decode(d, private_sine + at, std::size(private_sine) - at,
                           &used, &f),
          hdmaxdec_error(d));
    check(f.layout.count == 12 && f.immersive == 1,
          "standard layered presentation");
    for (unsigned c = 0; c < 12; ++c) {
      int source = 0;
      switch (f.layout.speakers[c]) {
      case HD_FL:
        source = 0;
        break;
      case HD_FR:
        source = 1;
        break;
      case HD_FC:
        source = 2;
        break;
      case HD_LFE:
        source = 3;
        break;
      case HD_SL:
        source = 4;
        break;
      case HD_SR:
        source = 5;
        break;
      case HD_BL:
        source = 6;
        break;
      case HD_BR:
        source = 7;
        break;
      case HD_TFL:
        source = 8;
        break;
      case HD_TFR:
        source = 9;
        break;
      case HD_TBL:
        source = 10;
        break;
      case HD_TBR:
        source = 11;
        break;
      default:
        check(false, "private speaker position");
      }
      for (unsigned i = 0; i < f.sample_count; ++i) {
        int sample = timeline + int(i);
        // Core pre-roll can carry analysis output before the source origin;
        // only its declared zero-height feeds are a digital-zero contract.
        if (sample < 0 && source < 8)
          continue;
        int32_t expected =
            sample < 0 || sample >= 1024
                ? 0
                : int32_t(std::llround(std::sin(2.0 * std::acos(-1.0) *
                                                (521.0 + source * 137.0) *
                                                sample / 48000.0) *
                                       700000.0));
        check(f.planes[c][i] == expected,
              "independent twelve-channel predictor/entropy/bed unfold vector");
      }
    }
    timeline += int(f.sample_count);
    at += used;
  }
  check(timeline == 1024, "layered priming/timeline");
  hdmaxdec_destroy(d);
}
void layouts() {
  const char *names[] = {"2.0",   "5.1",   "7.1",   "5.1.2", "5.1.4",
                         "7.1.2", "7.1.4", "7.1.5", "7.1.6", "9.1.6"};
  const unsigned counts[] = {2, 6, 8, 8, 10, 10, 12, 13, 14, 16};
  for (size_t n = 0; n < std::size(names); ++n) {
    hdmaxdec_layout l{};
    check(hdmaxdec_layout_named(names[n], &l) == HD_OK && l.count == counts[n],
          "named layout");
    float m[1024];
    check(!hdmaxdec_mix_matrix(&l, &l, m), "identity layout");
    for (unsigned o = 0; o < l.count; ++o)
      for (unsigned i = 0; i < l.count; ++i)
        check(m[o * l.count + i] == float(i == o), "speaker identity routing");
  }
  hdmaxdec_layout in{}, out{};
  hdmaxdec_layout_named("7.1.5", &in);
  hdmaxdec_layout_named("9.1.6", &out);
  float m[1024];
  check(!hdmaxdec_mix_matrix(&in, &out, m), "immersive geometry routing");
  for (unsigned i = 0; i < in.count; ++i) {
    double energy = 0;
    for (unsigned o = 0; o < out.count; ++o)
      energy += m[o * in.count + i] * m[o * in.count + i];
    check(std::abs(energy - 1) < 1e-6, "equal-power spatial fold");
  }
  // Per-channel impulses expose mislabeled rear/side/top/wide routes.
  std::array<std::array<int32_t, 13>, 13> planes{};
  hdmaxdec_frame f{};
  f.layout = in;
  f.sample_rate = 48000;
  f.bit_depth = 24;
  f.sample_count = 13;
  for (unsigned c = 0; c < 13; ++c) {
    planes[c][c] = 4194304;
    f.planes[c] = planes[c].data();
  }
  float pcm[13 * 16];
  check(!hdmaxdec_render_float(&f, &out, 1, pcm, std::size(pcm)),
        "impulse rendering");
  for (unsigned i = 0; i < 13; ++i)
    for (unsigned o = 0; o < 16; ++o)
      check(std::abs(pcm[i * 16 + o] - m[o * 13 + i] * 0.5f) < 1e-7,
            "impulse speaker matrix");
  out.count = 33;
  check(hdmaxdec_mix_matrix(&in, &out, m) == HD_INVALID,
        "oversized speaker map rejected");
  hdmaxdec_layout_named("7.1", &out);
  f.immersive = 2;
  check(!hdmaxdec_frame_mix_matrix(&f, &out, m), "IMAX metadata fold");
  check(m[0 * 13 + 12] == 13818.0f / 32768 &&
            m[1 * 13 + 12] == 13818.0f / 32768 &&
            m[2 * 13 + 12] == 27571.0f / 32768 && m[0 * 13 + 8] == 1 &&
            m[4 * 13 + 10] == 1,
        "IMAX TFC and unity height coefficients");
  f.immersive = 1;
  f.layout.count = 12;
  check(!hdmaxdec_frame_mix_matrix(&f, &out, m) && m[8] == 23170.0f / 32768,
        "standard Q15 height coefficient");
}
void malformed() {
  std::unique_ptr<hdmaxdec_decoder, decltype(&hdmaxdec_destroy)> d(
      hdmaxdec_create(), hdmaxdec_destroy);
  uint32_t seed = 0xabcdef;
  std::array<uint8_t, 256> b{};
  for (int iteration = 0; iteration < 4096; ++iteration) {
    for (auto &v : b) {
      seed = seed * 1664525u + 1013904223u;
      v = uint8_t(seed >> 24);
    }
    if (iteration % 3 == 0) {
      b[0] = 0x41;
      b[1] = 0xa2;
      b[2] = 0x95;
      b[3] = 0x47;
    }
    size_t consumed = 0;
    hdmaxdec_frame f{};
    int s = hdmaxdec_decode(d.get(), b.data(), size_t(iteration % 257),
                            &consumed, &f);
    check(s != HD_OK, "random malformed frames rejected");
    hdmaxdec_reset(d.get());
  }
  uint8_t zero[1] = {0};
  hd::Bits reader(zero, 1);
  bool failed = false;
  try {
    reader.read(9);
  } catch (const hd::Error &) {
    failed = true;
  }
  check(failed, "bounded bit reader");
  check(hd::asr(-3, 1) == -2 && hd::wrap(INT64_C(0xffffffff)) == -1,
        "portable integer arithmetic");
}
int sampleValue(int channel, int sample) {
  return ((sample % 67) - 33) * (channel + 1) * 113;
}
void profile(const char *encoded, int id, bool dynamic) {
  auto bytes = profileBytes(encoded);
  auto *d = hdmaxdec_create();
  check(d, "profile context");
  int timeline = -1024;
  size_t at = 0;
  int bed = id >= 3 && !dynamic ? 6 : 8;
  int records = dynamic ? id : 0;
  std::array<std::array<double, 12>, 4> image{}, target{};
  for (int slot = 0; slot < 4; ++slot)
    image[slot] = hd::objectImage(std::array<int, 4>{100, 140, 20, 220}[slot],
                                  60 + slot * 10);
  int maximum = 0;
  while (at < bytes.size()) {
    hdmaxdec_frame f{};
    size_t used = 0;
    check(hdmaxdec_decode(d, bytes.data() + at, bytes.size() - at, &used, &f) ==
              HD_OK,
          hdmaxdec_error(d));
    check(used > 0 && f.sample_count == 512, "profile AU closure");
    check(f.layout.count ==
              unsigned(dynamic
                           ? (records == 5 ? 13 : 12)
                           : bed + std::array<int, 6>{3, 2, 2, 5, 4, 3}[id]),
          "profile speaker count");
    int frame = std::max(0, timeline / 512);
    for (int slot = 0; slot < 4; ++slot)
      target[slot] = hd::objectImage(
          std::array<int, 4>{100, 140, 20, 220}[slot] + frame * 3,
          60 + slot * 10);
    for (int i = 0; i < 512; ++i) {
      int sample = timeline + i;
      bool audible = sample >= 0 && sample < 1025;
      std::array<double, 12> rendered{};
      if (dynamic)
        for (int slot = 0; slot < 4; ++slot) {
          int value = audible ? sampleValue(slot + 13, sample) : 0;
          int64_t numerator = int64_t(value) * 32768;
          constexpr int gain = 23170;
          int64_t coded = numerator >= 0 ? (numerator + gain / 2) / gain
                                         : -((-numerator + gain / 2) / gain);
          for (int c = 0; c < 12; ++c) {
            image[slot][c] +=
                (target[slot][c] - image[slot][c]) * 0.001098198738079148;
            rendered[c] += double(coded) * gain / 32768 * image[slot][c];
          }
        }
      for (unsigned c = 0; c < f.layout.count; ++c) {
        int source = -1;
        switch (f.layout.speakers[c]) {
        case HD_FL:
          source = 0;
          break;
        case HD_FR:
          source = 1;
          break;
        case HD_FC:
          source = 2;
          break;
        case HD_LFE:
          source = 3;
          break;
        case HD_SL:
          source = 4;
          break;
        case HD_SR:
          source = 5;
          break;
        case HD_BL:
          source = 6;
          break;
        case HD_BR:
          source = 7;
          break;
        case HD_TFL:
        case HD_TSL:
          source = bed;
          break;
        case HD_TFR:
        case HD_TSR:
          source = bed + 1;
          break;
        case HD_TBC:
          source = bed + 2;
          break;
        case HD_TFC:
          source = dynamic ? 12 : bed + 2;
          break;
        case HD_TBL:
          source = bed + (id == 3 && !dynamic ? 3 : 2);
          break;
        case HD_TBR:
          source = bed + (id == 3 && !dynamic ? 4 : 3);
          break;
        default:
          check(false, "unexpected profile speaker");
        }
        int expected = audible ? sampleValue(source, sample) : 0;
        if (dynamic && source < 12)
          expected += int(std::round(rendered[source]));
        // Raw AUs include codec priming; compare the exact source interval.
        if (audible)
          maximum = std::max(maximum, std::abs(f.planes[c][i] - expected));
      }
    }
    // All new layouts must also support a conventional monitoring downmix.
    hdmaxdec_layout stereo{};
    check(!hdmaxdec_layout_named("2.0", &stereo), "stereo layout");
    float matrix[64];
    check(!hdmaxdec_frame_mix_matrix(&f, &stereo, matrix),
          "profile stereo fold");
    timeline += 512;
    at += used;
  }
  if (maximum > (dynamic ? 2 : 0))
    std::fprintf(stderr, "Profile %d dynamic=%d error=%d\n", id, int(dynamic),
                 maximum);
  check(maximum <= (dynamic ? 2 : 0),
        "profile reference PCM, permutation and continuous image");
  check(timeline == 1536, "profile priming and padded tail");
  // Exercise the private parser with a valid payload but a different enclosing
  // NAVI width, including the all-zero priming frame and its zero LSB fields.
  hd::Bits coreHeader(bytes.data(), 10);
  coreHeader.skip(46);
  size_t extension = (size_t(coreHeader.get(14) + 1) + 3) & ~size_t(3);
  hd::Bits extensionHeader(bytes.data() + extension, 10);
  extensionHeader.skip(42);
  bool wide = extensionHeader.get(1);
  size_t header = size_t(extensionHeader.get(wide ? 12 : 8) + 1);
  size_t frame = size_t(extensionHeader.get(wide ? 20 : 16) + 1);
  const uint8_t *xll = bytes.data() + extension + header;
  auto x = hd::decodeXLL(xll, frame - header);
  hd::Audio dummy;
  dummy.layout.count = unsigned(bed);
  hdmaxdec_speaker positions[] = {HD_FL, HD_FR, HD_FC, HD_LFE,
                                  HD_BL, HD_BR, HD_SL, HD_SR};
  for (int c = 0; c < bed; ++c)
    dummy.layout.speakers[c] = positions[bed == 6 && c >= 4 ? c + 2 : c];
  dummy.planes = hd::Planes(size_t(bed), std::vector<int32_t>(512));
  hd::Presentation presentation;
  x.width = std::max(8, x.width) + 1;
  bool rejected = false;
  try {
    hd::decodePrivate(dummy, x, xll + x.privateOffset,
                      frame - header - x.privateOffset, presentation);
  } catch (const hd::Error &) {
    rejected = true;
  }
  check(rejected, "private group must use the enclosing NAVI width");
  hdmaxdec_reset(d);
  size_t used = 99;
  hdmaxdec_frame f{};
  check(hdmaxdec_decode(d, bytes.data(), 10, &used, &f) == HD_NEED_MORE &&
            !used,
        "profile truncation consumes nothing");
  // Corrupt an ExSS header; the Core transaction must not be committed.
  auto damaged = bytes;
  check(extension + 8 < damaged.size(), "profile ExSS fixture");
  damaged[extension + 6] ^= 1;
  check(hdmaxdec_decode(d, damaged.data(), damaged.size(), &used, &f) < 0 &&
            !used,
        "profile CRC rejection");
  check(hdmaxdec_decode(d, bytes.data(), bytes.size(), &used, &f) == HD_OK,
        "profile failed AU preserves history");
  hdmaxdec_destroy(d);
}
void profiles() {
  const char *fixed[2][6] = {{fixed_0_auto, fixed_1_auto, fixed_2_auto,
                              fixed_3_auto, fixed_4_auto, fixed_5_auto},
                             {fixed_0_standard, fixed_1_standard,
                              fixed_2_standard, fixed_3_standard,
                              fixed_4_standard, fixed_5_standard}};
  for (auto &mode : fixed)
    for (int id = 0; id < 6; ++id)
      profile(mode[id], id, false);
  profile(dynamic_4_auto, 4, true);
  profile(dynamic_4_standard, 4, true);
  profile(dynamic_5_auto, 5, true);
  profile(dynamic_5_standard, 5, true);
  for (const auto &anchor : std::array<std::array<int, 3>, 5>{{{100, 60, 0},
                                                               {140, 60, 1},
                                                               {120, 60, 2},
                                                               {90, 90, 8},
                                                               {30, 90, 10}}}) {
    auto image = hd::objectImage(anchor[0], anchor[1]);
    check(std::abs(image[size_t(anchor[2])] - 1) < 1e-6,
          "speaker image unity anchor");
  }
}
void programme(const char *path) {
  std::unique_ptr<hdmaxdec_file, decltype(&hdmaxdec_file_close)> f(
      hdmaxdec_file_open(path), hdmaxdec_file_close);
  check(bool(f), "programme open");
  hdmaxdec_frame frame{};
  uint64_t count = 0;
  int s = 0;
  std::vector<std::vector<int32_t>> tail;
  while ((s = hdmaxdec_file_read(f.get(), &frame)) == HD_OK) {
    count += frame.sample_count;
    tail.clear();
    for (unsigned c = 0; c < frame.layout.count; ++c)
      tail.emplace_back(frame.planes[c], frame.planes[c] + frame.sample_count);
  }
  check(s == HD_NEED_MORE, "complete programme decode");
  uint64_t total = hdmaxdec_file_sample_count(f.get());
  check(total == UINT64_MAX || count == total,
        "programme sample count and priming");
  if (count > 100) {
    check(!hdmaxdec_file_seek(f.get(), count - 100), "EOF re-entry");
    check(!hdmaxdec_file_read(f.get(), &frame) && frame.sample_count >= 100,
          "EOF seek frame");
    for (unsigned c = 0; c < frame.layout.count; ++c)
      for (unsigned i = 0; i < 100; ++i)
        check(frame.planes[c][i] == tail[c][tail[c].size() - 100 + i],
              "Core history after re-entry");
    check(!hdmaxdec_file_seek(f.get(), 0), "stop/play reset");
    check(!hdmaxdec_file_read(f.get(), &frame), "restart decode");
  }
  std::printf("Programme passed: %llu samples/channel\n",
              (unsigned long long)count);
}
} // namespace
int main(int argc, char **argv) {
  vector(stereo, std::size(stereo), 2);
  vector(fiveone, std::size(fiveone), 6);
  vector(sevenone, std::size(sevenone), 8);
  layered();
  profiles();
  layouts();
  malformed();
  for (int i = 1; i < argc; ++i)
    programme(argv[i]);
  std::puts("hdmaxdec regressions passed");
}
