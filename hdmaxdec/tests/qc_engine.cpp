// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "../cli/macos/qc_engine.hpp"
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
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }
  check(false, "QC state timeout");
  return {};
}
int main(int argc, char **argv) {
  check(argc == 2, "supply a >=90-second programme");
  hdqc::Engine engine;
  engine.monitor(2);
  engine.layout("7.1.5");
  engine.load(argv[1], false);
  auto ready = wait(engine, [](auto &s) { return s.loaded && !s.seeking; });
  check(ready.total >= 48000 * 90 && ready.layout.count == 13,
        "QC 13 independent feeds");
  engine.toggle();
  auto live =
      wait(engine, [](auto &s) { return s.playing && s.position >= 4800; });
  engine.toggle();
  auto paused = wait(engine, [](auto &s) { return !s.playing && !s.seeking; });
  uint64_t at = paused.position;
  std::this_thread::sleep_for(std::chrono::milliseconds(100));
  check(engine.snapshot().position == at, "pause freezes source clock");
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
  std::puts("QC load, pause, virtual 13/16 feeds, seek, stop/play and EOF "
            "re-entry passed");
}
