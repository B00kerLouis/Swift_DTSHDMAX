/* Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later */
#ifndef HDMAXDEC_H
#define HDMAXDEC_H
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32) && defined(HDMAXDEC_SHARED)
#ifdef HDMAXDEC_BUILD
#define HDMAXDEC_API __declspec(dllexport)
#else
#define HDMAXDEC_API __declspec(dllimport)
#endif
#else
#define HDMAXDEC_API
#endif
#ifdef __cplusplus
extern "C" {
#endif
#define HDMAXDEC_MAX_CHANNELS 32
/* Position IDs follow the public multimedia channel convention. Order is
 * always explicit; a channel count alone never determines speaker placement. */
typedef enum hdmaxdec_speaker {
  HD_FL = 0,
  HD_FR = 1,
  HD_FC = 2,
  HD_LFE = 3,
  HD_BL = 4,
  HD_BR = 5,
  HD_FLC = 6,
  HD_FRC = 7,
  HD_BC = 8,
  HD_SL = 9,
  HD_SR = 10,
  HD_TC = 11,
  HD_TFL = 12,
  HD_TFC = 13,
  HD_TFR = 14,
  HD_TBL = 15,
  HD_TBC = 16,
  HD_TBR = 17,
  HD_WL = 31,
  HD_WR = 32,
  HD_TSL = 38,
  HD_TSR = 39,
  HD_UNKNOWN = 768
} hdmaxdec_speaker;
typedef struct hdmaxdec_layout {
  uint32_t count;
  hdmaxdec_speaker speakers[HDMAXDEC_MAX_CHANNELS];
} hdmaxdec_layout;
typedef enum hdmaxdec_status {
  HD_OK = 0,
  HD_NEED_MORE = 1,
  HD_INVALID = -1,
  HD_UNSUPPORTED = -2,
  HD_CRC = -3,
  HD_MEMORY = -4,
  HD_IO = -5,
  HD_DEVICE = -6,
  HD_CANCELLED = -7
} hdmaxdec_status;
typedef struct hdmaxdec_frame {
  uint32_t sample_rate, bit_depth, sample_count;
  hdmaxdec_layout layout;
  /* Signed 24-bit integers, right justified. Borrowed until the next decode,
   * reset or destroy. Each plane has sample_count entries. */
  const int32_t *planes[HDMAXDEC_MAX_CHANNELS];
  uint32_t
      immersive; /* 0: public bed, 1: standard heights/object presentation,
                    2: IMAX TFC + four heights/object presentation */
} hdmaxdec_frame;
typedef struct hdmaxdec_decoder hdmaxdec_decoder;
HDMAXDEC_API hdmaxdec_decoder *hdmaxdec_create(void);
HDMAXDEC_API void hdmaxdec_destroy(hdmaxdec_decoder *decoder);
HDMAXDEC_API void hdmaxdec_reset(hdmaxdec_decoder *decoder);
/* One elementary access unit or a raw XLL frame, including optional Core.
 * HD_NEED_MORE consumes zero bytes. On errors reset before retrying. A context
 * is single-threaded; separate contexts may be used concurrently. */
HDMAXDEC_API int hdmaxdec_decode(hdmaxdec_decoder *, const uint8_t *, size_t,
                                 size_t *consumed, hdmaxdec_frame *);
HDMAXDEC_API const char *hdmaxdec_error(const hdmaxdec_decoder *);
/* Explicit standalone Core packet mode; does not wait for an ExSS companion. */
HDMAXDEC_API int hdmaxdec_decode_core(hdmaxdec_decoder *, const uint8_t *,
                                      size_t, size_t *consumed,
                                      hdmaxdec_frame *);
HDMAXDEC_API const char *hdmaxdec_version(void);
typedef struct hdmaxdec_file hdmaxdec_file;
/* Bounded DTSHDHDR/elementary reader. Container programme length and priming
 * are applied once; raw Core-compatible input trims 1024 leading samples. */
HDMAXDEC_API hdmaxdec_file *hdmaxdec_file_open(const char *path);
HDMAXDEC_API int hdmaxdec_file_read(hdmaxdec_file *, hdmaxdec_frame *);
HDMAXDEC_API int hdmaxdec_file_seek(hdmaxdec_file *, uint64_t sample);
/* Return zero from progress to cancel; callbacks run on the calling thread. */
typedef int (*hdmaxdec_progress)(void *, uint64_t completed, uint64_t total);
HDMAXDEC_API int hdmaxdec_file_seek_progress(hdmaxdec_file *, uint64_t sample,
                                             hdmaxdec_progress, void *);
/* Scan raw AU headers without decoding programme PCM. Container totals are
 * returned immediately. Used by interactive clients with raw .dts input. */
HDMAXDEC_API int hdmaxdec_file_measure(hdmaxdec_file *, hdmaxdec_progress,
                                       void *);
/* Optional session-only seek acceleration. Scan AU headers and reconstruct
 * Core and continuous object-presentation history, retaining at most 4096
 * states (under 64 MiB), never programme PCM. Existing reads/pending PCM are
 * preserved, including on cancellation.
 * Subsequent seeks restore the nearest state and replay only the local span.
 * Without preparation, seeking retains exact replay from the stream start. */
HDMAXDEC_API int hdmaxdec_file_prepare_seek(hdmaxdec_file *, hdmaxdec_progress,
                                            void *);
HDMAXDEC_API uint64_t hdmaxdec_file_sample_count(const hdmaxdec_file *);
HDMAXDEC_API const char *hdmaxdec_file_error(const hdmaxdec_file *);
HDMAXDEC_API void hdmaxdec_file_close(hdmaxdec_file *);
HDMAXDEC_API int hdmaxdec_layout_named(const char *name, hdmaxdec_layout *);
HDMAXDEC_API const char *hdmaxdec_speaker_name(hdmaxdec_speaker);
/* Row-major output x input matrix. Exact speaker matches remain unity.
 * Missing feeds are folded geometrically; extra speakers are not fabricated.
 * Matrix peak headroom can be controlled by a host's master gain. */
HDMAXDEC_API int hdmaxdec_mix_matrix(const hdmaxdec_layout *,
                                     const hdmaxdec_layout *, float *);
/* Includes presentation-specific compatibility folds when output has no tops.
 */
HDMAXDEC_API int hdmaxdec_frame_mix_matrix(const hdmaxdec_frame *,
                                           const hdmaxdec_layout *, float *);
HDMAXDEC_API int hdmaxdec_render_float(const hdmaxdec_frame *,
                                       const hdmaxdec_layout *, float gain,
                                       float *interleaved, size_t capacity);

typedef struct hdmaxdec_device_info {
  char id[256], name[256];
  uint32_t sample_rate;
  hdmaxdec_layout layout;
  uint32_t positions_known;
} hdmaxdec_device_info;
typedef struct hdmaxdec_player hdmaxdec_player;
/* NULL id selects the default endpoint. Query does not play audio. Unknown
 * maps are reported, and require an explicit layout when opening playback. */
HDMAXDEC_API int hdmaxdec_device_query(const char *id, hdmaxdec_device_info *);
HDMAXDEC_API hdmaxdec_player *
hdmaxdec_player_open(const char *id, const hdmaxdec_layout *override_layout);
HDMAXDEC_API const hdmaxdec_device_info *
hdmaxdec_player_info(const hdmaxdec_player *);
/* Blocking, bounded queue, 48 kHz input. Device loss is an error.
 * Open/write/drain/close must all use the same calling thread on Windows. */
HDMAXDEC_API int hdmaxdec_player_write(hdmaxdec_player *,
                                       const hdmaxdec_frame *, float gain);
HDMAXDEC_API int hdmaxdec_player_drain(hdmaxdec_player *);
/* Discard queued monitoring PCM while retaining the open device. */
HDMAXDEC_API int hdmaxdec_player_flush(hdmaxdec_player *);
/* Cooperative cancellation for interactive hosts. Existing blocking entry
 * points retain their behavior. Callbacks run on the playback thread. */
HDMAXDEC_API int hdmaxdec_player_write_progress(hdmaxdec_player *,
    const hdmaxdec_frame *, float gain, hdmaxdec_progress, void *);
HDMAXDEC_API int hdmaxdec_player_drain_progress(hdmaxdec_player *,
    hdmaxdec_progress, void *);
HDMAXDEC_API void hdmaxdec_player_close(hdmaxdec_player *);

typedef enum hdmaxdec_pcm_format {
  HD_PCM_WAV24 = 0,
  HD_PCM_S24LE = 1,
  HD_PCM_S32LE = 2,
  HD_PCM_F32LE = 3
} hdmaxdec_pcm_format;
typedef struct hdmaxdec_export_options {
  hdmaxdec_pcm_format format;
  hdmaxdec_layout
      layout; /* count=0 preserves native feeds; independent of DAC */
  float gain;
} hdmaxdec_export_options;
typedef struct hdmaxdec_export_result {
  uint64_t samples, clipped_samples;
  hdmaxdec_layout layout;
  char error[256];
} hdmaxdec_export_result;
/* Bounded, cancellable PCM export to a sibling temporary file, committed only
 * on success. Input/output must differ. S32LE stores left-justified 24-bit PCM.
 */
HDMAXDEC_API int hdmaxdec_export_pcm(const char *input, const char *output,
                                     const hdmaxdec_export_options *,
                                     hdmaxdec_progress, void *,
                                     hdmaxdec_export_result *);
#ifdef __cplusplus
}
#endif
#endif
