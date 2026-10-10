// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "internal.hpp"
#include "tables.hpp"
namespace hd {
// The staged inverse transform rounds and saturates between butterflies.
// A floating DCT with a final clamp changes the Core samples used by XLL.
static std::array<int32_t, 32> imdct(const std::array<int32_t, 32> &input) {
  std::array<int32_t, 32> a{}, b{};
  int64_t magnitude = 0;
  for (int32_t v : input)
    magnitude += std::abs(int64_t(v));
  unsigned shift = magnitude > 0x400000 ? 2 : 0;
  for (int i = 0; i < 32; ++i)
    a[i] = wrap(asr(int64_t(input[i]) + (shift ? 2 : 0), shift));
  auto sumA = [](const auto &in, int off, auto &out, int dest, int len) {
    for (int i = 0; i < len; ++i)
      out[dest + i] = add(in[off + i * 2], in[off + i * 2 + 1]);
  };
  auto sumB = [](const auto &in, int off, auto &out, int dest, int len) {
    out[dest] = in[off];
    for (int i = 1; i < len; ++i)
      out[dest + i] = add(in[off + i * 2], in[off + i * 2 - 1]);
  };
  auto clipAll = [](auto &v) {
    for (auto &x : v)
      x = clip(x);
  };
  sumA(a, 0, b, 0, 16);
  sumB(a, 0, b, 16, 16);
  clipAll(b);
  sumA(b, 0, a, 0, 8);
  sumB(b, 0, a, 8, 8);
  for (int i = 0; i < 8; ++i)
    a[16 + i] = b[16 + i * 2];
  a[24] = b[17];
  for (int i = 1; i < 8; ++i)
    a[24 + i] = add(b[16 + i * 2 - 1], b[16 + i * 2 + 1]);
  clipAll(a);
  for (int row = 0; row < 8; ++row) {
    int64_t v = 0;
    for (int c = 0; c < 8; ++c)
      v += int64_t(table::dctACoefficients[row * 8 + c]) * a[c];
    b[row] = norm(v, 23);
  }
  for (int off = 8; off < 32; off += 8)
    for (int row = 0; row < 8; ++row) {
      int64_t v = int64_t(a[off]) * 8388608;
      for (int c = 0; c < 7; ++c)
        v += int64_t(table::dctBCoefficients[row * 7 + c]) * a[off + 1 + c];
      b[off + row] = norm(v, 23);
    }
  clipAll(b);
  for (int i = 0; i < 8; ++i)
    a[i] = norm(int64_t(table::modACoefficients[i]) * add(b[i], b[8 + i]), 23);
  for (int i = 8; i < 16; ++i) {
    int rev = 15 - i;
    a[i] =
        norm(int64_t(table::modACoefficients[i]) * sub(b[rev], b[8 + rev]), 23);
  }
  for (int i = 0; i < 8; ++i)
    b[24 + i] = norm(int64_t(table::modBCoefficients[i]) * b[24 + i], 23);
  for (int i = 0; i < 8; ++i) {
    a[16 + i] = add(b[16 + i], b[24 + i]);
    a[24 + i] = sub(b[23 - i], b[31 - i]);
  }
  clipAll(a);
  for (int i = 0; i < 16; ++i)
    b[i] = norm(int64_t(table::modCCoefficients[i]) * add(a[i], a[16 + i]), 23);
  for (int i = 16; i < 32; ++i) {
    int rev = 31 - i;
    b[i] = norm(int64_t(table::modCCoefficients[i]) * sub(a[rev], a[16 + rev]),
                23);
  }
  for (auto &v : b)
    v = clip(int64_t(v) * (int64_t(1) << shift));
  std::array<int32_t, 32> out{};
  for (int i = 0; i < 16; ++i) {
    out[i] = clip(int64_t(b[i]) - b[31 - i]);
    out[16 + i] = clip(int64_t(b[i]) + b[31 - i]);
  }
  return out;
}
static std::array<int32_t, 32> synthesis(const std::array<int32_t, 32> &input,
                                         Core::Synth &s, bool perfect) {
  auto t = imdct(input);
  for (int i = 0; i < 32; ++i)
    s.history[s.offset + i] = t[i];
  const int32_t *w =
      perfect ? table::perfectSynthesisFIR : table::nonPerfectSynthesisFIR;
  std::array<int32_t, 32> out{}, next{};
  for (int i = 0; i < 16; ++i) {
    int64_t a = int64_t(s.delay[i]) * 2097152,
            b = int64_t(s.delay[i + 16]) * 2097152, c = 0, d = 0;
    for (int p = 0; p < 512; p += 64) {
      int base = (s.offset + p) & 511;
      a += int64_t(w[i + p]) * s.history[base + i];
      b += int64_t(w[i + p + 16]) * s.history[base + 15 - i];
      c += int64_t(w[i + p + 32]) * s.history[base + 16 + i];
      d += int64_t(w[i + p + 48]) * s.history[base + 31 - i];
    }
    out[i] = clip(norm(a, 21));
    out[i + 16] = clip(norm(b, 21));
    next[i] = norm(c, 21);
    next[i + 16] = norm(d, 21);
  }
  s.delay = next;
  s.offset = (s.offset - 32) & 511;
  return out;
}
static int32_t scaleFactor(int i) {
  require(i >= 0 && i < 128 && table::scaleFactorQuant7[i] != 0,
          "invalid Core scale index");
  return table::scaleFactorQuant7[i];
}
static int32_t dequant(int32_t q, int allocation, int32_t scale,
                       bool lossless) {
  if (!allocation)
    return 0;
  int64_t p = int64_t(lossless ? table::losslessQuant[allocation]
                               : table::lossyQuant[allocation]) *
              scale;
  unsigned shift = 0;
  while (p > (int64_t(1) << 23)) {
    p = asr(p, 1);
    ++shift;
  }
  require(shift <= 21, "quantizer normalization overflow");
  return clip(norm(int64_t(q) * p, 22 - shift));
}
static int transition(Bits &r, int selector) {
  if (selector == 3)
    return r.get(2);
  const int map[3][4] = {{0, 1, 2, 3}, {3, 0, 1, 2}, {2, 3, 0, 1}};
  for (int i = 0; i < 3; ++i)
    if (!r.get(1))
      return map[selector][i];
  return map[selector][3];
}
static std::array<int32_t, 8> codewords(Bits &r, int allocation, int selector) {
  std::array<int32_t, 8> q{};
  if (!allocation)
    return q;
  const int groups[] = {1, 3, 3, 3, 3, 7, 7, 7, 7, 7},
            widths[] = {7, 10, 12, 13, 15, 17, 19};
  require(allocation > 0 && allocation <= 26, "Core bit allocation");
  if (allocation <= 10)
    require(selector >= groups[allocation - 1],
            "Core Huffman codewords outside encoder profile", HD_UNSUPPORTED);
  if (allocation <= 7) {
    int levels = table::quantLevels[allocation];
    for (int half = 0; half < 2; ++half) {
      int code = r.get(unsigned(widths[allocation - 1]));
      for (int i = 0; i < 4; ++i) {
        q[half * 4 + i] = code % levels - (levels - 1) / 2;
        code /= levels;
      }
      require(!code, "invalid Core block code");
    }
  } else
    for (auto &v : q)
      v = r.signedBits(unsigned(allocation - 3));
  return q;
}
Audio Core::decode(const uint8_t *p, size_t n) {
  // Decode in stream order. QMF, predictor and decimated-LFE histories belong
  // to the context, while all bitstream and subframe workspaces are bounded.
  Bits r(p, n);
  require(r.read(32) == 0x7ffe8001, "Core sync");
  r.skip(1);
  require(r.get(5) == 31, "Core short frame", HD_UNSUPPORTED);
  bool cpf = r.get(1);
  int blocks = r.get(7) + 1, frame = r.get(14) + 1;
  require(blocks % 8 == 0 && blocks <= 128 && frame >= 96 && size_t(frame) == n,
          "invalid Core frame dimensions");
  require(r.get(6) == 9 && r.get(4) == 13,
          "Core mode/sample rate outside encoder profile", HD_UNSUPPORTED);
  bool lossless = r.get(5) == 31;
  require(!r.get(1), "Core reserved bit");
  bool dyn = r.get(1);
  r.skip(1 + 1 + 1 + 3 + 1);
  bool sync = r.get(1);
  require(r.get(2) == 2, "Core LFE mode", HD_UNSUPPORTED);
  bool history = r.get(1);
  require(!cpf, "Core CRC profile not qualified", HD_UNSUPPORTED);
  bool perfect = r.get(1);
  r.skip(4 + 2 + 3);
  require(!r.get(1) && !r.get(1), "Core sum/difference", HD_UNSUPPORTED);
  r.skip(4);
  if (!history) {
    adpcm = {};
  }
  int subframes = r.get(4) + 1;
  require(r.get(3) == 4, "Core primary channel count");
  std::array<int, 5> active{}, vq{}, joint{}, trans{}, scale{}, allocSel{};
  for (auto &v : active) {
    v = r.get(5) + 2;
    require(v <= 32, "Core active subbands");
  }
  for (auto &v : vq) {
    v = r.get(5) + 1;
    require(v <= 32, "Core VQ start");
  }
  for (auto &v : joint) {
    v = r.get(3);
    require(!v, "Core joint intensity", HD_UNSUPPORTED);
  }
  for (auto &v : trans)
    v = r.get(2);
  for (auto &v : scale) {
    v = r.get(3);
    require(v == 5 || v == 6, "Core Huffman scale outside encoder profile",
            HD_UNSUPPORTED);
  }
  for (auto &v : allocSel) {
    v = r.get(3);
    require(v == 5 || v == 6, "Core Huffman allocation outside encoder profile",
            HD_UNSUPPORTED);
  }
  std::array<std::array<int, 10>, 5> selectors{}, adjust{};
  const int widths[] = {1, 2, 2, 2, 2, 3, 3, 3, 3, 3},
            groups[] = {1, 3, 3, 3, 3, 7, 7, 7, 7, 7};
  for (int j = 0; j < 10; ++j)
    for (int c = 0; c < 5; ++c)
      selectors[c][j] = r.get(unsigned(widths[j]));
  for (int j = 0; j < 10; ++j)
    for (int c = 0; c < 5; ++c)
      if (selectors[c][j] < groups[j])
        adjust[c][j] = r.get(2);
  std::array<std::array<std::vector<int32_t>, 32>, 5> bands;
  for (auto &channel : bands)
    for (auto &band : channel)
      band.resize(size_t(blocks));
  std::vector<int32_t> lfeSamples;
  int offset = 0;
  for (int sf = 0; sf < subframes; ++sf) {
    int subs = r.get(2) + 1;
    r.skip(3);
    int samples = subs * 8;
    require(offset + samples <= blocks, "Core subframe timeline");
    std::array<std::array<int, 32>, 5> pred{}, vector{}, alloc{}, tr{}, hf{};
    std::array<std::array<std::array<int, 2>, 32>, 5> sc{};
    for (int c = 0; c < 5; ++c)
      for (int b = 0; b < active[c]; ++b)
        pred[c][b] = r.get(1);
    for (int c = 0; c < 5; ++c)
      for (int b = 0; b < active[c]; ++b)
        if (pred[c][b])
          vector[c][b] = r.get(12);
    for (int c = 0; c < 5; ++c)
      for (int b = 0; b < vq[c]; ++b) {
        alloc[c][b] = r.get(unsigned(allocSel[c] - 1));
        require(alloc[c][b] <= 26, "invalid Core allocation");
      }
    if (subs > 1)
      for (int c = 0; c < 5; ++c)
        for (int b = 0; b < vq[c]; ++b)
          if (alloc[c][b])
            tr[c][b] = transition(r, trans[c]);
    for (int c = 0; c < 5; ++c) {
      for (int b = 0; b < vq[c]; ++b)
        if (alloc[c][b]) {
          sc[c][b][0] = r.get(unsigned(scale[c] + 1));
          if (tr[c][b])
            sc[c][b][1] = r.get(unsigned(scale[c] + 1));
        }
      for (int b = vq[c]; b < active[c]; ++b)
        sc[c][b][0] = r.get(unsigned(scale[c] + 1));
    }
    if (dyn)
      r.skip(8);
    for (int c = 0; c < 5; ++c)
      for (int b = vq[c]; b < active[c]; ++b)
        hf[c][b] = r.get(10);
    std::vector<int32_t> lfeQ(size_t(subs * 4));
    for (auto &v : lfeQ)
      v = r.signedBits(8);
    int lfScale = r.get(8);
    int32_t ls = norm(int64_t(4697620) * scaleFactor(lfScale), 23);
    for (int32_t v : lfeQ)
      lfeSamples.push_back(clip(asr(int64_t(v) * ls, 4)));
    for (int ss = 0; ss < subs; ++ss) {
      for (int c = 0; c < 5; ++c)
        for (int b = 0; b < vq[c]; ++b) {
          int allocation = alloc[c][b];
          auto q = codewords(r, allocation,
                             allocation && allocation <= 10
                                 ? selectors[c][allocation - 1]
                                 : 0);
          int32_t s =
              allocation
                  ? scaleFactor(sc[c][b][tr[c][b] && ss >= tr[c][b] ? 1 : 0])
                  : 0;
          if (allocation && allocation <= 10 &&
              selectors[c][allocation - 1] < groups[allocation - 1])
            s = clip(asr(
                int64_t(table::scaleFactorAdjust[adjust[c][allocation - 1]]) *
                    s,
                22));
          for (int i = 0; i < 8; ++i)
            bands[c][b][offset + ss * 8 + i] =
                dequant(q[i], allocation, s, lossless);
        }
      if (sync || ss == subs - 1)
        require(r.get(16) == 65535, "Core DSYNC");
    }
    for (int c = 0; c < 5; ++c)
      for (int b = vq[c]; b < active[c]; ++b) {
        int32_t s = scaleFactor(sc[c][b][0]);
        for (int i = 0; i < samples; ++i)
          bands[c][b][offset + i] = clip(asr(
              int64_t(table::highFrequencyVQ[hf[c][b] * 32 + i % 32]) * s + 8,
              4));
      }
    for (int c = 0; c < 5; ++c)
      for (int b = 0; b < active[c]; ++b) {
        auto &hist = adpcm[c][b];
        for (int i = 0; i < samples; ++i) {
          int32_t v = bands[c][b][offset + i];
          if (pred[c][b]) {
            int64_t pr = 0;
            for (int t = 0; t < 4; ++t)
              pr += int64_t(hist[3 - t]) * table::adpcmVQ[vector[c][b] * 4 + t];
            v = clip(int64_t(v) + norm(pr, 13));
            bands[c][b][offset + i] = v;
          }
          for (int t = 0; t < 3; ++t)
            hist[t] = hist[t + 1];
          hist[3] = v;
        }
      }
    offset += samples;
  }
  require(offset == blocks && lfeSamples.size() == size_t(blocks / 2),
          "Core timeline does not close");
  Planes primary(5);
  for (int c = 0; c < 5; ++c)
    for (int b = 0; b < blocks; ++b) {
      std::array<int32_t, 32> input{};
      for (int i = 0; i < 32; ++i)
        input[i] = bands[c][i][b];
      auto out = synthesis(input, synth[c], perfect);
      primary[c].insert(primary[c].end(), out.begin(), out.end());
    }
  std::vector<int32_t> source(lfe.begin(), lfe.end());
  source.insert(source.end(), lfeSamples.begin(), lfeSamples.end());
  std::vector<int32_t> outLFE(lfeSamples.size() * 64);
  for (size_t i = 0; i < lfeSamples.size(); ++i)
    for (int phase = 0; phase < 32; ++phase) {
      int64_t a = 0, b = 0;
      for (int t = 0; t < 8; ++t) {
        a +=
            int64_t(table::lfeFIR64[phase * 8 + t]) * source[8 + i - size_t(t)];
        b += int64_t(table::lfeFIR64[255 - phase * 8 - t]) *
             source[8 + i - size_t(t)];
      }
      outLFE[i * 64 + size_t(phase)] = clip(norm(a, 23));
      outLFE[i * 64 + 32 + size_t(phase)] = clip(norm(b, 23));
    }
  std::copy(source.end() - 8, source.end(), lfe.begin());
  Audio a;
  a.layout.count = 6;
  hdmaxdec_speaker speakers[] = {HD_FL, HD_FR, HD_FC, HD_LFE, HD_SL, HD_SR};
  std::copy(std::begin(speakers), std::end(speakers), a.layout.speakers);
  a.planes = {std::move(primary[1]), std::move(primary[2]),
              std::move(primary[0]), std::move(outLFE),
              std::move(primary[3]), std::move(primary[4])};
  return a;
}
} // namespace hd
