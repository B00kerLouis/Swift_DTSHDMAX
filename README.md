# Swift_DTSHDMAX

`Swift_DTSHDMAX` is a native Swift 6 research implementation for DTS-HD Master
Audio and DTS:X HDMA authoring workflows. The project implements its own
bitstream handling, PCM processing, Core and XLL paths, container extraction,
Atmos input handling, and validation tools. It does not link to or call an
external codec at runtime.

This is interoperability research software. It is not an official DTS encoder,
decoder, certification result, or trademark license.

## Products

The Xcode project contains three shared schemes and targets:

- `cli` builds the Mach-O command-line executable `hdmax`.
- `Framework` builds `libhdmax.framework`, with native Swift and Objective-C
  entry points that share the CLI behavior.
- `Build ALL` builds both products.

The public framework entry point is `HDMAX`. Swift callers use
`HDMAX.run(arguments:)`; Objective-C callers use the corresponding `NSError`
bridge.

## Supported inputs and outputs

The Release CLI has one production entry point:

```text
hdmax -i INPUT -o OUTPUT.dtshd [--encode-mode auto|standard] [--frame-rate FRAME_RATE]
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

Input routing is automatic:

| Input | Output |
| --- | --- |
| 48 kHz, 24-bit 5.1 or 7.1 PCM WAVE | DTS HDMA |
| DAMF Atmos | DTS:X HDMA after native 7.1.4 rendering |
| ADM BWF | DTS:X HDMA after native 7.1.4 rendering |
| IMF IAB MXF | DTS:X HDMA after native 7.1.4 rendering |

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

Build both products with Xcode:

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
```

GitHub Actions builds both products in Release and optimized Debug with
Xcode 26.3, then runs the in-memory encoding-mode, navigation-width, private
entropy and integrated DTS:X regressions. Full official-player programme
acceptance requires the local player and external test media.

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

The tracked repository is source-only. Local research materials, scripts,
tests, generated artifacts, and agent instruction files are deliberately
ignored and are never included in `main` by ordinary Git staging commands.

## License

This project uses `LicenseRef-Swift-DTSHDMAX-Research`, a source-available
research license and not an OSI open-source license. Downstream permission is
limited to noncommercial encoding research with the Swift implementation,
education, and experimental validation. Commercial use, reverse engineering,
and non-Swift translation or reimplementation require separate written
authorization. Commercial use also requires prior written authorization from
DTS, Inc., its parent company Xperi Inc., and B00kerLouis, each for the rights it
controls. See
[LICENSE](LICENSE) and the [full research license](LICENSES/LicenseRef-Swift-DTSHDMAX-Research.txt).
