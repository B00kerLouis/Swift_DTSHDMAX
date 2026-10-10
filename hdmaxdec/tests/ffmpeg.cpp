// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "hdmaxdec_avframe.h"
#include <array>
#include <cstdio>
#include <cstdlib>
static void check(bool b, const char *m) {
  if (!b) {
    std::fprintf(stderr, "FAIL %s\n", m);
    std::exit(1);
  }
}
int main() {
  for (const char *name : {"2.0", "5.1", "7.1", "5.1.2", "5.1.4", "7.1.2",
                           "7.1.4", "7.1.5", "7.1.6", "9.1.6"}) {
    hdmaxdec_frame f{};
    check(!hdmaxdec_layout_named(name, &f.layout), "layout");
    f.sample_rate = 48000;
    f.bit_depth = 24;
    f.sample_count = 3;
    std::array<std::array<int32_t, 3>, 32> p{};
    for (uint32_t c = 0; c < f.layout.count; ++c) {
      p[c] = {-8388608, int32_t(c), 8388607};
      f.planes[c] = p[c].data();
    }
    AVFrame *frame = av_frame_alloc();
    check(frame, "allocation");
    check(!hdmaxdec_avframe_copy(&f, frame), "frame copy");
    check(av_channel_layout_check(&frame->ch_layout),
          "channel layout integrity");
    for (uint32_t c = 0; c < f.layout.count; ++c) {
      check(frame->ch_layout.u.map[c].id == int(f.layout.speakers[c]),
            "custom speaker identity");
      auto *plane = reinterpret_cast<int32_t *>(frame->extended_data[c]);
      for (unsigned i = 0; i < 3; ++i)
        check(plane[i] == p[c][i] * 256, "S32 planar sample justification");
    }
    av_frame_free(&frame);
  }
  std::puts("FFmpeg frame adapter passed all ten layouts");
}
