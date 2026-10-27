// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "internal.hpp"
#include <cstdio>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#define HD_SEEK _fseeki64
#define HD_TELL _ftelli64
#else
#define HD_SEEK fseeko
#define HD_TELL ftello
#endif
struct hdmaxdec_file {
  struct SeekPoint {
    uint64_t offset = 0, produced = 0, trim = 0;
    hd::Core core;
    hd::Presentation presentation;
  };
  std::vector<SeekPoint> seekPoints;
  FILE *fp = nullptr;
  hdmaxdec_decoder *decoder = nullptr;
  std::vector<uint8_t> buffer;
  size_t head = 0;
  uint64_t start = 0, length = 0, offset = 0, total = UINT64_MAX, produced = 0;
  uint64_t trim = 0, initialTrim = 0;
  std::string error;
  hdmaxdec_frame pending{};
  bool hasPending = false;
  bool coreOnly = false;
  ~hdmaxdec_file() {
    if (fp)
      std::fclose(fp);
    hdmaxdec_destroy(decoder);
  }
};
namespace {
uint64_t big64(const uint8_t *p) {
  return uint64_t(hd::be32(p)) << 32 | hd::be32(p + 4);
}
bool readAt(FILE *fp, uint64_t at, void *p, size_t n) {
  return at <= uint64_t(INT64_MAX) && HD_SEEK(fp, int64_t(at), SEEK_SET) == 0 &&
         std::fread(p, 1, n, fp) == n;
}
struct ScanWindow {
  hdmaxdec_file *file;
  std::vector<uint8_t> &bytes;
  uint64_t begin = UINT64_MAX;
  explicit ScanWindow(hdmaxdec_file *f) : file(f), bytes(f->buffer) {
    bytes.clear();
    f->head = 0;
  }
  ~ScanWindow() {
    bytes.clear();
    file->head = 0;
  }
  const uint8_t *get(uint64_t at, size_t count) {
    hd::require(at <= file->length && count <= file->length - at &&
                    count <= (1u << 20),
                "AU scan exceeds input bound");
    if (begin == UINT64_MAX || at < begin || at - begin > bytes.size() ||
        count > bytes.size() - size_t(at - begin)) {
      begin = at;
      bytes.resize(size_t(std::min<uint64_t>(file->length - at, 1u << 20)));
      hd::require(
          readAt(file->fp, file->start + at, bytes.data(), bytes.size()),
          "AU scan read failed", HD_IO);
    }
    return bytes.data() + size_t(at - begin);
  }
};
struct ScanAU {
  uint64_t end = 0, samples = 0;
  size_t coreSize = 0;
};
ScanAU scanAU(hdmaxdec_file *f, ScanWindow &window, uint64_t at) {
  ScanAU au;
  const uint8_t *p = window.get(at, 10);
  uint32_t sync = hd::be32(p);
  uint64_t next = at;
  uint64_t coreSamples = 0;
  if (sync == 0x7ffe8001) {
    hd::Bits r(p, 10);
    r.skip(39);
    coreSamples = uint64_t(r.get(7) + 1) * 32;
    au.coreSize = size_t(r.get(14) + 1);
    hd::require(au.coreSize >= 96 && au.coreSize <= f->length - at,
                "Core scan exceeds stream");
    if (f->coreOnly) {
      au.end = at + au.coreSize;
      au.samples = coreSamples;
      return au;
    }
    next += (au.coreSize + 3) & ~size_t(3);
    p = window.get(next, 10);
    sync = hd::be32(p);
  }
  uint64_t xll = next;
  if (sync == 0x64582025) {
    hd::Bits r(p, 10);
    r.skip(42);
    bool wide = r.get(1);
    size_t header = size_t(r.get(wide ? 12 : 8) + 1);
    size_t bytes = size_t(r.get(wide ? 20 : 16) + 1);
    hd::require(header <= bytes && bytes <= f->length - next, "ExSS scan size");
    au.end = next + bytes;
    xll = next + header;
  } else
    hd::require(sync == 0x41a29547, "unsupported scan sync", HD_UNSUPPORTED);
  p = window.get(xll, 20);
  hd::Bits r(p, 20);
  hd::require(r.read(32) == 0x41a29547, "XLL scan sync");
  r.skip(12);
  int bits = r.get(5) + 1;
  uint64_t bytes = r.read(unsigned(bits)) + 1;
  r.skip(4);
  au.samples = uint64_t(1 << r.get(4)) * uint64_t(1 << r.get(4));
  hd::require(bytes <= f->length - xll && au.samples <= 65536 &&
                  (!au.coreSize || coreSamples == au.samples),
              "XLL scan dimensions");
  if (!au.end)
    au.end = xll + bytes;
  hd::require(au.end > at && au.end - at <= (1u << 20) && xll + bytes <= au.end,
              "AU scan boundary");
  return au;
}
int readFrame(hdmaxdec_file *f, hdmaxdec_frame *out) {
  // Retain one compressed window and compact only across AU boundaries.
  // The exported PCM borrows the decoder's frame, not the input window.
  while (true) {
    if (f->offset == f->length) {
      if (f->total != UINT64_MAX && f->produced != f->total) {
        f->error = "programme sample count does not close";
        return HD_INVALID;
      }
      return HD_NEED_MORE;
    }
    if (f->head == f->buffer.size()) {
      size_t size = size_t(std::min<uint64_t>(f->length - f->offset, 1u << 20));
      f->buffer.resize(size);
      f->head = 0;
      if (!readAt(f->fp, f->start + f->offset, f->buffer.data(), size)) {
        f->error = "input read failed";
        return HD_IO;
      }
    }
    size_t used = 0;
    int status = (f->coreOnly ? hdmaxdec_decode_core : hdmaxdec_decode)(
        f->decoder, f->buffer.data() + f->head, f->buffer.size() - f->head,
        &used, out);
    if (status == HD_NEED_MORE &&
        f->buffer.size() - f->head < f->length - f->offset) {
      size_t kept = f->buffer.size() - f->head;
      size_t size = size_t(std::min<uint64_t>(f->length - f->offset, 1u << 20));
      if (kept == size) {
        f->error = "access unit exceeds input bound";
        return HD_INVALID;
      }
      std::memmove(f->buffer.data(), f->buffer.data() + f->head, kept);
      f->buffer.resize(size);
      f->head = 0;
      if (!readAt(f->fp, f->start + f->offset + kept, f->buffer.data() + kept,
                  size - kept)) {
        f->error = "input read failed";
        return HD_IO;
      }
      continue;
    }
    if (status != HD_OK) {
      f->error = hdmaxdec_error(f->decoder);
      return status == HD_NEED_MORE ? HD_INVALID : status;
    }
    f->offset += used;
    f->head += used;
    uint32_t skip = uint32_t(std::min<uint64_t>(f->trim, out->sample_count));
    f->trim -= skip;
    out->sample_count -= skip;
    for (uint32_t c = 0; c < out->layout.count; ++c)
      out->planes[c] += skip;
    if (!out->sample_count)
      continue;
    if (f->total != UINT64_MAX) {
      out->sample_count = uint32_t(
          std::min<uint64_t>(out->sample_count, f->total - f->produced));
    }
    f->produced += out->sample_count;
    if (!out->sample_count)
      continue;
    return HD_OK;
  }
}
} // namespace
extern "C" {
hdmaxdec_file *hdmaxdec_file_open(const char *path) {
  if (!path)
    return nullptr;
  hdmaxdec_file *f = nullptr;
  try {
    f = new hdmaxdec_file;
#ifdef _WIN32
    int chars = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1,
                                    nullptr, 0);
    hd::require(chars > 0, "invalid UTF-8 path");
    std::vector<wchar_t> wide(size_t(chars), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide.data(),
                        chars);
    f->fp = _wfopen(wide.data(), L"rb");
#else
    f->fp = std::fopen(path, "rb");
#endif
    if (!f->fp)
      throw hd::Error(HD_IO, "input open failed");
    hd::require(!HD_SEEK(f->fp, 0, SEEK_END), "input seek failed", HD_IO);
    auto end = HD_TELL(f->fp);
    hd::require(end >= 4, "empty or truncated input", HD_IO);
    f->length = uint64_t(end);
    uint8_t header[26];
    hd::require(readAt(f->fp, 0, header, 8), "input header", HD_IO);
    if (!std::memcmp(header, "DTSHDHDR", 8)) {
      uint64_t at = 0, streamStart = 0, streamLength = 0;
      while (at < f->length) {
        hd::require(f->length - at >= 16 && readAt(f->fp, at, header, 16),
                    "container chunk header", HD_IO);
        uint64_t size = big64(header + 8), payload = at + 16;
        hd::require(size <= f->length - payload,
                    "container chunk exceeds file");
        if (!std::memcmp(header, "STRMDATA", 8)) {
          hd::require(!streamStart, "multiple stream chunks", HD_UNSUPPORTED);
          streamStart = payload;
          streamLength = size;
        } else if (!std::memcmp(header, "AUPR-HDR", 8)) {
          hd::require(size >= 21 && readAt(f->fp, payload, header, 21),
                      "container programme header");
          f->total = 0;
          for (int j = 12; j < 17; ++j)
            f->total = (f->total << 8) | header[j];
          f->initialTrim = hd::be16(header + 19);
          hd::require(f->total > 0 && header[3] == 0 && header[4] == 0xbb &&
                          header[5] == 0x80 && hd::be16(header + 10) == 512,
                      "unsupported programme timing", HD_UNSUPPORTED);
        }
        at = payload + size;
      }
      hd::require(streamStart && streamLength, "missing stream chunk");
      f->start = streamStart;
      f->length = streamLength;
    } else if (hd::be32(header) == 0x7ffe8001) {
      hd::require(readAt(f->fp, 0, header, 10), "Core prefix", HD_IO);
      hd::Bits r(header, 10);
      r.skip(46);
      size_t bytes = size_t(r.get(14) + 1);
      f->coreOnly = f->length == bytes ||
                    (readAt(f->fp, (bytes + 3) & ~size_t(3), header, 4) &&
                     hd::be32(header) != 0x64582025);
      f->initialTrim = f->coreOnly ? 0 : 1024;
    }
    f->trim = f->initialTrim;
    f->decoder = hdmaxdec_create();
    hd::require(f->decoder, "decoder allocation", HD_MEMORY);
    return f;
  } catch (...) {
    delete f;
    return nullptr;
  }
}
int hdmaxdec_file_read(hdmaxdec_file *f, hdmaxdec_frame *out) {
  if (!f || !out)
    return HD_INVALID;
  try {
    if (f->hasPending) {
      *out = f->pending;
      f->hasPending = false;
      return HD_OK;
    }
    return readFrame(f, out);
  } catch (const std::bad_alloc &) {
    f->error = "allocation failed";
    return HD_MEMORY;
  } catch (const std::exception &e) {
    f->error = e.what();
    return HD_INVALID;
  }
}
int hdmaxdec_file_seek_progress(hdmaxdec_file *f, uint64_t sample,
                                hdmaxdec_progress callback, void *context) {
  if (!f || (f->total != UINT64_MAX && sample > f->total))
    return HD_INVALID;
  try {
    // Restore complete Core history, not just an XLL NAVI byte offset.
    // Clients without a prepared session index retain replay from the start.
    hdmaxdec_reset(f->decoder);
    f->offset = 0;
    f->buffer.clear();
    f->head = 0;
    f->produced = 0;
    f->trim = f->initialTrim;
    f->hasPending = false;
    f->error.clear();
    auto point =
        std::upper_bound(f->seekPoints.begin(), f->seekPoints.end(), sample,
                         [](uint64_t value, const hdmaxdec_file::SeekPoint &p) {
                           return value < p.produced;
                         });
    if (point != f->seekPoints.begin()) {
      --point;
      hd::coreState(f->decoder) = point->core;
      hd::presentationState(f->decoder) = point->presentation;
      f->offset = point->offset;
      f->produced = point->produced;
      f->trim = point->trim;
    }
    while (f->produced < sample) {
      if (callback && !callback(context, f->produced, sample))
        return HD_CANCELLED;
      hdmaxdec_frame frame{};
      uint64_t before = f->produced;
      int s = readFrame(f, &frame);
      if (s)
        return s;
      if (f->produced > sample) {
        uint32_t skip = uint32_t(sample - before);
        frame.sample_count -= skip;
        for (uint32_t c = 0; c < frame.layout.count; ++c)
          frame.planes[c] += skip;
        f->pending = frame;
        f->hasPending = true;
      }
    }
    return HD_OK;
  } catch (...) {
    return HD_INVALID;
  }
}
int hdmaxdec_file_seek(hdmaxdec_file *f, uint64_t sample) {
  return hdmaxdec_file_seek_progress(f, sample, nullptr, nullptr);
}
int hdmaxdec_file_measure(hdmaxdec_file *f, hdmaxdec_progress callback,
                          void *context) {
  if (!f)
    return HD_INVALID;
  if (f->total != UINT64_MAX)
    return HD_OK;
  try {
    uint64_t at = 0, samples = 0;
    ScanWindow window(f);
    while (at < f->length) {
      if (callback && !callback(context, at, f->length))
        return HD_CANCELLED;
      auto au = scanAU(f, window, at);
      samples += au.samples;
      at = au.end;
    }
    hd::require(samples >= f->initialTrim, "scan priming exceeds samples");
    f->total = samples - f->initialTrim;
    return HD_OK;
  } catch (const hd::Error &e) {
    f->error = e.what();
    return e.status;
  } catch (...) {
    return HD_INVALID;
  }
}
int hdmaxdec_file_prepare_seek(hdmaxdec_file *f, hdmaxdec_progress callback,
                               void *context) {
  if (!f)
    return HD_INVALID;
  if (!f->seekPoints.empty())
    return HD_OK;
  int measured = hdmaxdec_file_measure(f, callback, context);
  if (measured != HD_OK)
    return measured;
  try {
    constexpr uint64_t limit = 4096;
    static_assert(limit * sizeof(hdmaxdec_file::SeekPoint) < (64u << 20),
                  "seek history memory bound");
    hd::require(f->total <= UINT64_MAX - f->initialTrim,
                "seek index sample count overflow");
    uint64_t stride = std::max<uint64_t>(12000, f->total / (limit - 1) + 1);
    std::vector<hdmaxdec_file::SeekPoint> points;
    points.reserve(size_t(std::min<uint64_t>(limit, f->total / stride + 1)));
    hd::Core core;
    hd::Presentation presentation;
    ScanWindow window(f);
    uint64_t at = 0, coded = 0, next = 0;
    while (at < f->length) {
      if (callback && !callback(context, at, f->length))
        return HD_CANCELLED;
      uint64_t produced = coded > f->initialTrim ? coded - f->initialTrim : 0;
      if (produced >= next && produced < f->total) {
        points.push_back({at, produced,
                          coded < f->initialTrim ? f->initialTrim - coded : 0,
                          core, presentation});
        next = produced + stride;
      }
      auto au = scanAU(f, window, at);
      if (!f->coreOnly) {
        size_t consumed = 0;
        auto audio = hd::decodeAU(core, presentation,
                                  window.get(at, size_t(au.end - at)),
                                  size_t(au.end - at), consumed);
        hd::require(consumed == au.end - at &&
                        audio.planes[0].size() == au.samples,
                    "seek presentation timeline mismatch");
      } else if (au.coreSize) {
        auto audio = core.decode(window.get(at, au.coreSize), au.coreSize);
        hd::require(audio.planes[0].size() == au.samples,
                    "seek Core timeline mismatch");
      }
      hd::require(au.samples <= UINT64_MAX - coded, "seek timeline overflow");
      coded += au.samples;
      at = au.end;
    }
    hd::require(coded >= f->initialTrim + f->total && points.size() <= limit,
                "seek index programme closure");
    if (callback && !callback(context, f->length, f->length))
      return HD_CANCELLED;
    f->seekPoints = std::move(points);
    return HD_OK;
  } catch (const hd::Error &e) {
    f->error = e.what();
    return e.status;
  } catch (const std::bad_alloc &) {
    f->error = "seek index allocation failed";
    return HD_MEMORY;
  } catch (const std::exception &e) {
    f->error = e.what();
    return HD_INVALID;
  }
}
uint64_t hdmaxdec_file_sample_count(const hdmaxdec_file *f) {
  return f ? f->total : UINT64_MAX;
}
const char *hdmaxdec_file_error(const hdmaxdec_file *f) {
  return f ? f->error.c_str() : "file open failed";
}
void hdmaxdec_file_close(hdmaxdec_file *f) { delete f; }
}
