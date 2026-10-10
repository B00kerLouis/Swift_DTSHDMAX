// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "../cli/macos/qc_engine.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <thread>
static void check(bool ok, const char *m) {
  if (!ok) {
    std::fprintf(stderr, "FAIL %s\n", m);
    std::exit(1);
  }
}
template <class F> hdqc::Snapshot wait(hdqc::Engine &e, F predicate) {
  auto end = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  while (std::chrono::steady_clock::now() < end) {
    auto s = e.snapshot();
    if (predicate(s))
      return s;
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  check(false, "QC state timeout");
  return {};
}
int main(int argc, char **argv) {
  check(argc == 2 || argc == 3, "supply a >=90-second programme [--device]");
  bool device = argc == 3 && std::string(argv[2]) == "--device";
  hdqc::Engine engine;
  engine.monitor(device ? 0 : 2);
  engine.volume(0);
  engine.layout("7.1.5");
  engine.load(argv[1], false);
  auto ready = wait(engine, [](auto &s) { return s.loaded && !s.seeking; });
  check(ready.total >= 48000 * 90 && ready.layout.count == 13,
        "QC 13 independent feeds");
  double worstSeek = 0;
  for (uint64_t p : {ready.total / 2, ready.total - 1024, uint64_t(48000 * 45)}) {
    auto begin = std::chrono::steady_clock::now();
    engine.seek(p);
    wait(engine, [p](auto &s) { return !s.seeking && s.position == p; });
    worstSeek = std::max(worstSeek, std::chrono::duration<double, std::milli>(
                                     std::chrono::steady_clock::now() - begin).count());
  }
  engine.seek(0);
  wait(engine, [](auto &s) { return !s.seeking && s.position == 0; });
  engine.toggle();
  auto live =
      wait(engine, [](auto &s) { return s.playing && s.position >= 4800; });
  if (device)
    check(live.device.find("QC only") == std::string::npos,
          "real audio endpoint opened");
  // Dragging previews positions without playing or decoding intermediate PCM.
  engine.beginScrub();
  for (unsigned n = 0; n < 40; ++n) {
    uint64_t preview = (ready.total / 41) * n;
    engine.previewScrub(preview);
    if (n % 4 == 0)
      engine.layout(n % 8 == 0 ? "9.1.6" : "2.0");
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    auto s = engine.snapshot();
    check(s.scrubbing && !s.playing && s.position == preview,
          "drag stays silent and preserves the latest position preview");
  }
  uint64_t final = ready.total / 3;
  auto begin = std::chrono::steady_clock::now();
  engine.previewScrub(final);
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  check(engine.snapshot().position == final && !engine.snapshot().playing,
        "drag preview clock stays frozen");
  begin = std::chrono::steady_clock::now();
  engine.endScrub(final);
  engine.layout("7.1.5");
  live = wait(engine, [final](auto &s) {
    return !s.seeking && s.playing && s.layout.count == 13 &&
           s.position >= final && s.position < final + 48000;
  });
  double drag = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - begin).count();
  std::printf("Paused seek worst %.3f ms, live drag/layout response %.3f ms (%s)\n",
              worstSeek, drag, device ? "device" : "QC only");
  engine.toggle();
  auto paused = wait(engine, [](auto &s) { return !s.playing && !s.seeking; });
  uint64_t at = paused.position;
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  check(engine.snapshot().position == at, "pause freezes source clock");
  engine.beginScrub();
  engine.previewScrub(48000 * 30);
  engine.endScrub(48000 * 30);
  wait(engine, [](auto &s) {
    return !s.scrubbing && !s.seeking && !s.playing && s.position == 48000 * 30;
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  check(engine.snapshot().position == 48000 * 30,
        "dragging a paused programme keeps it paused after release");
  engine.layout("9.1.6");
  check(engine.snapshot().layout.count == 16,
        "paused layout updates without DAC truncation");
  engine.seek(48000 * 45);
  auto seeked = wait(
      engine, [](auto &s) { return !s.seeking && s.position == 48000 * 45; });
  engine.toggle();
  live = wait(engine, [](auto &s) {
    return s.playing && s.position > 48000 * 45 + 4800;
  });
  engine.stop();
  auto stopped = wait(engine, [](auto &s) {
    return !s.seeking && !s.playing && s.position == 0;
  });
  engine.seek(ready.total - 1024);
  wait(engine, [](auto &s) { return !s.seeking; });
  engine.toggle();
  auto eof = wait(engine, [](auto &s) {
    return !s.playing && s.status == "End of programme";
  });
  check(eof.position == ready.total, "QC last sample reached");
  engine.toggle();
  wait(engine, [](auto &s) { return s.playing && s.position < 48000; });
  engine.shutdown();
  // Stop during preparation changes playback intent without cancelling load.
  hdqc::Engine loading;
  loading.monitor(2);
  loading.load(argv[1]);
  loading.stop();
  auto stoppedLoad = wait(loading, [](auto &s) { return s.loaded && !s.seeking; });
  check(!stoppedLoad.playing, "stop during load preserves ready state");
  loading.shutdown();
  std::puts("QC load, pause, virtual 13/16 feeds, seek, stop/play and EOF "
            "re-entry passed");
}
