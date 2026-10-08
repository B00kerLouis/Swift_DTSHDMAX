# Switt_DTSHDMAX

`Switt_DTSHDMAX` is a native Swift 6 research implementation for DTS-HD Master
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
hdmax -i INPUT -o OUTPUT.dtshd [--frame-rate FRAME_RATE]
```

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
  -project Switt_DTSHDMAX.xcodeproj \
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
