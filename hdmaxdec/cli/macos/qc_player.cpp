// Copyright (c) 2026 B00kerLouis. SPDX-License-Identifier: LGPL-2.1-or-later
#include "qc_player.h"
#include "qc_engine.hpp"
#include <CoreGraphics/CoreGraphics.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdexcept>
#include <vector>
extern "C" {
extern id NSFontAttributeName;
extern id NSForegroundColorAttributeName;
extern id NSRunLoopCommonModes;
extern id NSAppearanceNameDarkAqua;
extern id UTTypeData;
}
namespace {
// AppKit is a system boundary: all implementation is C++. These signatures
// mirror the installed SDK declarations, including CGFloat/NSInteger/BOOL.
template <class R = id, class... A>
R send(id object, const char *name, A... args) {
  return reinterpret_cast<R (*)(id, SEL, A...)>(objc_msgSend)(
      object, sel_registerName(name), args...);
}
id type(const char *name) { return reinterpret_cast<id>(objc_getClass(name)); }
id string(const std::string &s) {
  return send<id>(type("NSString"), "stringWithUTF8String:", s.c_str());
}
std::string utf8(id s) {
  const char *p = s ? send<const char *>(s, "UTF8String") : nullptr;
  return p ? p : "";
}
struct Pool {
  id p = send<id>(type("NSAutoreleasePool"), "new");
  ~Pool() { send<void>(p, "drain"); }
};
id color(double r, double g, double b, double a = 1) {
  return send<id>(type("NSColor"),
                  "colorWithCalibratedRed:green:blue:alpha:", CGFloat(r),
                  CGFloat(g), CGFloat(b), CGFloat(a));
}
id font(double size, bool mono = false) {
  return mono ? send<id>(type("NSFont"),
                         "monospacedDigitSystemFontOfSize:weight:",
                         CGFloat(size), CGFloat(0))
              : send<id>(type("NSFont"), "systemFontOfSize:", CGFloat(size));
}
id symbol(const char *name, double size) {
  id image = send<id>(type("NSImage"),
                      "imageWithSystemSymbolName:accessibilityDescription:",
                      string(name), string(name));
  id config =
      send<id>(type("NSImageSymbolConfiguration"),
               "configurationWithPointSize:weight:", CGFloat(size), CGFloat(0));
  return send<id>(image, "imageWithSymbolConfiguration:", config);
}
void text(const std::string &t, CGPoint at, double size, id ink,
          bool mono = false) {
  id attrs = send<id>(type("NSMutableDictionary"), "dictionary");
  send<void>(attrs, "setObject:forKey:", font(size, mono), NSFontAttributeName);
  send<void>(attrs, "setObject:forKey:", ink, NSForegroundColorAttributeName);
  send<void>(string(t), "drawAtPoint:withAttributes:", at, attrs);
}
std::string timeString(uint64_t samples) {
  uint64_t seconds = samples / 48000;
  char b[32];
  if (seconds >= 3600)
    std::snprintf(b, sizeof(b), "%llu:%02llu:%02llu",
                  (unsigned long long)(seconds / 3600),
                  (unsigned long long)(seconds / 60 % 60),
                  (unsigned long long)(seconds % 60));
  else
    std::snprintf(b, sizeof(b), "%02llu:%02llu",
                  (unsigned long long)(seconds / 60),
                  (unsigned long long)(seconds % 60));
  return b;
}
const char *layouts[] = {"native", "2.0",   "5.1",   "7.1",   "5.1.2", "5.1.4",
                         "7.1.2",  "7.1.4", "7.1.5", "7.1.6", "9.1.6"};
const char *dolbyName(hdmaxdec_speaker speaker) {
  switch (speaker) {
  case HD_FL:
    return "L";
  case HD_FR:
    return "R";
  case HD_FC:
    return "C";
  case HD_LFE:
    return "LFE";
  case HD_SL:
    return "Ls";
  case HD_SR:
    return "Rs";
  case HD_BL:
    return "Lrs";
  case HD_BR:
    return "Rrs";
  case HD_WL:
    return "Lw";
  case HD_WR:
    return "Rw";
  case HD_TFL:
    return "Ltf";
  case HD_TFR:
    return "Rtf";
  case HD_TBL:
    return "Ltr";
  case HD_TBR:
    return "Rtr";
  case HD_TSL:
    return "Ltm";
  case HD_TSR:
    return "Rtm";
  case HD_TFC:
    return "Ctf";
  case HD_TC:
    return "Ctm";
  case HD_TBC:
    return "Ctr";
  case HD_BC:
    return "Cs";
  case HD_FLC:
    return "Lc";
  case HD_FRC:
    return "Rc";
  default:
    return "?";
  }
}
struct App {
  hdqc::Engine engine;
  id app = nullptr, window = nullptr, view = nullptr, controller = nullptr,
     timer = nullptr;
  id title = nullptr, elapsed = nullptr, duration = nullptr, seek = nullptr,
     play = nullptr, volumeLabel = nullptr, status = nullptr,
     description = nullptr, exportButton = nullptr, format = nullptr,
     exportLayout = nullptr, layout = nullptr;
  hdqc::Snapshot current;
  std::array<float, 32> display{}, hold{};
  std::array<std::chrono::steady_clock::time_point, 32> holdUntil{};
  std::array<CGRect, 32> slots{};
  std::atomic<bool> exportCancel{false}, exporting{false};
  std::atomic<uint64_t> exportDone{0}, exportTotal{0};
  std::mutex exportMutex;
  std::string exportStatus;
  std::thread exportThread;
  std::string shownPath, shownLayout;
  bool lastPlaying = false;
  explicit App(std::string device) : engine(std::move(device)) {
    display.fill(-60);
    hold.fill(-60);
  }
  ~App() {
    exportCancel = true;
    if (exportThread.joinable())
      exportThread.join();
    engine.shutdown();
  }
};
App *state(id object) {
  void *p = nullptr;
  object_getInstanceVariable(object, "_hdState", &p);
  return static_cast<App *>(p);
}
void bind(id object, App *p) {
  object_setInstanceVariable(object, "_hdState", p);
}
void redraw(App *c) { send<void>(c->view, "setNeedsDisplay:", BOOL(1)); }
BOOL flipped(id, SEL) { return YES; }
void draw(id object, SEL, CGRect) {
  Pool pool;
  App *c = state(object);
  if (!c)
    return;
  auto &s = c->current;
  CGContextRef g = send<CGContextRef>(
      send<id>(type("NSGraphicsContext"), "currentContext"), "CGContext");
  if (!g)
    return;
  CGContextSetRGBFillColor(g, 0.155, 0.155, 0.155, 1);
  CGContextFillRect(g, CGRectMake(0, 0, 840, 540));
  CGContextSetRGBFillColor(g, 0.25, 0.25, 0.25, 1);
  CGContextFillRect(g, CGRectMake(24, 269, 792, 1));
  id secondary = color(0.61, 0.61, 0.63), white = color(0.9, 0.9, 0.91);
  text("dBFS", CGPointMake(24, 279), 10, secondary);
  for (int db : {0, -6, -12, -24, -36, -48, -60}) {
    double y = 304 + (-db / 60.0) * 126;
    text(std::to_string(db), CGPointMake(28, y - 6), 10, secondary, true);
    CGContextSetRGBFillColor(g, 0.21, 0.21, 0.21, 1);
    CGContextFillRect(g, CGRectMake(58, y, 751, 0.5));
  }
  unsigned count = s.layout.count;
  if (!count) {
    text("Open audio to view channel Peak / RMS", CGPointMake(268, 354), 14,
         secondary);
    return;
  }
  double step = 750.0 / count;
  for (unsigned i = 0; i < count; ++i) {
    double x = 58 + i * step, w = std::min(30.0, step - 18);
    double bx = x + (step - w) / 2;
    CGRect area = CGRectMake(x, 290, step, 174);
    c->slots[i] = area;
    if (s.solo == int(i)) {
      CGContextSetRGBFillColor(g, 0.1, 0.22, 0.4, 0.65);
      CGContextFillRect(g, area);
    }
    CGContextSetRGBFillColor(g, 0.10, 0.10, 0.10, 1);
    CGContextFillRect(g, CGRectMake(bx, 303, w, 127));
    double db = std::clamp<double>(c->display[i], -60, 0), bottom = 430;
    struct Band {
      double lo, hi, r, g, b;
    };
    for (auto band :
         {Band{-60, -18, 0.17, 0.73, 0.42}, Band{-18, -6, 0.94, 0.77, 0.22},
          Band{-6, 0, 0.94, 0.28, 0.25}}) {
      double top = std::min(db, band.hi);
      if (top > band.lo) {
        double y = bottom - (top + 60) / 60 * 126,
               h = (top - band.lo) / 60 * 126;
        CGContextSetRGBFillColor(g, band.r, band.g, band.b, 1);
        CGContextFillRect(g, CGRectMake(bx, y, w, h));
      }
    }
    float rmsDb = s.rms[i] > 0 ? 20 * std::log10(s.rms[i]) : -60;
    double ry = bottom - (std::clamp<double>(rmsDb, -60, 0) + 60) / 60 * 126;
    CGContextSetRGBFillColor(g, 0.36, 0.72, 1, 1);
    CGContextFillRect(g, CGRectMake(bx, ry, 3, bottom - ry));
    double py =
        bottom - (std::clamp<double>(c->hold[i], -60, 0) + 60) / 60 * 126;
    CGContextSetRGBFillColor(g, 0.96, 0.96, 0.96, 1);
    CGContextFillRect(g, CGRectMake(bx, py, w, 1.5));
    bool clipping = c->hold[i] >= 0;
    CGContextSetRGBFillColor(g, clipping ? 0.95 : 0.31, clipping ? 0.19 : 0.31,
                             clipping ? 0.17 : 0.31, 1);
    CGContextFillRect(g, CGRectMake(bx, 291, w, 5));
    std::string label = dolbyName(s.layout.speakers[i]);
    text(label,
         CGPointMake(x + std::max(1.0, (step - label.size() * 6) / 2), 438), 11,
         white, true);
    char b[24];
    if (c->hold[i] <= -60)
      std::snprintf(b, sizeof(b), "−∞");
    else
      std::snprintf(b, sizeof(b), "%.1f", c->hold[i]);
    text(b,
         CGPointMake(x + std::max(1.0, (step - std::strlen(b) * 5.8) / 2), 457),
         10, secondary, true);
  }
}
void meterClick(id object, SEL, id event) {
  App *c = state(object);
  if (!c)
    return;
  CGPoint p = send<CGPoint>(event, "locationInWindow");
  p = send<CGPoint>(object, "convertPoint:fromView:", p, id(nullptr));
  for (unsigned i = 0; i < c->current.layout.count; ++i)
    if (CGRectContainsPoint(c->slots[i], p)) {
      c->engine.solo(int(i));
      return;
    }
}
id label(App *c, const char *value, CGRect rect, double size = 13,
         bool mono = false) {
  id o = send<id>(type("NSTextField"), "labelWithString:", string(value));
  send<void>(o, "setFrame:", rect);
  send<void>(o, "setFont:", font(size, mono));
  send<void>(o, "setTextColor:", color(0.83, 0.83, 0.85));
  send<void>(c->view, "addSubview:", o);
  return o;
}
id button(App *c, const char *value, const char *action, CGRect rect,
          const char *image = nullptr, double pointSize = 24) {
  id b = send<id>(send<id>(type("NSButton"), "alloc"), "initWithFrame:", rect);
  send<void>(b, "setTitle:", string(value));
  send<void>(b, "setTarget:", c->controller);
  send<void>(b, "setAction:", sel_registerName(action));
  send<void>(b, "setBezelStyle:", uintptr_t(1));
  if (image) {
    send<void>(b, "setBordered:", BOOL(0));
    send<void>(b, "setImage:", symbol(image, pointSize));
    send<void>(b, "setContentTintColor:", color(0.92, 0.92, 0.93));
  }
  send<void>(c->view, "addSubview:", b);
  send<void>(b, "release");
  return b;
}
id popup(App *c, const std::vector<std::string> &items, const char *action,
         CGRect rect) {
  id p = send<id>(send<id>(type("NSPopUpButton"), "alloc"),
                  "initWithFrame:pullsDown:", rect, BOOL(0));
  for (const auto &i : items)
    send<void>(p, "addItemWithTitle:", string(i));
  if (action) {
    send<void>(p, "setTarget:", c->controller);
    send<void>(p, "setAction:", sel_registerName(action));
  }
  send<void>(c->view, "addSubview:", p);
  send<void>(p, "release");
  return p;
}
id slider(App *c, double value, const char *action, CGRect rect,
          bool continuous) {
  id s = send<id>(send<id>(type("NSSlider"), "alloc"), "initWithFrame:", rect);
  send<void>(s, "setMinValue:", 0.0);
  send<void>(s, "setMaxValue:", 1.0);
  send<void>(s, "setDoubleValue:", value);
  send<void>(s, "setContinuous:", BOOL(continuous));
  send<void>(s, "setTarget:", c->controller);
  send<void>(s, "setAction:", sel_registerName(action));
  send<void>(c->view, "addSubview:", s);
  send<void>(s, "release");
  return s;
}
void toggle(id object, SEL, id) { state(object)->engine.toggle(); }
void stop(id object, SEL, id) { state(object)->engine.stop(); }
void backward(id object, SEL, id) { state(object)->engine.skip(-10); }
void forward(id object, SEL, id) { state(object)->engine.skip(10); }
void seek(id object, SEL, id sender) {
  App *c = state(object);
  c->engine.seek(
      uint64_t(send<double>(sender, "doubleValue") * c->current.total));
}
void volume(id object, SEL, id sender) {
  App *c = state(object);
  float v = float(send<double>(sender, "doubleValue"));
  c->engine.volume(v);
  send<void>(c->volumeLabel,
             "setStringValue:", string(std::to_string(int(v * 100)) + "%"));
}
void changeLayout(id object, SEL, id sender) {
  long i = send<long>(sender, "indexOfSelectedItem");
  if (i >= 0 && size_t(i) < std::size(layouts))
    state(object)->engine.layout(layouts[i]);
}
void changeMonitor(id object, SEL, id sender) {
  state(object)->engine.monitor(int(send<long>(sender, "indexOfSelectedItem")));
}
void typesForPanel(id panel, const std::vector<std::string> &extensions) {
  id a = send<id>(type("NSMutableArray"), "array");
  for (const auto &e : extensions) {
    id t = send<id>(type("UTType"),
                    "typeWithFilenameExtension:conformingToType:", string(e),
                    UTTypeData);
    if (t)
      send<void>(a, "addObject:", t);
  }
  send<void>(panel, "setAllowedContentTypes:", a);
}
void openFile(id object, SEL, id) {
  Pool pool;
  App *c = state(object);
  id panel = send<id>(type("NSOpenPanel"), "openPanel");
  send<void>(panel, "setCanChooseDirectories:", BOOL(0));
  send<void>(panel, "setAllowsMultipleSelection:", BOOL(0));
  send<void>(panel, "setAllowsOtherFileTypes:", BOOL(1));
  typesForPanel(panel, {"dtshd", "dts", "xll"});
  if (send<long>(panel, "runModal") == 1) {
    std::string path = utf8(send<id>(send<id>(panel, "URL"), "path"));
    c->engine.load(path);
  }
}
void pcmExport(id object, SEL, id) {
  Pool pool;
  App *c = state(object);
  if (c->exporting) {
    c->exportCancel = true;
    return;
  }
  auto s = c->engine.snapshot();
  if (!s.loaded)
    return;
  int format = int(send<long>(c->format, "indexOfSelectedItem"));
  bool native = send<long>(c->exportLayout, "indexOfSelectedItem") == 0;
  std::string ext = format == 0 ? "wav" : format == 3 ? "f32" : "pcm";
  id panel = send<id>(type("NSSavePanel"), "savePanel");
  typesForPanel(panel, {ext});
  send<void>(panel, "setNameFieldStringValue:",
             string(std::filesystem::u8path(s.path).stem().u8string() + "_" +
                    (native                     ? "native"
                     : s.layoutName == "native" ? "native"
                                                : s.layoutName) +
                    "." + ext));
  if (send<long>(panel, "runModal") != 1)
    return;
  std::string output = utf8(send<id>(send<id>(panel, "URL"), "path"));
  if (c->exportThread.joinable())
    c->exportThread.join();
  c->exportCancel = false;
  c->exporting = true;
  c->exportDone = 0;
  c->exportTotal = s.total;
  hdmaxdec_export_options options{};
  options.format = hdmaxdec_pcm_format(format);
  options.gain = 1;
  if (!native)
    options.layout = s.layout;
  c->exportThread = std::thread([c, path = s.path, output, options] {
    hdmaxdec_export_result result{};
    auto progress = [](void *p, uint64_t n, uint64_t total) -> int {
      auto *a = static_cast<App *>(p);
      a->exportDone = n;
      a->exportTotal = total;
      return !a->exportCancel.load();
    };
    int code = hdmaxdec_export_pcm(path.c_str(), output.c_str(), &options,
                                   progress, c, &result);
    std::lock_guard<std::mutex> lock(c->exportMutex);
    c->exportStatus =
        code == HD_OK
            ? "PCM exported · " + std::to_string(result.samples) +
                  " samples/ch · clip " + std::to_string(result.clipped_samples)
        : code == HD_CANCELLED ? "Export cancelled"
                               : "Export failed: " + std::string(result.error);
    c->exporting = false;
  });
}
void tick(id object, SEL, id) {
  Pool pool;
  App *c = state(object);
  c->current = c->engine.snapshot();
  auto &s = c->current;
  if (s.path != c->shownPath) {
    c->shownPath = s.path;
    std::string name =
        s.path.empty() ? "hdmaxdec QC"
                       : std::filesystem::u8path(s.path).filename().u8string();
    send<void>(c->title, "setStringValue:", string(name));
    send<void>(c->window, "setTitle:", string(name));
  }
  if (s.layoutName != c->shownLayout) {
    c->shownLayout = s.layoutName;
    c->display.fill(-60);
    c->hold.fill(-60);
  }
  if (s.playing != c->lastPlaying) {
    c->lastPlaying = s.playing;
    send<void>(c->play,
               "setImage:", symbol(s.playing ? "pause.fill" : "play.fill", 42));
  }
  send<void>(c->elapsed, "setStringValue:", string(timeString(s.position)));
  send<void>(c->duration, "setStringValue:",
             string(s.total ? timeString(s.total) : "--:--"));
  send<void>(c->seek, "setEnabled:", BOOL(s.loaded && s.total));
  if (!send<BOOL>(send<id>(c->seek, "cell"), "isHighlighted"))
    send<void>(c->seek, "setDoubleValue:",
               s.total ? double(s.position) / double(s.total) : 0.0);
  send<void>(c->description, "setStringValue:",
             string(s.loaded ? "QC " + std::to_string(s.layout.count) +
                                   " ch · 48 kHz / 24 bit"
                             : ""));
  std::string status = s.status;
  if (!s.device.empty())
    status += " · " + s.device;
  if (s.solo >= 0 && unsigned(s.solo) < s.layout.count)
    status += " · Solo " +
              std::string(dolbyName(s.layout.speakers[unsigned(s.solo)]));
  status += " · clip " + std::to_string(s.clips);
  if (c->exporting) {
    uint64_t total = c->exportTotal.load(), done = c->exportDone.load();
    status +=
        " · PCM " +
        (total && total != UINT64_MAX
             ? std::to_string(std::min<uint64_t>(100, done * 100 / total)) + "%"
             : std::to_string(done) + " samples");
  } else {
    std::lock_guard<std::mutex> l(c->exportMutex);
    if (!c->exportStatus.empty())
      status += " · " + c->exportStatus;
  }
  send<void>(c->status, "setStringValue:", string(status));
  send<void>(c->exportButton, "setTitle:",
             string(c->exporting ? "Cancel Export" : "Export PCM…"));
  send<void>(c->exportButton, "setEnabled:", BOOL(s.loaded || c->exporting));
  auto now = std::chrono::steady_clock::now();
  for (unsigned i = 0; i < s.layout.count; ++i) {
    float p = s.peak[i] > 0 ? 20 * std::log10(s.peak[i]) : -60;
    c->display[i] = std::max(p, c->display[i] - 0.8f);
    if (p >= c->hold[i]) {
      c->hold[i] = p;
      c->holdUntil[i] = now + std::chrono::milliseconds(900);
    } else if (now > c->holdUntil[i])
      c->hold[i] = std::max(p, c->hold[i] - 0.35f);
  }
  redraw(c);
}
BOOL closeWindow(id object, SEL, id) {
  App *c = state(object);
  c->exportCancel = true;
  send<void>(c->app, "stop:", id(nullptr));
  return YES;
}
void quit(id object, SEL, id) {
  send<void>(state(object)->window, "performClose:", id(nullptr));
}
Class registerClass(const char *name, Class parent, bool view) {
  Class cls = objc_getClass(name);
  if (cls)
    return cls;
  cls = objc_allocateClassPair(parent, name, 0);
  if (!cls)
    throw std::runtime_error("AppKit class allocation failed");
  class_addIvar(cls, "_hdState", sizeof(void *), 3, "^v");
  auto add = [&](const char *n, auto function, const char *encoding) {
    if (!class_addMethod(cls, sel_registerName(n),
                         reinterpret_cast<IMP>(function), encoding))
      throw std::runtime_error("AppKit method registration failed");
  };
  if (view) {
    add("isFlipped", flipped, "B@:");
    add("drawRect:", draw, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    add("mouseDown:", meterClick, "v@:@");
  } else {
    add("toggle:", toggle, "v@:@");
    add("stop:", stop, "v@:@");
    add("backward:", backward, "v@:@");
    add("forward:", forward, "v@:@");
    add("seek:", seek, "v@:@");
    add("volume:", volume, "v@:@");
    add("layout:", changeLayout, "v@:@");
    add("monitor:", changeMonitor, "v@:@");
    add("open:", openFile, "v@:@");
    add("export:", pcmExport, "v@:@");
    add("tick:", tick, "v@:@");
    add("quit:", quit, "v@:@");
    add("windowShouldClose:", closeWindow, "B@:@");
    class_addProtocol(cls, objc_getProtocol("NSWindowDelegate"));
  }
  objc_registerClassPair(cls);
  return cls;
}
void build(App *c) {
  c->app = send<id>(type("NSApplication"), "sharedApplication");
  send<BOOL>(c->app, "setActivationPolicy:", long(0));
  Class controller = registerClass("B00kerHDMaxQCController",
                                   objc_getClass("NSObject"), false),
        view =
            registerClass("B00kerHDMaxQCView", objc_getClass("NSView"), true);
  c->controller = send<id>(reinterpret_cast<id>(controller), "new");
  bind(c->controller, c);
  c->window = send<id>(send<id>(type("NSWindow"), "alloc"),
                       "initWithContentRect:styleMask:backing:defer:",
                       CGRectMake(0, 0, 840, 540), uintptr_t(1 | 2 | 4 | 32768),
                       uintptr_t(2), BOOL(0));
  send<void>(c->window, "setReleasedWhenClosed:", BOOL(0));
  send<void>(c->window, "setTitlebarAppearsTransparent:", BOOL(1));
  send<void>(c->window, "setTitleVisibility:", long(1));
  send<void>(c->window, "setBackgroundColor:", color(.155, .155, .155));
  send<void>(c->window, "setAppearance:",
             send<id>(type("NSAppearance"),
                      "appearanceNamed:", NSAppearanceNameDarkAqua));
  send<void>(c->window, "setDelegate:", c->controller);
  c->view = send<id>(send<id>(reinterpret_cast<id>(view), "alloc"),
                     "initWithFrame:", CGRectMake(0, 0, 840, 540));
  bind(c->view, c);
  send<void>(c->window, "setContentView:", c->view);
  send<void>(c->view, "release");
  c->title = label(c, "hdmaxdec QC", CGRectMake(180, 12, 480, 32), 19);
  send<void>(c->title, "setAlignment:", long(1));
  button(c, "Open…", "open:", CGRectMake(742, 14, 75, 29));
  c->elapsed = label(c, "00:00", CGRectMake(24, 62, 86, 29), 21, true);
  c->duration = label(c, "--:--", CGRectMake(728, 62, 92, 29), 21, true);
  send<void>(c->duration, "setAlignment:", long(2));
  c->seek = slider(c, 0, "seek:", CGRectMake(114, 66, 602, 20), false);
  button(c, "", "backward:", CGRectMake(265, 104, 56, 58), "backward.fill", 29);
  c->play =
      button(c, "", "toggle:", CGRectMake(373, 91, 82, 81), "play.fill", 42);
  send<void>(c->play, "setKeyEquivalent:", string(" "));
  button(c, "", "forward:", CGRectMake(506, 104, 56, 58), "forward.fill", 29);
  button(c, "", "stop:", CGRectMake(584, 116, 34, 34), "stop.fill", 18);
  id speaker =
      send<id>(type("NSImageView"),
               "imageViewWithImage:", symbol("speaker.wave.2.fill", 19));
  send<void>(speaker, "setFrame:", CGRectMake(25, 188, 32, 26));
  send<void>(c->view, "addSubview:", speaker);
  slider(c, 0.5, "volume:", CGRectMake(74, 191, 650, 20), true);
  c->volumeLabel = label(c, "50%", CGRectMake(741, 189, 76, 23), 13, true);
  send<void>(c->volumeLabel, "setAlignment:", long(2));
  label(c, "QC Layout", CGRectMake(24, 230, 68, 20), 12);
  std::vector<std::string> names;
  for (auto n : layouts)
    names.push_back(n);
  c->layout = popup(c, names, "layout:", CGRectMake(87, 224, 144, 28));
  popup(c,
        {"Direct Channels (No Downmix)", "Downmix to Device", "QC Meters Only"},
        "monitor:", CGRectMake(248, 224, 232, 28));
  c->description = label(c, "", CGRectMake(501, 230, 195, 20), 11);
  c->exportButton =
      button(c, "Export PCM…", "export:", CGRectMake(712, 223, 104, 29));
  label(c, "PCM", CGRectMake(24, 492, 35, 20), 11);
  c->format =
      popup(c, {"WAV · 24 bit", "PCM · S24LE", "PCM · S32LE", "PCM · Float32"},
            nullptr, CGRectMake(60, 485, 147, 28));
  c->exportLayout = popup(c, {"Native Feeds", "QC Layout"}, nullptr,
                          CGRectMake(218, 485, 118, 28));
  c->status = label(c, "", CGRectMake(24, 518, 792, 19), 11);
  id menu = send<id>(send<id>(type("NSMenu"), "alloc"),
                     "initWithTitle:", string("hdmaxdec QC"));
  id root =
      send<id>(send<id>(type("NSMenuItem"), "alloc"),
               "initWithTitle:action:keyEquivalent:", string("hdmaxdec QC"),
               SEL(nullptr), string(""));
  id sub = send<id>(send<id>(type("NSMenu"), "alloc"),
                    "initWithTitle:", string("hdmaxdec QC"));
  id item = send<id>(
      send<id>(type("NSMenuItem"), "alloc"),
      "initWithTitle:action:keyEquivalent:", string("Quit hdmaxdec QC"),
      sel_registerName("quit:"), string("q"));
  send<void>(item, "setTarget:", c->controller);
  send<void>(sub, "addItem:", item);
  send<void>(root, "setSubmenu:", sub);
  send<void>(menu, "addItem:", root);
  send<void>(c->app, "setMainMenu:", menu);
  for (id o : {item, sub, root, menu})
    send<void>(o, "release");
  c->timer = send<id>(
      type("NSTimer"),
      "timerWithTimeInterval:target:selector:userInfo:repeats:", 1.0 / 30,
      c->controller, sel_registerName("tick:"), id(nullptr), BOOL(1));
  send<void>(c->timer, "retain");
  send<void>(send<id>(type("NSRunLoop"), "mainRunLoop"),
             "addTimer:forMode:", c->timer, NSRunLoopCommonModes);
  send<void>(c->window, "center");
  send<void>(c->window, "makeKeyAndOrderFront:", id(nullptr));
  send<void>(c->app, "activateIgnoringOtherApps:", BOOL(1));
}
} // namespace
int hdmaxdec_qc_main(int argc, char **argv) {
  try {
    std::string input, device, layout = "native";
    for (int i = 1; i < argc; ++i) {
      std::string a = argv[i];
      if (a == "--play")
        continue;
      if (a == "-i" || a == "--input") {
        if (++i >= argc)
          throw std::runtime_error("--play input missing");
        input = argv[i];
      } else if (a == "--layout" || a == "--device") {
        if (++i >= argc)
          throw std::runtime_error("--play option value missing");
        (a == "--layout" ? layout : device) = argv[i];
      } else if (a.rfind("-", 0) == 0)
        throw std::runtime_error("unsupported QC option: " + a);
      else if (input.empty())
        input = a;
      else
        throw std::runtime_error("only one QC input is supported");
    }
    Pool pool;
    App c(device);
    build(&c);
    c.engine.layout(layout);
    for (size_t i = 0; i < std::size(layouts); ++i)
      if (layout == layouts[i])
        send<void>(c.layout, "selectItemAtIndex:", long(i));
    if (!input.empty())
      c.engine.load(input);
    else
      send<void>(c.controller, "performSelector:withObject:afterDelay:",
                 sel_registerName("open:"), id(nullptr), 0.1);
    send<void>(c.app, "run");
    c.exportCancel = true;
    send<void>(c.timer, "invalidate");
    send<void>(c.timer, "release");
    send<void>(c.window, "orderOut:", id(nullptr));
    send<void>(c.window, "release");
    send<void>(c.controller, "release");
    return 0;
  } catch (const std::exception &e) {
    std::fprintf(stderr, "hdmaxdec QC: %s\n", e.what());
    return 1;
  }
}
