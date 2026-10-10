// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include "hdmaxdec.h"
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
namespace hdqc {
struct Snapshot {
  std::string path, status = "Open DTS / DTS-HD audio", device = "",
                    layoutName = "native";
  hdmaxdec_layout layout{};
  uint64_t position = 0, total = 0, span = 0, clips = 0;
  unsigned immersive = 0;
  bool playing = false, seeking = false, loaded = false, scrubbing = false;
  int solo = -1;
  std::array<float, 32> peak{}, rms{};
  std::chrono::steady_clock::time_point stamp =
      std::chrono::steady_clock::now();
};
class Engine {
public:
  explicit Engine(std::string device = {});
  ~Engine();
  void load(const std::string &, bool autoplay = true);
  void toggle();
  void stop();
  void seek(uint64_t);
  void beginScrub();
  void previewScrub(uint64_t);
  void endScrub(uint64_t);
  void skip(double seconds);
  void layout(const std::string &);
  void monitor(int);
  void solo(int);
  void volume(float);
  Snapshot snapshot();
  void shutdown();

private:
  std::mutex mutex_;
  std::condition_variable changed_;
  Snapshot state_;
  hdmaxdec_layout nativeLayout_{};
  std::string pendingPath_, deviceID_, selected_ = "native";
  bool quitting_ = false, playing_ = false, loadPending_ = false,
       seekPending_ = false, flushPending_ = false, resumeAfterScrub_ = false;
  uint64_t requested_ = 0;
  std::atomic<uint64_t> generation_{0};
  int monitor_ = 0, solo_ = -1;
  float volume_ = 0.5f;
  std::thread worker_;
  void reconfigure(); // Called with mutex_ held.
  void run();
};
} // namespace hdqc
