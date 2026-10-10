// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "internal.hpp"
namespace hd {
struct ExSS {
  size_t header = 0, frame = 0, asset = 0, privateOffset = 0, privateSize = 0;
  int channels = 0;
  bool immersive = false;
};
static ExSS exss(const uint8_t *p, size_t n) {
  Bits r(p, n);
  require(r.read(32) == 0x64582025, "ExSS sync");
  r.skip(8);
  require(!r.get(2), "ExSS index", HD_UNSUPPORTED);
  bool wide = r.get(1);
  ExSS e;
  e.header = size_t(r.get(wide ? 12 : 8) + 1);
  e.frame = size_t(r.get(wide ? 20 : 16) + 1);
  require(e.frame == n && e.header >= 10 && e.header <= n, "invalid ExSS size");
  r.checkCRC(5, e.header);
  r.limit = (e.header - 2) * 8;
  require(r.get(1) && r.get(2) == 2 && r.get(3) == 0 && !r.get(1),
          "ExSS static clock/timestamp", HD_UNSUPPORTED);
  require(!r.get(3) && !r.get(3) && r.get(1) && r.get(8) == 1,
          "ExSS multiple presentations/assets", HD_UNSUPPORTED);
  require(!r.get(1), "ExSS mix metadata", HD_UNSUPPORTED);
  e.asset = size_t(r.get(wide ? 20 : 16) + 1);
  size_t start = r.pos;
  size_t end = start + size_t(r.get(9) + 1) * 8;
  require(end <= r.limit, "ExSS descriptor outside header");
  require(!r.get(3), "ExSS asset index", HD_UNSUPPORTED);
  bool type = r.get(1);
  if (type)
    require(r.get(4) == 13, "ExSS asset type", HD_UNSUPPORTED);
  require(!r.get(1) && !r.get(1), "ExSS text/language metadata",
          HD_UNSUPPORTED);
  require(r.get(5) == 23 && r.get(4) == 12, "ExSS precision/sample rate",
          HD_UNSUPPORTED);
  e.channels = r.get(8) + 1;
  require(r.get(1), "ExSS non-speaker map", HD_UNSUPPORTED);
  bool stereo = e.channels > 2 && r.get(1);
  if (e.channels > 6)
    r.skip(1);
  require(r.get(1), "ExSS missing speaker mask");
  int maskBits = (r.get(2) + 1) * 4;
  uint64_t mask = r.read(unsigned(maskBits));
  require((e.channels == 2 && mask == 2) || (e.channels == 6 && mask == 15) ||
              (e.channels == 8 && mask == 0x84b),
          "ExSS speaker profile", HD_UNSUPPORTED);
  require(!r.get(3), "ExSS remap", HD_UNSUPPORTED);
  bool drc = r.get(1);
  if (drc)
    r.skip(8);
  if (r.get(1))
    r.skip(5);
  if (drc && stereo)
    r.skip(8);
  int coding = r.get(2);
  if (coding == 0) {
    int ext = r.get(12);
    require((ext & 0x200) && !(ext & ~0x201), "ExSS additional components",
            HD_UNSUPPORTED);
  } else
    require(coding == 1, "ExSS coding mode", HD_UNSUPPORTED);
  size_t xll = size_t(r.get(16) + 1);
  require(r.get(1), "ExSS missing XLL sync", HD_UNSUPPORTED);
  r.skip(4);
  int delayBits = r.get(5) + 1;
  require(!r.read(unsigned(delayBits)) && !r.get(16),
          "XLL transport buffering unsupported", HD_UNSUPPORTED);
  r.skip(3);
  require(!r.get(1) && !r.get(1), "ExSS secondary/DRC rev2", HD_UNSUPPORTED);
  require(r.pos <= end, "ExSS descriptor closure");
  size_t remaining = end - r.pos;
  if (remaining == 67) {
    require(r.get(5) == 3, "DTS:X descriptor profile");
    e.privateOffset = size_t(r.get(16));
    require(r.read(24) == 0x1145, "DTS:X signature");
    size_t nibbles = size_t(r.get(16));
    require(nibbles % 2 == 0 && !r.get(6), "DTS:X descriptor payload");
    e.privateSize = 24 + nibbles / 2;
    e.immersive = true;
  } else if (remaining == 95 && type) {
    require(r.get(5) == 3, "IMAX profile");
    e.privateOffset = size_t(r.get(16));
    require(r.read(40) == 0x1112154444, "IMAX signature");
    size_t first = size_t(r.get(15) + 1), second = size_t(r.get(15) + 1);
    require(!r.get(4), "IMAX descriptor padding");
    e.privateSize = 45 + first + second;
    e.privateSize = (e.privateSize + 3) & ~size_t(3);
    e.immersive = true;
  } else
    r.zeros(end);
  require(r.pos == end, "ExSS descriptor boundary");
  if (r.get(1))
    require(!r.get(2) && !r.get(3), "ExSS backward Core association");
  require(e.asset == xll && xll <= n - e.header, "ExSS asset size closure");
  return e;
}
Audio decodeAU(Core &state, const uint8_t *p, size_t n, size_t &consumed) {
  consumed = 0;
  if (n < 10)
    throw Error(HD_NEED_MORE, "access unit prefix");
  size_t at = 0, coreSize = 0;
  uint32_t sync = be32(p);
  if (sync == 0x7ffe8001) {
    Bits r(p, 10);
    r.skip(32 + 1 + 5 + 1 + 7);
    coreSize = size_t(r.get(14) + 1);
    require(coreSize >= 96, "invalid Core frame size");
    at = (coreSize + 3) & ~size_t(3);
    if (n < at + 4)
      throw Error(HD_NEED_MORE, "Core companion prefix");
    if (be32(p + at) != 0x64582025) {
      require(n >= coreSize, "Core frame incomplete", HD_NEED_MORE);
      Audio a = state.decode(p, coreSize);
      consumed = coreSize;
      return a;
    }
  } else
    require(sync == 0x64582025 || sync == 0x41a29547,
            "unsupported elementary sync", HD_UNSUPPORTED);
  if (n - at < 10)
    throw Error(HD_NEED_MORE, "extension prefix");
  size_t frame = 0, header = 0;
  if (be32(p + at) == 0x64582025) {
    Bits r(p + at, 10);
    r.skip(42);
    bool wide = r.get(1);
    header = size_t(r.get(wide ? 12 : 8) + 1);
    frame = size_t(r.get(wide ? 20 : 16) + 1);
  } else {
    Bits r(p + at, 10);
    r.skip(36);
    header = size_t(r.get(8) + 1);
    int bits = r.get(5) + 1;
    frame = size_t(r.read(unsigned(bits)) + 1);
  }
  require(frame >= header && frame <= 1u << 20,
          "extension frame size exceeds bound");
  if (n - at < frame)
    throw Error(HD_NEED_MORE, "extension frame incomplete");
  Audio core;
  const Audio *corePtr = nullptr;
  Core next = state;
  // Commit Core history only after the entire public/private AU has closed.
  if (coreSize) {
    core = next.decode(p, coreSize);
    corePtr = &core;
  }
  const uint8_t *xll = p + at;
  size_t xllSize = frame;
  ExSS e;
  if (be32(xll) == 0x64582025) {
    e = exss(xll, frame);
    xllSize = e.asset;
    xll += e.header;
  }
  XLL x = decodeXLL(xll, xllSize);
  Audio a = assemble(x, corePtr);
  require(!e.channels || a.layout.count == uint32_t(e.channels),
          "ExSS/XLL channel count mismatch");
  require(x.privateOffset <= xllSize, "XLL band alignment outside frame");
  size_t privateSize = xllSize - x.privateOffset;
  if (privateSize >= 4 && be32(xll + x.privateOffset) != 0) {
    if (e.immersive)
      require(e.privateOffset == x.privateOffset &&
                  e.privateSize == privateSize,
              "ExSS/private range mismatch");
    decodePrivate(a, x, xll + x.privateOffset, privateSize);
  } else if (e.immersive)
    throw Error(HD_INVALID, "advertised private presentation is missing");
  for (const auto &plane : a.planes)
    for (int32_t v : plane)
      require(v >= -8388608 && v <= 8388607,
              "reconstructed PCM outside signed 24-bit");
  state = std::move(next);
  consumed = at + frame;
  return a;
}
} // namespace hd
struct hdmaxdec_decoder {
  hd::Core core;
  hd::Audio audio;
  std::string error;
};
extern "C" {
hdmaxdec_decoder *hdmaxdec_create(void) {
  try {
    return new hdmaxdec_decoder;
  } catch (...) {
    return nullptr;
  }
}
void hdmaxdec_destroy(hdmaxdec_decoder *d) { delete d; }
void hdmaxdec_reset(hdmaxdec_decoder *d) {
  if (d) {
    d->core = {};
    d->audio = {};
    d->error.clear();
  }
}
int hdmaxdec_decode(hdmaxdec_decoder *d, const uint8_t *p, size_t n,
                    size_t *consumed, hdmaxdec_frame *f) {
  if (!d || !p || !consumed || !f)
    return HD_INVALID;
  *consumed = 0;
  *f = {};
  try {
    size_t used = 0;
    d->audio = hd::decodeAU(d->core, p, n, used);
    f->sample_rate = 48000;
    f->bit_depth = 24;
    f->sample_count = uint32_t(d->audio.planes[0].size());
    f->layout = d->audio.layout;
    f->immersive = d->audio.immersive;
    for (size_t c = 0; c < d->audio.planes.size(); ++c)
      f->planes[c] = d->audio.planes[c].data();
    *consumed = used;
    d->error.clear();
    return HD_OK;
  } catch (const hd::Error &e) {
    d->error = e.what();
    return e.status;
  } catch (const std::bad_alloc &) {
    d->error = "allocation failed";
    return HD_MEMORY;
  } catch (const std::exception &e) {
    d->error = e.what();
    return HD_INVALID;
  }
}
const char *hdmaxdec_error(const hdmaxdec_decoder *d) {
  return d ? d->error.c_str() : "null decoder";
}
const char *hdmaxdec_version(void) { return "hdmaxdec 0.1.0"; }
int hdmaxdec_decode_core(hdmaxdec_decoder *d, const uint8_t *p, size_t n,
                         size_t *consumed, hdmaxdec_frame *f) {
  if (!d || !p || !consumed || !f)
    return HD_INVALID;
  *consumed = 0;
  *f = {};
  try {
    if (n < 10)
      throw hd::Error(HD_NEED_MORE, "Core prefix");
    hd::require(hd::be32(p) == 0x7ffe8001, "Core sync");
    hd::Bits r(p, 10);
    r.skip(46);
    size_t size = size_t(r.get(14) + 1);
    if (n < size)
      throw hd::Error(HD_NEED_MORE, "Core frame incomplete");
    hd::Core next = d->core;
    d->audio = next.decode(p, size);
    d->core = std::move(next);
    f->sample_rate = 48000;
    f->bit_depth = 24;
    f->sample_count = uint32_t(d->audio.planes[0].size());
    f->layout = d->audio.layout;
    for (size_t c = 0; c < d->audio.planes.size(); ++c)
      f->planes[c] = d->audio.planes[c].data();
    *consumed = size;
    d->error.clear();
    return HD_OK;
  } catch (const hd::Error &e) {
    d->error = e.what();
    return e.status;
  } catch (const std::bad_alloc &) {
    return HD_MEMORY;
  } catch (const std::exception &e) {
    d->error = e.what();
    return HD_INVALID;
  }
}
}
