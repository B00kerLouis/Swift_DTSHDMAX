// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "qc_engine.hpp"
#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>
namespace hdqc {
using Clock = std::chrono::steady_clock;
static uint64_t displayed(const Snapshot &s) {
  uint64_t p = s.position;
  if (s.playing && !s.seeking)
    p += std::min(s.span, uint64_t(std::max(0.0, std::chrono::duration<double>(
                                                     Clock::now() - s.stamp)
                                                     .count()) *
                                   48000));
  return s.total ? std::min(p, s.total) : p;
}
Engine::Engine(std::string device)
    : deviceID_(std::move(device)), worker_(&Engine::run, this) {}
Engine::~Engine() { shutdown(); }
void Engine::shutdown() {
  {
    std::lock_guard<std::mutex> l(mutex_);
    quitting_ = true;
    ++generation_;
    changed_.notify_all();
  }
  if (worker_.joinable())
    worker_.join();
}
Snapshot Engine::snapshot() {
  std::lock_guard<std::mutex> l(mutex_);
  Snapshot s = state_;
  s.position = displayed(s);
  s.span = 0;
  s.playing = playing_ && !state_.seeking;
  return s;
}
void Engine::load(const std::string &p, bool autoplay) {
  std::lock_guard<std::mutex> l(mutex_);
  pendingPath_ = p;
  loadPending_ = true;
  playing_ = autoplay;
  ++generation_;
  state_.status = "Loading audio…";
  state_.seeking = true;
  state_.loaded = false;
  changed_.notify_all();
}
void Engine::toggle() {
  std::lock_guard<std::mutex> l(mutex_);
  if (!state_.loaded)
    return;
  if (playing_) {
    requested_ = displayed(state_);
    state_.position = requested_;
    state_.span = 0;
    state_.playing = false;
    state_.seeking = true;
    seekPending_ = true;
    ++generation_;
    playing_ = false;
  } else {
    if (state_.total && state_.position >= state_.total) {
      requested_ = 0;
      seekPending_ = true;
      ++generation_;
    }
    playing_ = true;
  }
  changed_.notify_all();
}
void Engine::stop() {
  std::lock_guard<std::mutex> l(mutex_);
  playing_ = false;
  requested_ = 0;
  state_.position = 0;
  state_.span = 0;
  state_.seeking = true;
  seekPending_ = true;
  ++generation_;
  changed_.notify_all();
}
void Engine::seek(uint64_t p) {
  std::lock_guard<std::mutex> l(mutex_);
  if (!state_.loaded)
    return;
  requested_ = state_.total ? std::min(p, state_.total) : p;
  seekPending_ = true;
  ++generation_;
  state_.position = requested_;
  state_.span = 0;
  state_.seeking = true;
  state_.status = "Seeking…";
  changed_.notify_all();
}
void Engine::skip(double seconds) {
  auto s = snapshot();
  int64_t p = int64_t(s.position) + int64_t(seconds * 48000);
  seek(uint64_t(std::max<int64_t>(0, p)));
}
void Engine::layout(const std::string &name) {
  std::lock_guard<std::mutex> l(mutex_);
  selected_ = name;
  if (name == "native")
    state_.layout = nativeLayout_;
  else
    hdmaxdec_layout_named(name.c_str(), &state_.layout);
  solo_ = -1;
  state_.layoutName = name;
  state_.solo = -1;
  state_.peak = {};
  state_.rms = {};
  changed_.notify_all();
}
void Engine::monitor(int value) {
  std::lock_guard<std::mutex> l(mutex_);
  monitor_ = value;
  changed_.notify_all();
}
void Engine::solo(int channel) {
  std::lock_guard<std::mutex> l(mutex_);
  solo_ = solo_ == channel ? -1 : channel;
  state_.solo = solo_;
  changed_.notify_all();
}
void Engine::volume(float value) {
  std::lock_guard<std::mutex> l(mutex_);
  volume_ = std::clamp(value, 0.0f, 1.0f);
}
void Engine::run() {
  using File = std::unique_ptr<hdmaxdec_file, decltype(&hdmaxdec_file_close)>;
  using Player =
      std::unique_ptr<hdmaxdec_player, decltype(&hdmaxdec_player_close)>;
  File file(nullptr, hdmaxdec_file_close);
  Player player(nullptr, hdmaxdec_player_close);
  uint64_t cursor = 0;
  Clock::time_point deadline = Clock::now();
  struct Cancel {
    Engine *engine;
    uint64_t generation;
  };
  auto check = [](void *p, uint64_t, uint64_t) -> int {
    auto *c = static_cast<Cancel *>(p);
    return c->engine->generation_.load() == c->generation;
  };
  auto fail = [&](const std::string &message) {
    player.reset();
    std::lock_guard<std::mutex> l(mutex_);
    playing_ = false;
    state_.playing = false;
    state_.seeking = false;
    state_.span = 0;
    state_.status = message;
  };
  while (true) {
    std::unique_lock<std::mutex> lock(mutex_);
    changed_.wait(lock, [&] {
      return quitting_ || loadPending_ || seekPending_ || (playing_ && file);
    });
    if (quitting_)
      break;
    uint64_t gen = generation_.load();
    if (loadPending_) {
      std::string path = pendingPath_;
      loadPending_ = false;
      seekPending_ = false;
      lock.unlock();
      player.reset();
      file.reset(hdmaxdec_file_open(path.c_str()));
      cursor = 0;
      deadline = Clock::now();
      if (!file) {
        fail("Unable to open file or unsupported stream");
        continue;
      }
      Cancel c{this, gen};
      int measured = hdmaxdec_file_measure(file.get(), check, &c);
      if (measured == HD_CANCELLED)
        continue;
      if (measured != HD_OK) {
        fail(hdmaxdec_file_error(file.get()));
        continue;
      }
      hdmaxdec_frame first{};
      int initial = hdmaxdec_file_read(file.get(), &first);
      if (initial != HD_OK) {
        fail(hdmaxdec_file_error(file.get()));
        continue;
      }
      hdmaxdec_layout sourceLayout = first.layout;
      unsigned immersive = first.immersive;
      hdmaxdec_file_seek(file.get(), 0);
      lock.lock();
      if (gen != generation_.load())
        continue;
      nativeLayout_ = sourceLayout;
      state_.layout = sourceLayout;
      if (selected_ != "native")
        hdmaxdec_layout_named(selected_.c_str(), &state_.layout);
      state_.immersive = immersive;
      state_.path = path;
      state_.total = hdmaxdec_file_sample_count(file.get());
      state_.position = 0;
      state_.span = 0;
      state_.loaded = true;
      state_.seeking = false;
      state_.clips = 0;
      state_.status = "Ready";
    }
    if (seekPending_) {
      uint64_t wanted = requested_;
      seekPending_ = false;
      lock.unlock();
      player.reset();
      Cancel c{this, gen};
      int status = hdmaxdec_file_seek_progress(file.get(), wanted, check, &c);
      if (status == HD_CANCELLED)
        continue;
      if (status != HD_OK) {
        fail("Seek failed: " + std::string(hdmaxdec_file_error(file.get())));
        continue;
      }
      cursor = wanted;
      deadline = Clock::now();
      lock.lock();
      state_.position = cursor;
      state_.span = 0;
      state_.seeking = false;
      state_.peak = {};
      state_.rms = {};
      state_.status = playing_ ? "Playing" : "Paused";
    }
    if (!playing_) {
      player.reset();
      state_.playing = false;
      state_.stamp = Clock::now();
      continue;
    }
    std::string name = selected_;
    int monitor = monitor_, solo = solo_;
    float volume = volume_;
    lock.unlock();
    hdmaxdec_frame f{};
    int decoded = hdmaxdec_file_read(file.get(), &f);
    if (decoded == HD_NEED_MORE) {
      if (player)
        hdmaxdec_player_drain(player.get());
      player.reset();
      lock.lock();
      playing_ = false;
      state_.playing = false;
      state_.position = state_.total;
      state_.span = 0;
      state_.status = "End of programme";
      state_.peak = {};
      state_.rms = {};
      continue;
    }
    if (decoded != HD_OK) {
      fail("Decode failed: " + std::string(hdmaxdec_file_error(file.get())));
      continue;
    }
    hdmaxdec_layout qc = f.layout;
    if (name != "native" && hdmaxdec_layout_named(name.c_str(), &qc) != HD_OK) {
      fail("Unsupported QC layout");
      continue;
    }
    float matrix[32 * 32];
    if (hdmaxdec_frame_mix_matrix(&f, &qc, matrix) != HD_OK) {
      fail("QC channel mapping failed");
      continue;
    }
    // QC is measured before master volume and before DAC clipping. This plane
    // count is unrelated to the endpoint's count; absent feeds remain zero.
    std::vector<std::vector<float>> virtualPCM(
        qc.count, std::vector<float>(f.sample_count));
    std::array<float, 32> peak{}, rms{};
    uint64_t clips = 0;
    for (unsigned o = 0; o < qc.count; ++o) {
      double square = 0;
      for (unsigned i = 0; i < f.sample_count; ++i) {
        double v = 0;
        for (unsigned c = 0; c < f.layout.count; ++c)
          v +=
              double(f.planes[c][i]) * matrix[o * f.layout.count + c] / 8388608;
        virtualPCM[o][i] = float(v);
        peak[o] = std::max(peak[o], float(std::abs(v)));
        square += v * v;
        if (v > 8388607.0 / 8388608 || v < -1)
          ++clips;
      }
      rms[o] = float(std::sqrt(square / f.sample_count));
    }
    hdmaxdec_device_info info{};
    if (monitor != 2 && !player) {
      player.reset(hdmaxdec_player_open(
          deviceID_.empty() ? nullptr : deviceID_.c_str(), nullptr));
      if (player)
        info = *hdmaxdec_player_info(player.get());
    } else if (player)
      info = *hdmaxdec_player_info(player.get());
    if (monitor == 2)
      player.reset();
    if (player) {
      hdmaxdec_frame physical{};
      physical.sample_rate = 48000;
      physical.bit_depth = 24;
      physical.sample_count = f.sample_count;
      physical.layout = info.layout;
      std::vector<std::vector<int32_t>> pcm(
          info.layout.count, std::vector<int32_t>(f.sample_count));
      float fold[32 * 32]{};
      if (monitor == 1 && solo < 0)
        hdmaxdec_mix_matrix(&qc, &info.layout, fold);
      for (unsigned o = 0; o < info.layout.count; ++o) {
        int matched = -1;
        for (unsigned c = 0; c < qc.count; ++c)
          if (info.layout.speakers[o] == qc.speakers[c])
            matched = int(c);
        for (unsigned i = 0; i < f.sample_count; ++i) {
          double value = 0;
          if (solo >= 0 && solo < int(qc.count)) {
            if (info.layout.speakers[o] == HD_FL ||
                info.layout.speakers[o] == HD_FR || info.layout.count == 1)
              value = virtualPCM[unsigned(solo)][i] * 0.7071067811865476;
          } else if (monitor == 1) {
            for (unsigned c = 0; c < qc.count; ++c)
              value += virtualPCM[c][i] * fold[o * qc.count + c];
          } else if (matched >= 0)
            value = virtualPCM[unsigned(matched)][i];
          pcm[o][i] = int32_t(std::llround(
              std::clamp(value, -1.0, 8388607.0 / 8388608) * 8388608));
        }
        physical.planes[o] = pcm[o].data();
      }
      if (hdmaxdec_player_write(player.get(), &physical, volume) != HD_OK) {
        fail("Audio device failed or disconnected");
        continue;
      }
    }
    lock.lock();
    if (gen != generation_.load())
      continue;
    state_.layout = qc;
    state_.layoutName = name;
    state_.immersive = f.immersive;
    state_.position = cursor;
    state_.span = f.sample_count;
    state_.stamp = Clock::now();
    state_.playing = true;
    state_.peak = peak;
    state_.rms = rms;
    state_.clips += clips;
    state_.solo = solo;
    state_.device = player ? std::string(info.name) + " · " +
                                 std::to_string(info.layout.count) + " ch"
                    : monitor == 2 ? "QC only, no monitoring"
                                   : "Device unavailable, QC only";
    state_.status = "Playing";
    cursor += f.sample_count;
    deadline += std::chrono::duration_cast<Clock::duration>(
        std::chrono::duration<double>(double(f.sample_count) / 48000));
    if (deadline < Clock::now() - std::chrono::milliseconds(100))
      deadline = Clock::now();
    changed_.wait_until(lock, deadline, [&] {
      return quitting_ || !playing_ || loadPending_ || seekPending_;
    });
    if (!quitting_ && !loadPending_ && !seekPending_) {
      state_.position = cursor;
      state_.span = 0;
      state_.stamp = Clock::now();
    }
  }
}
} // namespace hdqc
