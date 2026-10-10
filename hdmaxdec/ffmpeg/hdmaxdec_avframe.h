/* Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef HDMAXDEC_AVFRAME_H
#define HDMAXDEC_AVFRAME_H
#include "hdmaxdec.h"
#ifdef __cplusplus
extern "C" {
#endif
#include <libavutil/frame.h>
/* Copy into an owning S32P AVFrame, preserving explicit speaker order.
 * The caller sets timestamps from its demuxer and owns the destination.
 * libavutil >= 58 is required. No decoder registration is implied. */
int hdmaxdec_avframe_copy(const hdmaxdec_frame *source, AVFrame *destination);
#ifdef __cplusplus
}
#endif
#endif
