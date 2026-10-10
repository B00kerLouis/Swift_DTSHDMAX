# Swift_DTSHDMAX

`Swift_DTSHDMAX` is a native Swift 6 research implementation for DTS-HD Master
Audio and DTS:X HDMA authoring workflows. The project implements its own
bitstream handling, PCM processing, Core and XLL paths, container extraction,
Atmos input handling, and validation tools. It does not link to or call an
external codec at runtime.

This is interoperability research software. It is not an official DTS encoder,
decoder, certification result, or trademark license.

## Products

The Xcode project contains four product targets and the `Build ALL` shared scheme:

- `cli` builds the Mach-O command-line executable `hdmax`.
- `Framework` builds `libhdmax.framework`, with native Swift and Objective-C
  entry points that share the CLI behavior.
- `decoder cli` builds the independent C/C++ executable `hdmaxdec` and the
  macOS QC application `hdmaxdec QC.app`.
- `decoder framework` builds `libhdmaxdec.framework`.
- `Build ALL` builds both encoder and decoder families.

See [hdmaxdec/README.md](hdmaxdec/README.md) for decoder playback, PCM export,
speaker layouts, FFmpeg integration and Windows/Linux CMake builds. Decoder
licensing is LGPL-2.1-or-later; component grants and complete texts are collected
in [LICENSES/](LICENSES/README.md).

The public framework entry point is `HDMAX`. Swift callers use
`HDMAX.run(arguments:)`; Objective-C callers use the corresponding `NSError`
bridge.

## Supported inputs and outputs

The Release CLI has one production entry point:

```text
hdmax -i INPUT -o OUTPUT.dtshd [--dtsx-vision 1|2] [--encode-mode auto|standard] [--frame-rate FRAME_RATE]
```

`--encode-mode` is optional and defaults to `auto`. Auto enables frame-local
prediction and searches 2x256, 4x128 and 8x64 partitions using serialized public
XLL cost, including headers, navigation and alignment. The private provider
encodes once after selection and uses the same partition and shared NAVI width.
The established priming and fully silent startup/tail forms remain explicit.
`standard` disables temporal prediction and retains the qualified two-segment
delivery with its four-segment silent-start transition. Both modes use bounded
Straight Rice and keep Branch-0 private routing.

Framework callers use the same optional argument with `HDMAX.run(arguments:)`
or `executeWithArguments:error:`. `HDMAX.supportedEncodeModes()` returns
`auto` and `standard`. Typed Swift APIs accept `encodeMode: DTSEncodeMode = .auto`
in `DTSAutomaticEncoder.encode`, `HDMAEncoder`, `DTSXNativeHDMAEncoder`, and
`DTSXHDMAEncoderConfiguration`.

`--dtsx-vision` is optional and defaults to `1`, preserving the existing 7.1.4
DTS:X path. `2` selects fixed IMAX 12.1: thirteen PCM channels including Top
Front C. It retains default `auto` prediction and public 2/4/8 partition
selection. `standard` disables prediction and keeps explicit priming,
silent-start and zero-height frame policies. Framework callers use the same
argument; `HDMAX.supportedDTSXVisions()` returns `1` and `2`. Typed callers can
pass `dtsxVision: .imax` to `DTSAutomaticEncoder.encode`, or use
`DTSIMAXRenderer` and `DTSIMAXNativeHDMAEncoder`. The existing typed automatic
encoding overload remains available.

Vision 2 accepts Atmos masters or 48 kHz packed 24-bit, thirteen-channel WAVE.
A zero mask uses `L R C LFE Lss Rss Lsr Rsr TFL TFR TBL TBR TFC`. Mask `0x2f63f`
uses ascending WAVE speaker-bit order. Plain 5.1/7.1 WAVE retains its existing
HDMA route by default; IMAX selection requires the thirteen-channel input.
Ordinary WAVE still requires `--frame-rate`.

Input routing is automatic:

| Input | Output |
| --- | --- |
| 48 kHz, 24-bit 5.1 or 7.1 PCM WAVE | DTS HDMA |
| DAMF Atmos | DTS:X HDMA after native 7.1.4 rendering |
| ADM BWF | DTS:X HDMA after native 7.1.4 rendering |
| IMF IAB MXF | DTS:X HDMA after native 7.1.4 rendering |
| Atmos input with `--dtsx-vision 2` | DTS:X IMAX HDMA after fixed 12.1 rendering |
| 13-channel PCM WAVE with `--dtsx-vision 2` | DTS:X IMAX HDMA |

The output file must use the `.dtshd` extension. Delivery also writes:

```text
OUTPUT.dtspbr
OUTPUT.dtshd_log.txt
```

Release displays a single, continuously refreshed ASCII progress bar on
standard error. Its JSON delivery report remains on standard output so it can
be consumed by automation. Research and diagnostic subcommands are available
only in Debug builds and are not exposed in the Release help text.

## Frame rates

Supported non-drop SMPTE frame rates are:

