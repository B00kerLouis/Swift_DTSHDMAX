/* Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later */
#include "hdmaxdec_avframe.h"
#include <errno.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libavutil/version.h>
#if LIBAVUTIL_VERSION_MAJOR < 58
#error libavutil 58 or later is required
#endif
int hdmaxdec_avframe_copy(const hdmaxdec_frame *src, AVFrame *dst) {
  if (!src || !dst || !src->layout.count ||
      src->layout.count > HDMAXDEC_MAX_CHANNELS || !src->sample_rate ||
      src->sample_count > 65536)
    return AVERROR(EINVAL);
  av_frame_unref(dst);
  dst->format = AV_SAMPLE_FMT_S32P;
  dst->sample_rate = (int)src->sample_rate;
  dst->nb_samples = (int)src->sample_count;
  dst->ch_layout.order = AV_CHANNEL_ORDER_CUSTOM;
  dst->ch_layout.nb_channels = (int)src->layout.count;
  dst->ch_layout.u.map = av_calloc(src->layout.count, sizeof(AVChannelCustom));
  if (!dst->ch_layout.u.map)
    return AVERROR(ENOMEM);
  for (uint32_t c = 0; c < src->layout.count; ++c) {
    if (!src->planes[c]) {
      av_frame_unref(dst);
      return AVERROR(EINVAL);
    }
    dst->ch_layout.u.map[c].id = (enum AVChannel)src->layout.speakers[c];
  }
  int status = av_frame_get_buffer(dst, 0);
  if (status < 0) {
    av_frame_unref(dst);
    return status;
  }
  for (uint32_t c = 0; c < src->layout.count; ++c) {
    int32_t *plane = (int32_t *)dst->extended_data[c];
    for (uint32_t i = 0; i < src->sample_count; ++i) {
      if (src->planes[c][i] < -8388608 || src->planes[c][i] > 8388607) {
        av_frame_unref(dst);
        return AVERROR(EINVAL);
      }
      plane[i] = src->planes[c][i] * 256;
    }
  }
  return 0;
}
