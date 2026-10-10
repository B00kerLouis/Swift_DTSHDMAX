# hdmaxdec

Copyright (c) 2026 B00kerLouis. LGPL-2.1-or-later.

An independent C17/C++17 decoder for this project's 48 kHz, 24-bit Core/ExSS/XLL delivery streams, standard branch-0 DTS:X, and D0 IMAX. Decoding does not link the Swift encoder, an external codec library, or an external decoder process.

## Targets and shared products

The Xcode project owns `decoder cli` (`hdmaxdec`) and `decoder framework` (`libhdmaxdec.framework`), both targeting macOS 12.5+. `Build ALL` builds both encoder and decoder families. Normal products share `Build/Products/Release` or `Build/Products/Debug`: `hdmax`, `libhdmax.framework`, `hdmaxdec`, `libhdmaxdec.framework`, and `hdmaxdec QC.app`.

Build on macOS with Xcode 26.3:

```sh
xcodebuild -project Swift_DTSHDMAX.xcodeproj -scheme "Build ALL" \
  -configuration Release -derivedDataPath Build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Use `decoder cli` or `decoder framework` to build a decoder target independently. Use a separate `OBJROOT` when running concurrent investigations. The Framework uses `@rpath`; keep it beside the CLI. The QC application embeds its own Framework using Xcode's Copy Files phase. Its executable/plist packaging phase retains the build-script sandbox and declares its inputs and outputs.

Linux and Windows use the standalone CMake project:

```sh
cmake -S hdmaxdec -B Build/hdmaxdec -DCMAKE_BUILD_TYPE=Release
cmake --build Build/hdmaxdec --config Release
ctest --test-dir Build/hdmaxdec -C Release --output-on-failure
```

Windows supports MSVC C++17 and MinGW-w64, with WASAPI and system COM libraries. Linux needs ALSA development headers, such as `libasound2-dev`. Paths and device IDs use UTF-8. Windows CLI arguments are converted from Unicode. The macOS GUI sources and AppKit dependencies are excluded from Windows/Linux builds.

## macOS QC player

```sh
Build/Products/Release/hdmaxdec --play INPUT.dtshd
Build/Products/Release/hdmaxdec --play -i INPUT.dtshd --layout 7.1.5
Build/Products/Release/hdmaxdec --play
```

`--play` opens a dark, QuickTime-style player. Double-clicking `hdmaxdec QC.app` opens the same interface. Controls include play/pause, stop, ten-second skips, seek, monitoring volume, Peak/RMS meters, peak hold, clipping counts, channel Solo, QC layout selection, and PCM export. The interface is English. Filenames and endpoint names retain their original spelling.

Meters and Solo labels use Dolby-style names: `L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr`, top-middle `Ltm Rtm`, and wide `Lw Rw`. IMAX TFC is displayed as `Ctf`. These display names do not change speaker IDs or PCM order.

The QC layout is independent of the DAC: a stereo device can inspect and export 7.1.5, 7.1.6, or 9.1.6. **Direct Channels (No Downmix)** sends only position-matched feeds to the device while retaining all virtual QC feeds. **Downmix to Device** explicitly folds the QC layout; **QC Meters Only** disables monitoring. Clicking a meter solos that feed to front L/R. Additional speakers with no encoded feed remain silent.

Metering occurs before monitoring volume and DAC clipping. Export does not apply monitoring volume. The UI runs on the main thread; decoding, header measurement, Core-history seeking, and export run on background threads. Meter snapshots are displayed at 30 fps. There is no whole-programme PCM cache, UI persistence database, or checkpoint model.

The GUI is compiled entirely as C++, using the system AppKit/Core Graphics boundary through Objective-C runtime C APIs. It contains no `.m`, `.mm`, or Swift implementation. C++ runtime, Objective-C++, SwiftUI, Qt, and WebView approaches were evaluated; C++ runtime preserves the language constraint and platform isolation.

## PCM export and CLI playback

```sh
hdmaxdec devices
hdmaxdec decode INPUT.dtshd OUTPUT.wav
hdmaxdec decode INPUT.dtshd STEREO.wav --layout 2.0
hdmaxdec play INPUT.dtshd --device DEVICE_ID
hdmaxdec export-pcm INPUT.dtshd OUTPUT.wav
hdmaxdec export-pcm INPUT.dtshd OUTPUT.pcm --format s32 --layout 9.1.6
```

`export-pcm` supports RF64/WAV 24-bit, raw S24LE, left-justified S32LE, and Float32LE. GUI export selects either native feeds or the current QC layout. Export uses an independent decoder, bounded buffers, progress, and cancellation. A sibling temporary file is committed only after successful decoding and output close. Cancellation or failure preserves an existing destination; input/output aliasing is rejected.

WAV uses WAVEFORMATEXTENSIBLE order and supports files larger than 4 GiB. Thirteen feeds including TFC are representable. Wide/top-side positions in 7.1.6 and 9.1.6 cannot be accurately labelled with the standard WAVE mask; use raw PCM or the C/AVFrame API. Raw output is little-endian and interleaved in the explicit selected layout order.

`devices` queries the default endpoint; `--device ID` queries or selects a specific endpoint. IDs are Core Audio UIDs on macOS, WASAPI endpoint IDs on Windows, and ALSA PCM names on Linux. Headless `play` uses the endpoint's declared layout. Unknown positions require an explicit configuration, with a matching count when the count is known. Flexible ALSA PCM capabilities do not identify the server's speaker arrangement and are reported as unknown.

Named layouts: `2.0`, `5.1`, `7.1`, `5.1.2`, `5.1.4`, `7.1.2`, `7.1.4`, `7.1.5`, `7.1.6`, `9.1.6`. The 5.1 preset uses sides; two-height presets use TFL/TFR; 7.1.5 adds TFC; 9.1.6 adds WL/WR and TSL/TSR. The C API can specify other explicit arrangements. Exact matches remain unity, missing side/rear feeds fold, and missing heights are remapped. Without tops, standard Q15 folds and IMAX TFC/unity folds remain distinct. LFE routes only to LFE; bass management is a host policy.

The headless decode/play commands retain automatic uniform peak headroom for remixes unless `--gain` is supplied. Native output retains gain 1. Final statistics include peak, RMS, maximum sample jump, clipping, and full-scale counts.

## Stream contract

1. DTSHDHDR chunks have an eight-byte tag and big-endian u64 length. Decode only STRMDATA AUs; apply AUPR-HDR source count and 1024-sample priming once. Raw Core-compatible streams lack an exact source count and retain coded tails.
2. Core sync is `0x7ffe8001`, with 48 kHz AMODE 9, five QMF feeds and 64x LFE. QMF, ADPCM and LFE history span frames. `hdmaxdec_decode_core` explicitly accepts standalone Core packets.
3. ExSS sync is `0x64582025`. Validate the single-asset static profile, speaker pairs, XLL size, CRC, and standard/IMAX private ranges.
4. XLL sync is `0x41a29547`. Decode common/channel headers, segment-major NAVI, Linear/Rice/Hybrid entropy, Part-A seeds, Part-B residuals, fixed/LPC prediction, pair decorrelation and scalable LSBs.
5. Recover the 6+2 hierarchy from Core, public residuals, Q16 scales and Q15 undo-downmix before publishing the explicit speaker order.
6. Standard XLL-X sync is `0x02000850`. Decode branch-0 routing, predictors, CRC and entropy using `max(8, public nBits4SSize)`. Compact navigated zeros still validate that width. Accept the exact canonical 48-byte zero grammar only for 2x256 with public width <=8.
7. D0 sync is `0xf14000d0`. Validate fixed metadata, mono TFC and quartet height groups, shared widths, CRC, and 2/4/8 partitions. Undo TFC C/L/R Q15 27571/13818/13818 and unity corner-height folds.

File reading retains at most a 1 MiB compressed window plus bounded PCM frames. Accurate seeking replays Core history from the beginning and is cancellable; seeking near EOF is linear-time. A file NAVI entry alone cannot restore Core history.

## C and FFmpeg integration

Each decoder context is single-threaded; independent contexts may run concurrently. `hdmaxdec_decode` takes complete elementary AUs or raw XLL frames. `HD_NEED_MORE` consumes zero bytes. Returned PCM is signed-24, right-justified, planar and borrowed until the next decode/reset/destroy.

`hdmaxdec_file_read` returns `HD_OK` for a frame, `HD_NEED_MORE` at normal EOF, and a negative status for corruption or I/O failure. `hdmaxdec_file_measure` scans raw AU headers for duration; `hdmaxdec_file_seek_progress` enables cancellable history replay. Windows playback open/write/drain/close must use the same calling thread.

Optional `ffmpeg/hdmaxdec_avframe.c` copies to an owning S32P AVFrame using left-justified samples and custom channel order, preserving TFC, top-middle and wide feeds. It requires libavutil >=58 and does not add a codec runtime dependency to the default library.

```sh
cmake -S hdmaxdec -B Build/hdmaxdec-ffmpeg -DHDMAXDEC_FFMPEG=ON
cmake --build Build/hdmaxdec-ffmpeg
ctest --test-dir Build/hdmaxdec-ffmpeg --output-on-failure
hdmaxdec decode INPUT.dtshd - --layout 7.1.4 --format f32 | \
  ffmpeg -f f32le -ar 48000 -ch_layout "FL+FR+FC+LFE+BL+BR+SL+SR+TFL+TFR+TBL+TBR" \
    -i - -c:a pcm_s24le OUTPUT.wav