```text
23.976  24  25  29.97  30  47.952  48  50  59.94  60
```

DAMF and IMF IAB inputs use embedded timing metadata. PCM WAVE and ADM BWF
inputs require `--frame-rate` when no authoring rate is available. A supplied
override must agree with any embedded rate. Drop-frame timecode is rejected.

## Build

Build all products with Xcode:

```bash
xcodebuild \
  -project Swift_DTSHDMAX.xcodeproj \
  -scheme "Build ALL" \
  -configuration Release \
  -derivedDataPath Build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The Release products are placed under `Build/Products/Release/`:

```text
hdmax
libhdmax.framework
hdmaxdec
libhdmaxdec.framework
hdmaxdec QC.app
```

GitHub Actions builds both families in Release and optimized Debug with
Xcode 26.3, then runs the in-memory encoding-mode, navigation-width, private
entropy and integrated DTS:X regressions. Full official-player programme
acceptance requires the local player and external test media. The independent
decoder workflow also builds and tests Linux GCC/libavutil and Windows MSVC.

Example:

```bash
Build/Products/Release/hdmax \
  -i INPUT.wav \
  -o OUTPUT.dtshd \
  --frame-rate 24
```

## Engineering scope

The implementation uses planar integer PCM internally and includes native
parsers, writers, validation, Core decoding, XLL decoding, XLL encoding, and
the Core plus XLL HDMA delivery path. DTS:X authoring renders supported Atmos
inputs to a 7.1.4 PCM representation before native encoding.

Atmos object gains are sample-continuous. The 7.1.4 renderer keeps per-object
Q30 gain history, ramps ordinary automation over one pan sub-block, and limits
large moves to at most `1/480` full-scale gain per sample. A target that arrives
mid-ramp starts from the exact current gain, preventing zipper steps across the
four height feeds without inserting a limiter into the lossless PCM path.

The DTS:X private profile preserves rendered height PCM but does not yet retain
independent object identifiers or object trajectories. Hardware playback and
formal DTS certification remain external acceptance requirements.

The IMAX profile encodes independent TFC and four-height audio groups behind
the `F14000D0` fixed presentation. Both groups contribute to the shared NAVI
width before public headers, LSB byte counts and ExSS offsets are finalized.
Its compatibility fold includes TFC in C/L/R; the linked source guard covers
those composite and Core-recovery constraints. Legacy rendering and panning
remain isolated from IMAX. Debug exposes `verify-dtsx-imax-encoder` for predictor,
width, CRC, TFC slew and composite-headroom checks. Independent PCM decode and
actual IMAX presentation playback remain separate qualification results.

Public XLL and private XLL-X navigation use one width contract: private entries
use `max(8, nBits4SSize)` from the enclosing XLL header. Both layers contribute
to that width before headers, LSB byte counts, and offsets are finalized.
Full-stream structure verification rejects mismatched widths, which otherwise
can pass an isolated native PCM round-trip while producing clipped height
audio in a presentation decoder. Debug builds expose
`verify-dtsx-navigation-width` for in-memory boundary regressions.

DTS:X delivery uses frame-local fixed order 0/1 or quantized LPC with explicit
Straight Rice. The parameter estimate uses mean absolute magnitude and bounds
every unary quotient, including predictor initialization samples, to 22.
Branch-0 routing and the delivery hierarchy remain fixed. Predictor choices
follow the local PCM and serialized coding cost; this does not claim identical
encoder decisions or a complete reproduction of the official distribution.

Compact silent navigation also follows the enclosing XLL width. Fully silent
2x256 programme tails with public width at most eight use the canonical
48-byte zero form. File-level seek navigation uses a seven-byte prefix and
ordinary big-endian 32-bit offsets, verified against every access unit. These
rules cover pause/resume, stop/play and re-entry near the end of a programme.

## Repository policy

The tracked repository is source-only. Local research materials, exploratory
scripts and tests, generated artifacts, and agent instruction files stay
ignored. Decoder regression tests and their deterministic synthetic fixtures
are tracked for clean-checkout CI. Research archives are published only when
explicitly requested by the human.

## License

The Swift encoder uses `LicenseRef-Swift-DTSHDMAX-Research`, a source-available
research license and not an OSI open-source license. Downstream permission is
limited to noncommercial encoding research with the Swift implementation,
education, and experimental validation. Commercial use, reverse engineering,
and non-Swift translation or reimplementation require separate written
authorization. Commercial use also requires prior written authorization from
DTS, Inc., its parent company Xperi Inc., and B00kerLouis, each for the rights it
controls. The independent decoder, its CLI/QC interface and Framework use
`LGPL-2.1-or-later`; the encoder restrictions do not apply to them. See the
[component license index](LICENSES/README.md),
[full research license](LICENSES/LicenseRef-Swift-DTSHDMAX-Research.txt), and
[decoder grant](LICENSES/hdmaxdec-LGPL-2.1-or-later.txt).
