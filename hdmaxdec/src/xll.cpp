// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "internal.hpp"
#include "tables.hpp"
namespace hd {
struct Entropy {
  bool common = false, initialized = false;
  std::array<int, 8> rice{}, hybrid{}, a{}, b{}, seeds{};
};
static void predictionHeader(Bits &r, Set &s) {
  for (int c = 0; c < s.count; ++c)
    s.adaptive[c] = r.get(4);
  for (int c = 0; c < s.count; ++c)
    if (!s.adaptive[c])
      s.fixed[c] = r.get(2);
  for (int c = 0; c < s.count; ++c)
    for (int j = 0; j < s.adaptive[c]; ++j) {
      int i = r.linear(8);
      require(i != -128, "reserved reflection index");
      s.reflection[c].push_back(
          i < 0 ? -int32_t(table::reflectionCoefficients[-i])
                : table::reflectionCoefficients[i]);
    }
}
void predict(Set &s) {
  // Part-A provides original seeds. Prediction spans the whole frame after
  // every entropy segment has been read; segment boundaries do not reset it.
  for (int c = 0; c < s.count; ++c) {
    auto &p = s.planes[c];
    int n = s.adaptive[c];
    if (n) {
      std::vector<int32_t> d(size_t(n), 0);
      for (int i = 0; i < n; ++i) {
        int32_t k = s.reflection[c][i];
        for (int j = 0; j < (i + 1) / 2; ++j) {
          int o = i - j - 1;
          int32_t a = d[j], b = d[o];
          d[j] = add(a, norm(int64_t(k) * b, 16));
          d[o] = add(b, norm(int64_t(k) * a, 16));
        }
        d[i] = k;
      }
      for (size_t i = 0; i + size_t(n) < p.size(); ++i) {
        int64_t e = 0;
        for (int j = 0; j < n; ++j)
          e = sumChecked(e, int64_t(p[i + j]) * d[n - j - 1]);
        p[i + n] = sub(p[i + n], clip(asr(sumChecked(e, 32768), 16)));
      }
    } else
      for (int j = 0; j < s.fixed[c]; ++j)
        for (size_t i = 1; i < p.size(); ++i)
          p[i] = add(p[i], p[i - 1]);
  }
  if (s.decor) {
    for (int j = 0; j < s.count / 2; ++j)
      for (size_t i = 0; i < s.planes[0].size(); ++i)
        s.planes[j * 2 + 1][i] = add(
            s.planes[j * 2 + 1][i],
            wrap(asr(int64_t(s.planes[j * 2][i]) * s.decorCoeff[j] + 4, 3)));
    Planes coded = s.planes;
    for (int c = 0; c < s.count; ++c)
      s.planes[s.order[c]] = std::move(coded[c]);
  }
}
static void entropy(Bits &r, Set &s, Entropy &e, int seg, int samples) {
  bool reuse = seg > 0 && r.get(1);
  require(!reuse || e.initialized, "uninitialized entropy reuse");
  if (!reuse) {
    e.initialized = true;
    e.common = r.get(1);
    int np = e.common ? 1 : s.count;
    for (int p = 0; p < np; ++p) {
      e.rice[p] = r.get(1);
      e.hybrid[p] = !e.common && e.rice[p] && r.get(1) ? r.get(5) + 1 : 0;
    }
    for (int p = 0; p < np; ++p) {
      e.a[p] = seg == 0 ? r.get(5) : 0;
      if (!e.rice[p] && e.a[p])
        ++e.a[p];
      e.seeds[p] =
          seg == 0 ? (e.common ? *std::max_element(s.adaptive.begin(),
                                                   s.adaptive.begin() + s.count)
                               : s.adaptive[p])
                   : 0;
      e.b[p] = r.get(5);
      if (!e.rice[p] && e.b[p])
        ++e.b[p];
    }
  }
  for (int c = 0; c < s.count; ++c) {
    int p = e.common ? 0 : c;
    int a = e.seeds[p];
    require(a <= samples, "seed partition exceeds segment");
    int off = seg * samples;
    for (int i = 0; i < a; ++i)
      s.planes[c][off + i] =
          e.rice[p] ? r.rice(unsigned(e.a[p])) : r.linear(unsigned(e.a[p]));
    std::vector<bool> isolated(size_t(samples - a), false);
    if (e.hybrid[p]) {
      int lg = 0;
      while ((1 << lg) < samples)
        ++lg;
      int count = r.get(unsigned(lg));
      require(count <= samples - a, "isolated sample count");
      for (int i = 0; i < count; ++i) {
        int at = r.get(unsigned(lg));
        require(at < samples - a && !isolated[at],
                "invalid isolated sample location");
        isolated[at] = true;
      }
    }
    for (int i = a; i < samples; ++i)
      s.planes[c][off + i] =
          e.rice[p] ? (isolated[i - a] ? r.linear(unsigned(e.hybrid[p]))
                                       : r.rice(unsigned(e.b[p])))
                    : r.linear(unsigned(e.b[p]));
  }
}
static Set channelHeader(Bits &r, XLL &x, int index, int lower, int maskBits,
                         bool alternate, bool fixedMapping) {
  size_t start = r.pos / 8;
  size_t end = start + size_t(r.get(10) + 1);
  r.checkCRC(start, end);
  size_t oldLimit = r.limit;
  r.limit = (end - 2) * 8;
  Set s;
  s.count = r.get(4) + 1;
  require(s.count <= 8, "channel set exceeds eight channels", HD_UNSUPPORTED);
  s.residual = r.read(unsigned(s.count));
  s.pcm = r.get(5) + 1;
  s.storage = r.get(5) + 1;
  int freq = r.get(4), modifier = r.get(2), replacement = r.get(2);
  if (replacement)
    r.skip(1);
  require(s.pcm <= s.storage && s.storage == 24 && freq == 12 && !modifier &&
              !replacement,
          "unsupported XLL audio characteristics", HD_UNSUPPORTED);
  if (alternate) {
    require(s.residual == ((uint64_t(1) << s.count) - 1) &&
                !r.get(fixedMapping ? 1 : 2),
            "invalid private group map");
  } else {
    bool primary = r.get(1);
    require(primary == (index == 0), "invalid primary channel set");
    bool coeff = r.get(1);
    if (coeff) {
      s.embedded = r.get(1);
      if (primary)
        r.skip(3);
    }
    bool hierarchy = r.get(1);
    require(hierarchy || x.sets.size() == 1, "unsupported nonhierarchical sets",
            HD_UNSUPPORTED);
    if (coeff) {
      int inputs = primary ? 2 : lower;
      for (int i = 0; i < inputs; ++i) {
        if (!primary)
          s.scales.push_back(r.get(9));
        for (int c = 0; c < s.count; ++c)
          s.coeff.push_back(r.get(9));
      }
    }
    require(r.get(1), "missing XLL speaker mask", HD_UNSUPPORTED);
    s.mask = r.read(unsigned(maskBits));
    int count = 0;
    for (uint64_t m = s.mask; m; m >>= 1)
      count += int(m & 1);
    require(count == s.count, "XLL speaker mask mismatch");
  }
  s.decor = r.get(1);
  for (int c = 0; c < s.count; ++c)
    s.order[c] = c;
  if (s.decor && s.count > 1) {
    int lg = 1;
    while ((1 << lg) < s.count)
      ++lg;
    unsigned seen = 0;
    for (int c = 0; c < s.count; ++c) {
      s.order[c] = r.get(unsigned(lg));
      require(s.order[c] < s.count && !(seen & (1u << s.order[c])),
              "invalid channel permutation");
      seen |= 1u << s.order[c];
    }
    for (int p = 0; p < s.count / 2; ++p)
      if (r.get(1))
        s.decorCoeff[p] = r.linear(7);
  }
  predictionHeader(r, s);
  if (alternate)
    for (int c = 0; c < s.count; ++c)
      require(s.adaptive[c] <= 10, "private predictor order exceeds profile",
              HD_UNSUPPORTED);
  if (x.scalable) {
    uint64_t bytes = r.read(unsigned(x.width));
    require(bytes <= r.size, "LSB section exceeds frame");
    s.lsbBytes = int(bytes);
    if (s.lsbBytes && x.crcMode > 1)
      s.lsbBytes += 2;
    for (int c = 0; c < s.count; ++c)
      s.lsb[c] = r.get(4);
    for (int c = 0; c < s.count; ++c)
      s.adjust[c] = r.get(4);
    for (int c = 0; c < s.count; ++c)
      require(s.lsbBytes || !s.lsb[c], "LSB bits without section");
  }
  r.limit = oldLimit;
  r.seek(end * 8);
  s.planes = Planes(size_t(s.count),
                    std::vector<int32_t>(size_t(x.segments * x.samples), 0));
  return s;
}
static void bandData(Bits &r, XLL &x, std::vector<Set> &sets,
                     const std::vector<std::vector<int>> &navi) {
  std::vector<Entropy> states(sets.size());
  std::vector<Planes> lsb;
  for (auto &s : sets)
    lsb.emplace_back(size_t(s.count),
                     std::vector<int32_t>(size_t(x.segments * x.samples), 0));
  for (int seg = 0; seg < x.segments; ++seg)
    for (size_t j = 0; j < sets.size(); ++j) {
      Set &s = sets[j];
      size_t start = r.pos / 8, end = start + size_t(navi[seg][j]);
      require(end <= r.size, "band segment exceeds frame");
      size_t old = r.limit;
      size_t msbEnd = end - size_t(s.lsbBytes);
      require(size_t(s.lsbBytes) <= end - start, "invalid LSB section size");
      if (x.crcMode)
        require(msbEnd >= start + 2, "missing MSB CRC");
      r.limit = (msbEnd - (x.crcMode ? 2 : 0)) * 8;
      entropy(r, s, states[j], seg, x.samples);
      r.zeros(r.limit);
      if (x.crcMode)
        r.checkCRC(start, msbEnd);
      if (s.lsbBytes) {
        r.limit = (end - (x.crcMode > 1 ? 2 : 0)) * 8;
        r.seek(msbEnd * 8);
        for (int c = 0; c < s.count; ++c)
          for (int i = 0; i < x.samples && s.lsb[c]; ++i)
            lsb[j][c][seg * x.samples + i] =
                int32_t(r.read(unsigned(s.lsb[c])));
        r.zeros(r.limit);
        if (x.crcMode > 1)
          r.checkCRC(msbEnd, end);
      }
      r.limit = old;
      r.seek(end * 8);
    }
  for (size_t j = 0; j < sets.size(); ++j) {
    Set &s = sets[j];
    predict(s);
    for (int c = 0; c < s.count; ++c) {
      int shift = x.fixedLSB ? x.fixedLSB
                             : s.lsb[c] + s.adjust[c] -
                                   int(s.lsb[c] > 0 && s.adjust[c] > 0);
      require(shift <= 30 && s.adjust[c] <= 15, "invalid LSB assembly shift");
      if (shift)
        for (size_t i = 0; i < s.planes[c].size(); ++i)
          s.planes[c][i] = add(
              wrap(int64_t(s.planes[c][i]) * (int64_t(1) << shift)),
              s.lsb[c]
                  ? wrap(int64_t(lsb[j][c][i]) * (int64_t(1) << s.adjust[c]))
                  : 0);
    }
  }
}
std::vector<Set> decodeGroups(Bits &r, XLL &x, bool alternate,
                              bool fixedMapping) {
  int lower = 0;
  std::vector<Set> sets;
  int maskBits = int(x.privateOffset);
  for (size_t j = 0; j < x.sets.size(); ++j) {
    sets.push_back(
        channelHeader(r, x, int(j), lower, maskBits, alternate, fixedMapping));
    lower += sets.back().count;
  }
  size_t start = r.pos / 8;
  std::vector<std::vector<int>> navi(size_t(x.segments),
                                     std::vector<int>(sets.size()));
  for (auto &seg : navi)
    for (int &n : seg) {
      uint64_t bytes = r.read(unsigned(x.width)) + 1;
      require(bytes <= r.size, "NAVI segment exceeds frame");
      n = int(bytes);
    }
  r.zeros((r.pos + 7) & ~size_t(7));
  r.skip(16);
  r.checkCRC(start, r.pos / 8);
  bandData(r, x, sets, navi);
  x.privateOffset = fixedMapping ? r.pos / 8 : (r.pos / 8 + 3) & ~size_t(3);
  r.zeros(x.privateOffset * 8);
  return sets;
}
XLL decodeXLL(const uint8_t *p, size_t n) {
  Bits r(p, n);
  require(r.read(32) == 0x41a29547, "missing XLL sync");
  require(!r.get(4), "XLL version", HD_UNSUPPORTED);
  int header = r.get(8) + 1, bits = r.get(5) + 1;
  require(r.read(unsigned(bits)) + 1 == n, "XLL declared size mismatch");
  XLL x;
  int count = r.get(4) + 1;
  x.segments = 1 << r.get(4);
  x.samples = 1 << r.get(4);
  x.width = r.get(5) + 1;
  x.crcMode = r.get(2);
  x.scalable = r.get(1);
  x.privateOffset = size_t(r.get(5) + 1);
  x.fixedLSB = x.scalable ? r.get(4) : 0;
  require(count <= 3 && x.segments <= 1024 && x.samples <= 512 &&
              x.samples > 1 && x.segments * x.samples <= 65536,
          "unsupported XLL dimensions", HD_UNSUPPORTED);
  require(header >= 12 && size_t(header) <= n, "invalid common header");
  r.checkCRC(4, size_t(header));
  require(r.pos <= size_t(header - 2) * 8, "common fields overlap CRC");
  r.seek(size_t(header) * 8);
  x.sets.resize(size_t(count));
  x.sets = decodeGroups(r, x, false);
  return x;
}
static hdmaxdec_speaker speaker(int bit) {
  switch (bit) {
  case 0:
    return HD_FC;
  case 1:
    return HD_FL;
  case 2:
    return HD_FR;
  case 3:
    return HD_SL;
  case 4:
    return HD_SR;
  case 5:
    return HD_LFE;
  case 6:
    return HD_BC;
  case 7:
    return HD_BL;
  case 8:
    return HD_BR;
  case 9:
    return HD_SL;
  case 10:
    return HD_SR;
  case 11:
    return HD_FLC;
  case 12:
    return HD_FRC;
  case 13:
    return HD_TFL;
  case 14:
    return HD_TFC;
  case 15:
    return HD_TFR;
  case 16:
    return HD_LFE;
  case 17:
    return HD_TSL;
  case 18:
    return HD_TSR;
  case 19:
    return HD_TC;
  case 20:
    return HD_TBL;
  case 21:
    return HD_TBR;
  case 22:
    return HD_TBC;
  default:
    throw Error(HD_UNSUPPORTED, "unmapped DTS speaker position");
  }
}
static int32_t scaleQ16(int code) {
  int index = (code & 255) - 41;
  require(index >= 0 &&
              size_t(index) < std::size(table::inverseDownmixScalesQ16),
          "invalid downmix scale");
  int32_t v = int32_t(table::inverseDownmixScalesQ16[index]);
  return code & 256 ? v : -v;
}
static int32_t undoQ15(int scale, int code) {
  int magnitude = code & 255;
  require(size_t(magnitude) < std::size(table::downmixCoefficientsQ15),
          "invalid downmix coefficient");
  int32_t v = norm(
      int64_t(table::downmixCoefficientsQ15[magnitude]) * scaleQ16(scale), 16);
  return code & 256 ? v : -v;
}
Audio assemble(const XLL &x, const Audio *core) {
  // Recover primary C/L/R/LFE/side channels against Core, undo the secondary
  // rear-set fold, then publish the explicit WAVE speaker order.
  Audio a;
  if (x.sets.size() == 2 && x.sets[0].count == 6 && x.sets[1].count == 2) {
    const Set &p = x.sets[0], &s = x.sets[1];
    require(p.mask == 0x627 && s.mask == 0x180,
            "unsupported hierarchy speaker masks", HD_UNSUPPORTED);
    require(core || p.residual == 63, "XLL residual requires aligned Core",
            HD_UNSUPPORTED);
    int count = x.segments * x.samples;
    require(!core || (core->planes.size() == 6 &&
                      core->planes[0].size() == size_t(count)),
            "Core/XLL timeline mismatch");
    Planes h(8, std::vector<int32_t>(size_t(count)));
    int coreOrder[] = {2, 0, 1, 3, 4, 5};
    for (int c = 0; c < 6; ++c)
      for (int i = 0; i < count; ++i) {
        h[c][i] = p.planes[c][i];
        if (!(p.residual & (uint64_t(1) << c))) {
          int64_t v = core->planes[coreOrder[c]][i];
          if (s.embedded) {
            require(s.scales.size() == 6, "missing hierarchical scales");
            v = asr(v * scaleQ16(s.scales[c]) + 32768, 16);
          }
          int assembly = x.fixedLSB ? x.fixedLSB
                                    : p.lsb[c] + p.adjust[c] -
                                          int(p.lsb[c] > 0 && p.adjust[c] > 0);
          int shift = p.storage - p.pcm + assembly;
          require(shift >= 0 && shift <= 30, "invalid Core assembly shift");
          v = clip(asr(v + (shift ? (int64_t(1) << (shift - 1)) : 0),
                       unsigned(shift)));
          h[c][i] = add(h[c][i], wrap(v * (int64_t(1) << assembly)));
        }
      }
    h[6] = s.planes[0];
    h[7] = s.planes[1];
    if (s.embedded) {
      require(s.coeff.size() == 12 && s.scales.size() == 6,
              "invalid hierarchical matrix");
      for (int c = 0; c < 6; ++c)
        for (int d = 0; d < 2; ++d) {
          int32_t k = undoQ15(s.scales[c], s.coeff[c * 2 + d]);
          for (int i = 0; i < count; ++i)
            h[c][i] = sub(h[c][i], norm(int64_t(h[6 + d][i]) * k, 15));
        }
    }
    int order[] = {1, 2, 0, 3, 6, 7, 4, 5};
    hdmaxdec_speaker speakers[] = {HD_FL, HD_FR, HD_FC, HD_LFE,
                                   HD_BL, HD_BR, HD_SL, HD_SR};
    a.layout.count = 8;
    for (int c = 0; c < 8; ++c) {
      a.layout.speakers[c] = speakers[c];
      a.planes.push_back(std::move(h[order[c]]));
    }
    return a;
  }
  std::vector<std::pair<hdmaxdec_speaker, std::vector<int32_t>>> channels;
  for (const Set &s : x.sets) {
    bool residual = s.residual != ((uint64_t(1) << s.count) - 1);
    require(!residual ||
                (x.sets.size() == 1 && s.count == 6 && s.mask == 0x3f && core),
            "unsupported residual hierarchy", HD_UNSUPPORTED);
    int c = 0;
    for (int b = 0; b < 64; ++b)
      if (s.mask & (uint64_t(1) << b)) {
        auto plane = s.planes[c];
        if (!(s.residual & (uint64_t(1) << c))) {
          auto pos = speaker(b);
          uint32_t index = 0;
          while (index < core->layout.count &&
                 core->layout.speakers[index] != pos)
            ++index;
          require(index < core->layout.count &&
                      core->planes[index].size() == plane.size(),
                  "Core/XLL primary timeline or speaker mismatch");
          int assembly = x.fixedLSB ? x.fixedLSB
                                    : s.lsb[c] + s.adjust[c] -
                                          int(s.lsb[c] > 0 && s.adjust[c] > 0);
          int shift = s.storage - s.pcm + assembly;
          require(shift >= 0 && shift <= 30, "invalid Core assembly shift");
          for (size_t i = 0; i < plane.size(); ++i) {
            int32_t v = clip(asr(int64_t(core->planes[index][i]) +
                                     (shift ? INT64_C(1) << (shift - 1) : 0),
                                 unsigned(shift)));
            plane[i] =
                add(plane[i], wrap(int64_t(v) * (INT64_C(1) << assembly)));
          }
        }
        channels.push_back({speaker(b), std::move(plane)});
        ++c;
      }
  }
  std::sort(channels.begin(), channels.end(),
            [](const auto &l, const auto &r) { return l.first < r.first; });
  for (auto &c : channels) {
    require(a.layout.count < 32 &&
                (a.layout.count == 0 ||
                 a.layout.speakers[a.layout.count - 1] != c.first),
            "overlapping speaker sets");
    a.layout.speakers[a.layout.count++] = c.first;
    a.planes.push_back(std::move(c.second));
  }
  return a;
}
// Standard private NAVI is bound to the public width even for compact zeros.
static Planes standardPrivate(const uint8_t *p, size_t n, const XLL &x) {
  require(n >= 48 && be32(p) == 0x02000850, "invalid standard private header");
  require(!crc(p, 21), "private header CRC", HD_CRC);
  const uint8_t fixed[] = {0x28, 0x4b, 0xfa, 0x71, 0x0d, 0x62, 0x02, 0xfa,
                           0x02, 0xdc, 0x13, 0x71, 0x0d, 0xc8, 0x37};
  require(!std::memcmp(p + 4, fixed, sizeof(fixed)),
          "standard private metadata profile", HD_UNSUPPORTED);
  int primary = (be16(p + 22) >> 6) & 63, route = be16(p + 26) & 1023;
  unsigned routeSeen = 0;
  for (int c = 0; c < 4; ++c) {
    int to = (route >> (8 - c * 2)) & 3;
    require(!(routeSeen & (1u << to)), "invalid height routing permutation");
    routeSeen |= 1u << to;
  }
  require(p[21] == 2 && (be16(p + 22) & 0xf03f) == 15 &&
              be16(p + 24) == 0xef7c && (be16(p + 26) >> 10) == 1,
          "unsupported private profile", HD_UNSUPPORTED);
  require(!(route & 3), "private research decorrelation branch unsupported",
          HD_UNSUPPORTED);
  size_t boundary = 28 + size_t(primary - 7);
  require(primary >= 7 && boundary + 2 <= n, "private prediction boundary");
  Bits r(p, n);
  r.checkCRC(22, boundary + 2);
  r.seek(28 * 8);
  Set s;
  s.count = 4;
  predictionHeader(r, s);
  r.zeros(boundary * 8);
  r.skip(16);
  bool zeroPrediction = true;
  for (int c = 0; c < 4; ++c)
    zeroPrediction &= !s.adaptive[c] && !s.fixed[c];
  if (n == 48 && x.segments == 2 && x.samples == 256 && x.width <= 8 &&
      zeroPrediction && boundary == 36) {
    const uint8_t suffix[] = {2, 0, 0x7b, 0x6d, 0x80, 0, 0x40, 0, 0, 0};
    require(!std::memcmp(p + 38, suffix, 10), "invalid canonical zero frame");
    return Planes(4, std::vector<int32_t>(512));
  }
  int width = std::max(8, x.width);
  require(width <= 16 && x.segments <= 16 && x.segments * x.samples == 512,
          "private dimensions", HD_UNSUPPORTED);
  size_t navStart = r.pos / 8;
  size_t navBytes = (size_t(width * x.segments) + 7) / 8;
  if (x.segments == 2)
    navBytes = std::max<size_t>(3, navBytes);
  std::vector<int> nav;
  for (int seg = 0; seg < x.segments; ++seg)
    nav.push_back(r.get(unsigned(width)) + 1);
  r.zeros((navStart + navBytes) * 8);
  r.skip(16);
  r.checkCRC(navStart, r.pos / 8);
  bool compact =
      zeroPrediction && nav[0] == 2 && (x.segments == 2 || x.segments == 4);
  for (size_t i = 1; i < nav.size(); ++i)
    compact &= nav[i] == 1;
  size_t start = r.pos / 8;
  if (compact && start + size_t(x.segments + 1) <= n && p[start] == 0x80 &&
      p[start + 1] == 0) {
    for (int seg = 1; seg < x.segments; ++seg)
      require(p[start + size_t(seg) + 1] == 0x40,
              "invalid compact zero continuation");
    r.seek((start + size_t(x.segments) + 1) * 8);
    require(n * 8 - r.pos <= 56, "compact zero tail size");
    r.zeros(n * 8);
    return Planes(4, std::vector<int32_t>(512));
  }
  s.planes = Planes(4, std::vector<int32_t>(512));
  Entropy state;
  for (int seg = 0; seg < x.segments; ++seg) {
    size_t end = r.pos + size_t(nav[seg]) * 8;
    require(end <= n * 8, "private NAVI exceeds frame");
    size_t old = r.limit;
    r.limit = end;
    entropy(r, s, state, seg, x.samples);
    r.zeros(end);
    r.limit = old;
  }
  require(n * 8 - r.pos <= 56, "private tail too large");
  r.zeros(n * 8);
  predict(s);
  Planes height(4);
  unsigned seen = 0;
  for (int c = 0; c < 4; ++c) {
    int dest = (route >> (8 - c * 2)) & 3;
    require(!(seen & (1u << dest)), "private height permutation");
    seen |= 1u << dest;
    height[dest] = std::move(s.planes[c]);
  }
  return height;
}
// Fixed type-2 declarations contain speaker identities and compatibility
// matrices only. Audio is decoded from the following scalable-LSB group.
struct FixedProfile {
  std::vector<uint8_t> metadata;
  int bed;
  std::vector<hdmaxdec_speaker> heights;
  std::vector<std::vector<std::pair<hdmaxdec_speaker, int>>> folds;
};
static const std::vector<FixedProfile> &fixedProfiles() {
  static const std::vector<FixedProfile> profiles = {
      {{2, 0, 8, 0x50, 0x28, 0x4b, 0xfa, 0x69, 0x0d, 0x62, 2, 0xfa, 2, 0xdc,
        0x13, 0x73, 0x0c, 0x71},
       8,
       {HD_TFL, HD_TFR, HD_TBC},
       {{{HD_FL, 23170}}, {{HD_FR, 23170}}, {{HD_BL, 16423}, {HD_BR, 16423}}}},
      {{2, 0, 8, 0x50, 0x28, 0x4b, 0xfa, 0x50, 0xd6, 0x20, 0x2f, 0xa0, 0x2d,
        0xc1, 0x37},
       8,
       {HD_TFL, HD_TFR},
       {{{HD_FL, 23170}}, {{HD_FR, 23170}}}},
      {{2, 0, 8, 0x50, 0x28, 0x4b, 0xfa, 0x65, 9, 0x62, 2, 0xfa, 0x40, 0xde, 3,
        0x70},
       8,
       {HD_TSL, HD_TSR},
       {{{HD_SL, 23170}}, {{HD_SR, 23170}}}},
      {{2, 0, 8, 0x50, 0x0f, 0xfa, 0x70, 0x15, 0xe1, 2, 0xfa, 0x0b, 0x71, 0x37,
        7, 0x72, 0x37, 0x43, 0x70},
       6,
       {HD_TFL, HD_TFC, HD_TFR, HD_TBL, HD_TBR},
       {{{HD_FL, 23170}},
        {{HD_FC, 23170}},
        {{HD_FR, 23170}},
        {{HD_SL, 23170}},
        {{HD_SR, 23170}}}},
      {{2, 0, 8, 0x50, 0x0f, 0xfa, 0x70, 5, 0xe1, 2, 0xfa, 0x0b, 0x71, 0x37,
        0x23, 0x74, 0x37},
       6,
       {HD_TFL, HD_TFR, HD_TBL, HD_TBR},
       {{{HD_FL, 23170}},
        {{HD_FR, 23170}},
        {{HD_SL, 23170}},
        {{HD_SR, 23170}}}},
      {{2, 0, 8, 0x50, 0x0f, 0xfa, 0x68, 5, 0xe1, 2, 0xfa, 0x0b, 0x71, 0x37,
        0x63, 0x1c, 0x40},
       6,
       {HD_TFL, HD_TFR, HD_TBC},
       {{{HD_FL, 23170}}, {{HD_FR, 23170}}, {{HD_SL, 16423}, {HD_SR, 16423}}}}};
  return profiles;
}
static bool fixedPrivate(Audio &a, const XLL &x, const uint8_t *p, size_t n,
                         const std::vector<size_t> &metadata,
                         const std::vector<size_t> &groups) {
  for (const auto &profile : fixedProfiles()) {
    size_t bytes = profile.metadata.size() + 2;
    if (n <= bytes || std::memcmp(p, profile.metadata.data(), bytes - 2))
      continue;
    require(a.layout.count == uint32_t(profile.bed), "fixed speaker bed count");
    require(!crc(p, bytes), "fixed metadata CRC", HD_CRC);
    require(p[bytes] == (profile.bed == 8 ? 2 : 1), "fixed group association");
    Bits r(p + bytes + 1, n - bytes - 1);
    XLL y = x;
    y.width = std::max(8, x.width);
    y.crcMode = 0;
    y.scalable = true;
    y.fixedLSB = 0;
    y.sets.resize(1);
    auto sets = decodeGroups(r, y, true, true);
    auto &h = sets[0].planes;
    require(h.size() == profile.heights.size(), "fixed speaker group count");
    require(metadata.empty() || (metadata == std::vector<size_t>{bytes} &&
                                 groups == std::vector<size_t>{r.pos / 8}),
            "fixed ExSS group size mismatch");
    require(r.size - r.pos / 8 < 4, "fixed speaker tail size");
    r.zeros(r.limit);
    for (size_t c = 0; c < h.size(); ++c) {
      for (const auto &fold : profile.folds[c]) {
        uint32_t dest = 0;
        while (dest < a.layout.count && a.layout.speakers[dest] != fold.first)
          ++dest;
        require(dest < a.layout.count, "fixed fold speaker missing");
        for (size_t i = 0; i < h[c].size(); ++i)
          a.planes[dest][i] =
              sub(a.planes[dest][i], norm(int64_t(h[c][i]) * fold.second, 15));
      }
      a.layout.speakers[a.layout.count++] = profile.heights[c];
      a.planes.push_back(std::move(h[c]));
    }
    a.immersive = 1;
    return true;
  }
  return false;
}
struct ObjectMetadata {
  int count = 0;
  bool reserved = false;
  size_t bytes = 0;
  std::vector<size_t> chunks;
  std::array<std::array<double, 12>, 5> images{};
  std::array<std::array<double, 8>, 5> folds{};
  std::array<int, 5> gains{};
  int heightGain = 0;
};
static int gainQ15(int code) {
  require(code >= 0 && code <= 61, "object gain code");
  return code ? table::downmixCoefficientsQ15[4 * code - 3] : 0;
}
static ObjectMetadata objectMetadata(const uint8_t *p, size_t n) {
  Bits r(p, n);
  auto expect = [&](unsigned bits, uint64_t value) {
    require(r.read(bits) == value, "unsupported object metadata field",
            HD_UNSUPPORTED);
  };
  expect(8, 0xf1);
  expect(8, 0x40);
  expect(5, 0);
  expect(4, 1);
  expect(1, 1);
  expect(1, 0);
  expect(1, 1);
  ObjectMetadata m;
  m.count = r.get(4) + 1;
  require(m.count == 4 || m.count == 5, "object declaration count",
          HD_UNSUPPORTED);
  expect(9, 0x60);
  expect(3, 2);
  expect(12, 0x84b);
  expect(8, 0);
  for (int i = 0; i < m.count; ++i) {
    expect(1, 1);
    expect(2, 3);
    expect(3, unsigned(i));
    expect(2, 1);
    expect(10, 0);
  }
  int referenceOrder[] = {2, 0, 1, 3, 6, 7, 4, 5};
  std::array<std::array<int, 8>, 5> codes{};
  int firstAz = 0, firstEl = 0, firstDistance = 0;
  for (int i = 0; i < m.count; ++i) {
    expect(3, 0);
    expect(7, 0x20);
    expect(1, 1);
    expect(1, 1);
    expect(2, 0);
    int gain = r.get(6);
    require(gain >= 1 && gain <= 61, "object presentation gain escape");
    m.gains[i] = gainQ15(gain);
    int distance = r.get(6), az = r.get(8), el = r.get(7);
    require(az <= 239 && el <= 120, "object spherical position");
    if (!i) {
      firstAz = az;
      firstEl = el;
      firstDistance = distance;
    }
    m.images[i] = objectImage(az, el);
    expect(1, 0);
    expect(1, 1);
    expect(1, 0);
    int mask = r.get(8);
    for (int j = 0; j < 8; ++j)
      if (mask & (1 << j)) {
        int code = r.get(6);
        require(code >= 1 && code <= 61, "object reference gain escape");
        int c = referenceOrder[j];
        codes[i][c] = code;
        m.folds[i][c] = code <= 1 ? 0 : double(gainQ15(code)) / 32768;
      }
  }
  m.reserved = r.get(1);
  require(m.reserved == (m.count == 5), "reserved TFC/object role count");
  if (m.reserved) {
    for (int i = 0; i < m.count; ++i) {
      expect(1, i == 0);
      if (!i) {
        expect(2, 0);
        expect(5, 8);
        expect(8, 0x80);
        expect(1, 1);
        expect(1, 1);
        expect(6, 61);
      }
    }
    require(firstAz == 120 && firstEl == 77 && firstDistance == 63 &&
                m.gains[0] == gainQ15(61) &&
                codes[0] == std::array<int, 8>{46, 46, 58, 0, 0, 0, 0, 0},
            "reserved TFC declaration changed");
  }
  r.zeros((r.pos + 7) & ~size_t(7));
  size_t objectBytes = r.pos / 8;
  expect(8, 3);
  expect(8, 0);
  expect(1, 0);
  expect(4, 1);
  expect(4, 1);
  expect(1, 0);
  expect(1, 0);
  expect(4, 0);
  expect(1, 1);
  expect(6, 61);
  expect(1, 0);
  expect(3, 3);
  expect(16, 0x886b);
  expect(5, 2);
  expect(6, 0);
  expect(1, 1);
  expect(1, 0);
  expect(12, 0x3fa);
  int bedColumns[] = {1, 2, 6, 7}, heightColumns[] = {4, 5, 10, 11};
  int heightCode = m.reserved ? 61 : 55;
  m.heightGain = gainQ15(heightCode);
  for (int i = 0; i < 4; ++i) {
    expect(12, (1 << bedColumns[i]) | (1 << heightColumns[i]));
    expect(6, unsigned(heightCode));
    expect(6, 61);
  }
  r.zeros((r.pos + 7) & ~size_t(7));
  m.bytes = r.pos / 8 + 2;
  r.checkCRC(0, m.bytes);
  m.chunks = {objectBytes, m.bytes - objectBytes - 2};
  return m;
}
static Planes associatedGroup(const uint8_t *p, size_t n, size_t &at,
                              const XLL &x, int association, int channels,
                              size_t declared) {
  require(at <= n && n - at >= 13 && p[at] == association &&
              be32(p + at + 1) == 0x34388c4f,
          "object audio association");
  at += 5;
  Bits r(p + at, n - at);
  require(!r.get(4), "object common version", HD_UNSUPPORTED);
  int header = r.get(8) + 1, bits = r.get(5) + 1;
  size_t frame = size_t(r.read(unsigned(bits)) + 1);
  require(!r.get(4), "object set count");
  XLL y;
  y.segments = 1 << r.get(4);
  y.samples = 1 << r.get(4);
  y.width = r.get(5) + 1;
  y.crcMode = r.get(2);
  y.scalable = r.get(1);
  y.privateOffset = size_t(r.get(5) + 1);
  require(header >= 12 && frame >= size_t(header) && frame - 4 <= n - at &&
              y.segments == x.segments && y.samples == x.samples &&
              y.segments * y.samples == 512 &&
              y.width == std::max(8, x.width) && y.width <= 16 && !y.crcMode &&
              !y.scalable,
          "object shared header contract");
  require(!declared || declared == frame + 1,
          "ExSS object group size mismatch");
  r.checkCRC(0, size_t(header - 4));
  r.size = frame - 4;
  r.limit = r.size * 8;
  r.seek(size_t(header - 4) * 8);
  y.sets.resize(1);
  auto sets = decodeGroups(r, y, true);
  r.zeros(r.limit);
  require(sets[0].count == channels, "object group channel count");
  at += frame - 4;
  return std::move(sets[0].planes);
}
static void dynamicPrivate(Audio &a, const XLL &x, const uint8_t *p, size_t n,
                           Presentation &state,
                           const std::vector<size_t> &metadataSizes,
                           const std::vector<size_t> &groupSizes) {
  require(a.layout.count == 8 && x.segments * x.samples == 512,
          "dynamic bed dimensions");
  ObjectMetadata m = objectMetadata(p, n);
  require(metadataSizes.empty() || metadataSizes == m.chunks,
          "ExSS object metadata sizes");
  require(groupSizes.empty() || groupSizes.size() == 2,
          "ExSS object group count");
  size_t at = m.bytes;
  Planes objects = associatedGroup(p, n, at, x, 3, m.count,
                                   groupSizes.empty() ? 0 : groupSizes[0]);
  Planes heights = associatedGroup(p, n, at, x, 2, 4,
                                   groupSizes.empty() ? 0 : groupSizes[1]);
  require(n - at < 4, "object tail size");
  for (; at < n; ++at)
    require(!p[at], "object tail padding");
  if (state.records != m.count) {
    state.records = m.count;
    state.reference = m.folds;
    state.image = m.images;
  }
  int order[] = {0, 1, 2, 3,
                 6, 7, 4, 5}; // Authoring order to published WAVE bed.
  int destinations[] = {0, 1, 4, 5};
  for (int h = 0; h < 4; ++h) {
    for (size_t i = 0; i < 512; ++i)
      a.planes[destinations[h]][i] =
          sub(a.planes[destinations[h]][i],
              norm(int64_t(heights[h][i]) * m.heightGain, 15));
    a.planes.push_back(std::move(heights[h]));
  }
  hdmaxdec_speaker tops[] = {HD_TFL, HD_TFR, HD_TBL, HD_TBR};
  for (auto top : tops)
    a.layout.speakers[a.layout.count++] = top;
  if (m.reserved) {
    for (int c = 0; c < 3; ++c)
      for (size_t i = 0; i < 512; ++i)
        a.planes[c][i] =
            sub(a.planes[c][i],
                norm(int64_t(objects[0][i]) * gainQ15(c == 2 ? 58 : 46), 15));
    a.planes.push_back(std::move(objects[0]));
    a.layout.speakers[a.layout.count++] = HD_TFC;
  }
  constexpr double transition = 0.001098198738079148;
  for (size_t i = 0; i < 512; ++i) {
    std::array<double, 12> rendered{};
    for (int slot = m.reserved ? 1 : 0; slot < m.count; ++slot) {
      int32_t value = objects[slot][i];
      for (int c = 0; c < 8; ++c) {
        double &g = state.reference[slot][c];
        g += (m.folds[slot][c] - g) * transition;
        int coefficient = int(std::round(g * 32768));
        a.planes[order[c]][i] =
            sub(a.planes[order[c]][i], norm(int64_t(value) * coefficient, 15));
      }
      for (int c = 0; c < 12; ++c) {
        double &g = state.image[slot][c];
        g += (m.images[slot][c] - g) * transition;
        rendered[c] += double(value) * double(m.gains[slot]) / 32768 * g;
      }
    }
    for (int c = 0; c < 12; ++c) {
      int dest = c < 8 ? order[c] : c;
      int64_t value =
          int64_t(a.planes[dest][i]) + int64_t(std::round(rendered[c]));
      require(value >= -8388608 && value <= 8388607,
              "object rendering exceeds signed 24-bit");
      a.planes[dest][i] = int32_t(value);
    }
  }
  a.immersive = m.reserved ? 2 : 1;
}
void decodePrivate(Audio &a, const XLL &x, const uint8_t *p, size_t n,
                   Presentation &presentation,
                   const std::vector<size_t> &metadataSizes,
                   const std::vector<size_t> &groupSizes) {
  if (!n)
    return;
  require(n >= 4, "private presentation prefix");
  if (be32(p) == 0xf14000d3 || be32(p) == 0xf14000d4) {
    dynamicPrivate(a, x, p, n, presentation, metadataSizes, groupSizes);
    return;
  }
  if (fixedPrivate(a, x, p, n, metadataSizes, groupSizes))
    return;
  require(a.layout.count == 8, "private presentation requires 7.1 bed",
          HD_UNSUPPORTED);
  Planes h;
  if (be32(p) == 0x02000850) {
    require(metadataSizes.empty() ||
                (metadataSizes == std::vector<size_t>{21} && n >= 23 &&
                 groupSizes == std::vector<size_t>{n - 23}),
            "standard ExSS navigation sizes");
    h = standardPrivate(p, n, x);
    a.immersive = 1;
    int bed[] = {0, 1, 4, 5};
    for (int c = 0; c < 4; ++c)
      for (size_t i = 0; i < h[c].size(); ++i)
        a.planes[bed[c]][i] =
            sub(a.planes[bed[c]][i], norm(int64_t(h[c][i]) * 23170, 15));
  } else if (be32(p) == 0xf14000d0) {
    require(metadataSizes.empty() ||
                (metadataSizes == std::vector<size_t>{20, 23} &&
                 groupSizes.size() == 2),
            "IMAX ExSS metadata navigation sizes");
    const uint8_t metadata[] = {
        0xf1, 0x40, 0x00, 0xd0, 0x30, 0x28, 0x4b, 0,    0xe1, 0,    2,    0x0c,
        0xf7, 0xf7, 0x89, 0xa8, 0x1f, 0xab, 0xae, 0,    3,    0,    8,    0x81,
        0xf4, 0xe2, 0x1a, 0xc4, 4,    0x7f, 0x40, 0x25, 0xef, 0xa0, 0x49, 0xef,
        0xa8, 0x81, 0xef, 0xb1, 1,    0xef, 0xa0, 0x31, 0xb3};
    require(n > sizeof(metadata) &&
                std::memcmp(p, metadata, sizeof(metadata)) == 0 &&
                !crc(p, sizeof(metadata)),
            "unsupported IMAX metadata", HD_UNSUPPORTED);
    size_t at = sizeof(metadata);
    for (int g = 0; g < 2; ++g) {
      require(at + 5 < n && p[at] == (g ? 2 : 3) &&
                  be32(p + at + 1) == 0x34388c4f,
              "IMAX association");
      at += 5;
      Bits r(p + at, n - at);
      require(!r.get(4), "IMAX version");
      int header = r.get(8) + 1, b = r.get(5) + 1;
      size_t frame = size_t(r.read(unsigned(b)) + 1);
      require(!r.get(4), "IMAX set count");
      XLL y;
      y.segments = 1 << r.get(4);
      y.samples = 1 << r.get(4);
      y.width = r.get(5) + 1;
      y.crcMode = r.get(2);
      y.scalable = r.get(1);
      y.privateOffset = size_t(r.get(5) + 1);
      require(header >= 12 && frame >= size_t(header) && frame - 4 <= n - at &&
                  y.segments == x.segments && y.samples == x.samples &&
                  y.width == std::max(8, x.width) && !y.crcMode && !y.scalable,
              "IMAX shared header contract");
      r.checkCRC(0, size_t(header - 4));
      r.size = frame - 4;
      r.limit = r.size * 8;
      r.seek(size_t(header - 4) * 8);
      y.sets.resize(1);
      auto sets = decodeGroups(r, y, true);
      r.zeros(r.limit);
      require(sets[0].count == (g ? 4 : 1), "IMAX group count");
      for (auto &plane : sets[0].planes)
        h.push_back(std::move(plane));
      require(groupSizes.empty() || groupSizes[size_t(g)] == frame + 1,
              "ExSS associated group size mismatch");
      at += frame - 4;
    }
    require(n - at < 4, "IMAX tail size");
    for (size_t i = at; i < n; ++i)
      require(!p[i], "IMAX tail padding");
    a.immersive = 2;
    for (size_t i = 0; i < h[0].size(); ++i) {
      a.planes[0][i] =
          sub(sub(a.planes[0][i], h[1][i]), norm(int64_t(h[0][i]) * 13818, 15));
      a.planes[1][i] =
          sub(sub(a.planes[1][i], h[2][i]), norm(int64_t(h[0][i]) * 13818, 15));
      a.planes[2][i] = sub(a.planes[2][i], norm(int64_t(h[0][i]) * 27571, 15));
      a.planes[4][i] = sub(a.planes[4][i], h[3][i]);
      a.planes[5][i] = sub(a.planes[5][i], h[4][i]);
    }
    auto tfc = std::move(h[0]);
    h.erase(h.begin());
    h.push_back(std::move(tfc));
  } else
    throw Error(HD_UNSUPPORTED, "unknown private presentation metadata");
  hdmaxdec_speaker positions[] = {HD_TFL, HD_TFR, HD_TBL, HD_TBR, HD_TFC};
  for (size_t c = 0; c < h.size(); ++c) {
    a.layout.speakers[a.layout.count++] = positions[c];
    a.planes.push_back(std::move(h[c]));
  }
}
} // namespace hd