```

Hosts demux MKV/MOV/TS, assemble complete AUs, and handle packet PTS, container skip/discard samples and format changes. The adapter is an AVFrame integration boundary rather than a stock FFmpeg codec registration plugin. Public interfaces follow the [channel-layout API](https://ffmpeg.org/doxygen/trunk/channel__layout_8h_source.html) and [decode API](https://ffmpeg.org/doxygen/trunk/group__lavc__decoding.html).

## Validation and scope

Regressions cover deterministic stereo/5.1/7.1 and layered Core/private vectors, extreme values, predictor history, ten speaker layouts, impulse routing, standard/IMAX folds, truncation, 4096 malformed vectors, PCM export precision, cancellation and Unicode paths. `hdmaxdec_tests FILE...` checks complete programmes, exact source counts, EOF re-entry and stop/play reset. Playback material must be at least 90 seconds long.

Programme media, measurements and research reports remain local under ignored `Research/`. The supported contract is this encoder's auto/standard, vision 1/2 delivery profile. Other commercial object grammars, Core Huffman/non-AMODE-9, non-48-kHz audio, PBR fragmentation, multiple assets and private research branches 1/2/3 are outside qualification. PCM correctness and system playback do not establish hardware DTS:X/IMAX presentation acceptance or certification.

The decoder uses **LGPL-2.1-or-later**, matching [FFmpeg's default license](https://ffmpeg.org/legal.html). Its grant, complete LGPL text and incorporated GPL text are in the root [LICENSES/](../LICENSES/README.md) directory. The encoder's separate research license remains in force. CMake installs the decoder license texts under `share/hdmaxdec/LICENSES/`; keep the root license directory with source distributions.
