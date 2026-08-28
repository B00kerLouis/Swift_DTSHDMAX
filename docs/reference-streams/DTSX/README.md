# Nature's Fury DTS:X reference streams (cloud handoff)

This package is the cloud-agent handoff for the commercial perfect stream Louis
keeps on the local Mac research volume. The tracked repository is source-only
on `main` (`/Research/` is gitignored). This feature branch therefore carries
**manifest + oracle metadata + recovery notes**, not the multi-megabyte
binaries themselves, until they are force-staged from a mounted volume.

## Requested upload paths (local Mac)

```text
/Volumes/HP_SSD_FX900_Pro /Xcode_WorkSpace/Swift_DTSHDMAX/Research/reference-streams/DTSX/Dolby_Natures_Fury_HDMAX_Digital_Delivery.dtshd
/Volumes/HP_SSD_FX900_Pro /Xcode_WorkSpace/Swift_DTSHDMAX/Research/reference-streams/DTSX/Dolby_Natures_Fury_HDMAX_Digital_Delivery.dtspbr
/Volumes/HP_SSD_FX900_Pro /Xcode_WorkSpace/Swift_DTSHDMAX/Research/reference-streams/DTSX/Dolby_Natures_Fury_HDMAX_Digital_Delivery.dtshd_log.txt
```

Workspace-relative equivalents (when Research is present):

```text
Research/reference-streams/DTSX/Dolby_Natures_Fury_HDMAX_Digital_Delivery.dtshd
Research/reference-streams/DTSX/Dolby_Natures_Fury_HDMAX_Digital_Delivery.dtspbr
Research/reference-streams/DTSX/Dolby_Natures_Fury_HDMAX_Digital_Delivery.dtshd_log.txt
```

## Cloud mount status (this run)

| Asset | Present in cloud VM |
| --- | --- |
| `.dtshd` elementary stream | **No** — Mac volume not mounted |
| `.dtspbr` bitrate / navigation sidecar | **No** |
| `.dtshd_log.txt` Encoder Suite style log | **No** |

Do **not** invent binary payloads. Prefer the in-repo controlled vectors
(`SyntheticPCM.controlledDTS714`, `encode-dtsx-control`, startup-seam sweep)
until the three files are force-added under `docs/reference-streams/DTSX/` or
`Research/reference-streams/DTSX/`.

## Oracle identity (from `DTSXReferenceSet`)

The three delivery stems currently share one byte-identical elementary stream:

| Stem | Mode |
| --- | --- |
| `Dolby_Natures_Fury_HDMAX_BD` | blu-ray-disc |
| `Dolby_Natures_Fury_HDMAX_Digital_Delivery` | digital-delivery |
| `Dolby_Natures_Fury_HDMAX_SCSA` | scsa |

Canonical SHA-256 (shell-verified, published in source):

| File | SHA-256 |
| --- | --- |
| `*.dtshd` | `aac7ab3d927174b1414e008d41bcfcdafbbf18428836058ce2b8cf2e0db0d1c6` |
| `*.dtspbr` | `2a55ff6a771cb1ddff97feb674f10f1d6ece5aafc97af420c9e51ece71f639fb` |

When binaries appear, verify with:

```bash
shasum -a 256 Dolby_Natures_Fury_HDMAX_Digital_Delivery.dtshd
shasum -a 256 Dolby_Natures_Fury_HDMAX_Digital_Delivery.dtspbr
```

## Grammar recovered from this oracle (product-relevant)

These are already encoded in the Swift sources; keep them stable while fixing
startup / mid-stream terminal symptoms:

1. **Silent startup partition**: Nature's Fury-style silent start uses public
   XLL **4×128** for the first non-priming silent access units; mid-stream
   settles on **2×256**.
2. **Core priming**: two 512-sample priming AUs; `nuInitLLDecDlyFrames = 0`
   (trim is the priming pair itself). Priming must **not** declare research-only
   decorrelation / non-identity channel order / shared entropy if terminals are
   to play from AU0.
3. **Private XLL-X**: branch-zero routing, bounded unary Rice (official mean
   magnitude ABIT, quotient ≤ 22), frame-indexed silence grammars
   (no-NAVI compact → compact navigated 4×128 → mid-stream 2×256 silence).
4. **Height routing**: stable routing word across private frames in this
   reference set.

## Related delivery artifacts

Release encode of `OUTPUT.dtshd` also writes:

```text
OUTPUT.dtspbr
OUTPUT.dtshd_log.txt
```

Inspectors / reproducers:

- `DTSXReferenceSet` / `DTSXReferenceSetVerifier`
- `DTSXReferenceReproducer`
- `DTSXOracleVectorGenerator` (expects Research log paths)

## Controlled vectors (local HDMA/Core already green)

Use these instead of the commercial stream when it is absent:

```text
hdmax encode-dtsx-control silence|impulse:CHANNEL|frame-edge:CHANNEL|sine:CHANNEL|fullscale:CHANNEL|all-sine|channel-walk OUTPUT.dtshd PCM_FRAME_COUNT --frame-rate …
hdmax verify-hdma
hdmax verify-core-syntax
hdmax verify-dtsx-startup-seams
hdmax verify-dtsx-native-encoder
hdmax verify-xllx-native-encoder
hdmax verify-dtsx-channel-allocation
```

## Manifest file

See `MANIFEST.json` in this directory for machine-readable handoff status.

## Uploaded materials

The supplied files are classified and recorded in [`MATERIALS.md`](MATERIALS.md).
They are stored in 10 MiB-or-smaller archive segments because GitHub LFS is
unavailable for this repository. See [`ARCHIVES.md`](ARCHIVES.md) to restore
the reference streams and the three-file Dolby Atmos Master Format package.
