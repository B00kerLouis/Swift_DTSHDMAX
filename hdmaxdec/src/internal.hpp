// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include "hdmaxdec.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
namespace hd {
struct Error : std::runtime_error {
  int status;
  Error(int s, const char *m) : std::runtime_error(m), status(s) {}
};
inline void require(bool b, const char *m, int s = HD_INVALID) {
  if (!b)
    throw Error(s, m);
}
inline int32_t wrap(int64_t x) {
  uint32_t u = uint32_t(uint64_t(x));
  int32_t r;
  std::memcpy(&r, &u, 4);
  return r;
}
inline int32_t add(int32_t a, int32_t b) { return wrap(int64_t(a) + b); }
inline int32_t sub(int32_t a, int32_t b) { return wrap(int64_t(a) - b); }
/* Defined arithmetic shift on every C++17 compiler, including negative PCM. */
inline int64_t asr(int64_t x, unsigned n) {
  require(n < 63, "invalid arithmetic shift");
  if (!n)
    return x;
  return x >= 0 ? x / int64_t(uint64_t(1) << n)
                : -1 - int64_t(uint64_t(-(x + 1)) >> n);
}
inline int32_t norm(int64_t x, unsigned n) {
  require(n > 0 && n < 63, "invalid normalization shift");
  require(x <= INT64_MAX - (int64_t(1) << (n - 1)), "normalization overflow");
  return wrap(asr(x + (int64_t(1) << (n - 1)), n));
}
inline int64_t sumChecked(int64_t a, int64_t b) {
  require(!((b > 0 && a > INT64_MAX - b) || (b < 0 && a < INT64_MIN - b)),
          "prediction accumulator overflow");
  return a + b;
}
inline int32_t clip(int64_t x) {
  return int32_t(std::clamp<int64_t>(x, -8388608, 8388607));
}
inline uint32_t be32(const uint8_t *p) {
  return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 |
         p[3];
}
inline uint16_t be16(const uint8_t *p) {
  return uint16_t(uint16_t(p[0]) << 8 | p[1]);
}
inline uint16_t crc(const uint8_t *p, size_t n) {
  uint16_t c = 65535;
  for (size_t j = 0; j < n; ++j) {
    c ^= uint16_t(p[j]) << 8;
    for (int k = 0; k < 8; ++k)
      c = uint16_t((c << 1) ^ ((c & 32768) ? 0x1021 : 0));
  }
  return c;
}
struct Bits {
  const uint8_t *data;
  size_t size, pos = 0, limit;
  Bits(const uint8_t *p, size_t n) : data(p), size(n), limit(n * 8) {
    require(n <= size_t(1) << 24, "bitstream size exceeds bounded frame");
  }
  uint64_t read(unsigned n) {
    require(n <= 64 && pos <= limit && n <= limit - pos, "truncated bit field");
    uint64_t x = 0;
    for (unsigned i = 0; i < n; ++i) {
      x = (x << 1) | ((data[pos / 8] >> (7 - pos % 8)) & 1);
      ++pos;
    }
    return x;
  }
  int get(unsigned n) { return int(read(n)); }
  void skip(size_t n) {
    require(pos <= limit && n <= limit - pos, "truncated skipped field");
    pos += n;
  }
  void seek(size_t p) {
    require(p <= limit, "bitstream seek outside frame");
    pos = p;
  }
  void align() { seek((pos + 7) & ~size_t(7)); }
  void zeros(size_t end) {
    require(end >= pos && end <= limit, "invalid padding extent");
    while (pos < end)
      require(!read(1), "nonzero padding");
  }
  int32_t linear(unsigned n) {
    require(n <= 32, "linear width exceeds 32");
    if (!n)
      return 0;
    uint64_t v = read(n);
    return int32_t((v & 1) ? -int64_t(v >> 1) - 1 : int64_t(v >> 1));
  }
  int32_t signedBits(unsigned n) {
    require(n > 0 && n <= 32, "invalid signed width");
    uint64_t v = read(n);
    return wrap((v & (uint64_t(1) << (n - 1)))
                    ? int64_t(v) - int64_t(uint64_t(1) << n)
                    : int64_t(v));
  }
  int32_t rice(unsigned n) {
    require(n <= 31, "invalid Rice parameter");
    uint64_t q = 0;
    while (!read(1)) {
      require(++q <= uint64_t(UINT32_MAX) >> n, "Rice quotient overflow");
    }
    uint64_t v = (q << n) | read(n);
    int64_t s = (v & 1) ? -int64_t(v >> 1) - 1 : int64_t(v >> 1);
    require(s >= INT32_MIN && s <= INT32_MAX, "Rice sample overflow");
    return int32_t(s);
  }
  void checkCRC(size_t start, size_t end) {
    require(end >= start + 2 && end <= size, "invalid CRC range");
    require(crc(data + start, end - start) == 0, "CRC mismatch", HD_CRC);
  }
};
using Planes = std::vector<std::vector<int32_t>>;
struct Set {
  int count = 0, pcm = 24, storage = 24, lsbBytes = 0;
  uint64_t mask = 0, residual = 0;
  bool embedded = false, decor = false;
  std::vector<int> scales, coeff;
  std::array<int, 8> order{}, adaptive{}, fixed{}, lsb{}, adjust{};
  std::array<int32_t, 4> decorCoeff{};
  std::array<std::vector<int32_t>, 8> reflection;
  Planes planes;
};
struct XLL {
  int segments = 0, samples = 0, width = 0, crcMode = 0, fixedLSB = 0;
  bool scalable = false;
  size_t privateOffset = 0;
  std::vector<Set> sets;
};
struct Audio {
  Planes planes;
  hdmaxdec_layout layout{};
  uint32_t immersive = 0;
};
struct Core {
  struct Synth {
    std::array<int32_t, 512> history{};
    std::array<int32_t, 32> delay{};
    int offset = 0;
  };
  std::array<Synth, 5> synth{};
  std::array<std::array<std::array<int32_t, 4>, 32>, 5> adpcm{};
  std::array<int32_t, 8> lfe{};
  Audio decode(const uint8_t *, size_t);
};
Core &coreState(hdmaxdec_decoder *);
XLL decodeXLL(const uint8_t *, size_t);
Audio assemble(const XLL &, const Audio *);
void decodePrivate(Audio &, const XLL &, const uint8_t *, size_t);
void predict(Set &);
std::vector<Set> decodeGroups(Bits &, XLL &, bool alternate);
Audio decodeAU(Core &, const uint8_t *, size_t, size_t &);
} // namespace hd
