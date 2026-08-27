# Atmos-master Object onset / fast-motion pop — scheme selection

Branch: `cursor/dtsx-atmos-master-object-onset-3541` (off `main` @ `08b4478`).
Task: the DTS:X 爆音 that survives the landed silence-timeline fixes. Hardware
locus (Louis, 2026-08-27): **Atmos 母带 Object onset in the first few programme
frames, plus fast channel/object motion after the Atmos→7.1.4 map**. First
frames of both streams now play; the 7.1 HDMA/XLL compatibility bed is clean on
the same downmix; the defect lives in the DTS:X-private / height path. This is
**not** a DTS:X/XLL-X "object" concept — XLL-X carries four rendered height
planes, and the Atmos master's objects exist only upstream of the 7.1.4 render.

## PARENT_UPLOAD_REQUIRED — reference encodes still missing

`git fetch origin cursor/cloud-materials-3541` @ `f271e01` carries **no**
`cloud-fixtures/reference-streams/*.dtshd`. The two Mac-side encodes Louis
named are still required for byte-level differentials:

```text
/Users/sunyun_louis/Downloads/tbh.dtshd              → cloud-fixtures/reference-streams/tbh.dtshd
/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd → cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd
```

Mac-side push commands are in
`cloud-fixtures/reference-streams/WHERE_TO_PUT_ENCODES.md` on the materials
branch. This run therefore validates with the in-repo controlled vectors and
the recovered perfect-stream grammar notes only; no reference bitstream was
invented and no check silently passed for lack of input. ffmpeg is never used
as an acceptance decoder.

## Measured baseline defect (this VM, `main` @ `08b4478`)

The Linux-built Debug CLI (`swiftc -DDEBUG`, Swift 6.0.3) reproduces an
encoder-side grammar hole without any reference binary:

```text
hdmax encode-dtsx-control all-sine  ALL_SINE.dtshd 16 --frame-rate 24   # 12 hot planes
hdmax encode-dtsx-control channel-walk WALK.dtshd  24 --frame-rate 24   # 1 hot plane at a time
hdmax extract-xllx … ; hdmax inspect-xllx-private-frame …
```

| Vector | Active-frame segment bytes | Emitted two-segment NAVI width |
| --- | --- | --- |
| `all-sine` (dense, every plane hot) | ~2,700 + ~2,700 | **12-bit — every active frame** |
| `channel-walk` (one plane hot) | ~772 + ~779 | 11-bit |
| `channel-walk` (quiet tail) | 135 + 132 | 11-bit |

The recovered official corpus (Nature's Fury delivery grammar notes,
`cloud-fixtures/perfect-stream-grammar/`) exercises exactly three two-segment
NAVI widths: the canonical 11-bit three-data-byte word, and the 13/14-bit
four-data-byte words of large active frames. 8–10, 12, 15, 16 are
CRC-representable but never emitted. The encoder's
canonical-11-then-anything-representable order picks **12** for any frame whose
larger segment lands in 2,049–4,096 bytes — which is precisely the byte range
of the first dense height-active access units after silence (an object onset
rendered onto two or more height feeds) and of fast pans whose per-frame
magnitudes oscillate across the 2,048/4,096 boundaries. Every byte of that
12-bit form is individually valid, so Rice/partition/silence-form audits stay
green while a terminal bounded reader keyed to the recovered ladder misparses
the frame — a full-scale burst (爆音) confined to the DTS:X presentation, with
the public 7.1 bed untouched. That reader model also explains why the defect
survived every prior fix: none of them touched NAVI width selection.

## Schemes considered (≥5, distinct mechanisms)

### Scheme 1 — Pin delivery two-segment NAVI widths to the official 11/13/14 ladder  ← 择优

- **Mechanism.** In `DTSXPrivateFrameEncoder.navigationBitWidthCandidates`,
  restrict delivery two-segment frames to widths the corpus exercises:
  `[11, 13, 14].filter { $0 >= requiredBitWidth }`. Fix the encoder-side
  navigation size estimate to match `DTSXPrivateNavigation.serialize()`'s
  minimum-three-data-byte rule so size accounting can never diverge from the
  emitted bytes. Frames that needed 12 bits now emit the 13-bit four-data-byte
  word (one byte larger, still CRC-closed, still uniquely parseable);
  11-bit-canonical frames stay byte-identical.
- **Risk.** Low. Only the NAVI width choice of two-segment delivery frames
  changes; the qualified/reference `preferredBitWidth` path is untouched, the
  native encode→decode round trip re-verifies every frame, and non-hole
  encodes are byte-identical (checked below). 15/16-bit widths become
  unreachable errors — no legal four-plane 512-sample frame can need them
  (bounded-unary Rice caps a segment well under 8,192 bytes).
- **Validation without ffmpeg.** (a) `verify-xllx-native-encoder` gains
  `deliveryNavigationWidthLadderPassed`: a moderate vector must stay canonical
  11-bit and an incompressible full-scale vector must land 13-bit with every
  segment extent inside the former 2,049–4,096 hole, then decode bit-exactly.
  (b) `verify-dtsx-early-programme` gains rule 7: every parsed two-segment
  NAVI inside the startup/end windows must sit on the ladder, so any future
  regression is audited on real encodes, not just synthetic vectors.
  (c) `verify-dtsx-native-encoder` closed loops re-run the full delivery
  pipeline. (d) Controlled-vector NAVI dumps before/after
  (`extract-xllx` + `inspect-xllx-private-frame`): the `all-sine` active
  frames move 12 → 13; `channel-walk` stays 11 and byte-identical.
  Final acceptance remains Louis's hardware playback of the two Downloads
  encodes (PARENT_UPLOAD_REQUIRED above).

### Scheme 2 — Renderer-side object-onset conditioning (gain ramps from silence, softer slew)

- **Mechanism.** Reshape the rendered height PCM: start
  `DTS714ObjectGainSmoother` state at digital silence and slew up to the
  first declarations, and/or lengthen the slew window for dense fast-move
  retargets, so onsets reach the private encoder pre-softened.
- **Risk.** High, and empirically disproved. The `beginFromSilence` variant
  and the rate-exact slew variant were both hardware-tested earlier and
  **increased** pops (renderer comments record the verdict; the plane-level
  onset conditioning inside the source guard was likewise measured harmful and
  reverted). Official renders deliver hot programme heads unfaded, so this
  reshapes programme audio away from the reference behaviour. It also cannot
  explain the observed split: the public bed is a linear fold of the *same*
  planes and is clean, so the rendered PCM is not what breaks.
- **Validation.** `verify-dtsx-render-startup`, `verify-dtsx-render-guard`,
  gain-smoothing verifier — all local; but the hardware evidence already
  rejects the direction. **Rejected.**

### Scheme 3 — Invent a bridge form at the first height-active AU after silence/zero-height runs

- **Mechanism.** Emit a transitional private grammar (state re-declaration,
  forced-minimal ABIT, or content split) on the first active AU after the
  compact/no-NAVI or navigated-zero timeline, hypothesizing terminals need a
  state-establishing frame at the silence→active seam.
- **Risk.** High. The recovered corpus shows ordinary navigated active frames
  immediately following silence forms — no bridge form exists to copy, so this
  fabricates grammar the corpus never exercises, which is exactly the defect
  class being fixed (the misplaced-silence-form lesson from the tbh bed-hot
  head). Unverifiable without the reference binaries.
- **Validation.** Would require byte-level differentials against
  `tbh.dtshd` / `Dolby_NaturesFury.dtshd` (blocked, PARENT_UPLOAD_REQUIRED)
  plus hardware. **Rejected for this run.**

### Scheme 4 — Tighten Rice ABIT beyond the official bound at onsets

- **Mechanism.** If terminals bound the 5-bit ABIT allocation below 31, cap
  delivery ABIT at a recovered maximum (or force the linear escape on dense
  segments) so onset frames avoid large allocations.
- **Risk.** Medium. `terminalRiceOfficial` already reproduces both recovered
  Rice properties (mean-magnitude ABIT estimator, unary quotient ≤ 22); no
  recovered evidence shows an ABIT ceiling tighter than the estimator
  produces. An artificial cap lengthens unary runs (risking the quotient
  bound) or bloats segments, perturbing exactly the sizes Scheme 1
  stabilizes. Speculative without the reference corpus on disk.
- **Validation.** Corpus ABIT histogram from the two reference encodes
  (blocked, PARENT_UPLOAD_REQUIRED); native round-trip gates. **Deferred.**

### Scheme 5 — Pin private trailing-byte / alignment schedule to a frame-indexed official timeline

- **Mechanism.** `selectNavigation` chooses the 2–7 trailing frame bytes
  first-fit for 32-bit closure. If official active frames pin a specific
  trailing count per form, an off-schedule count could alias in a bounded
  reader the same way an off-ladder width does.
- **Risk.** Medium-low but speculative: the parse already requires unique
  closure over 0–7 trailing bytes and every frame round-trips bit-exactly;
  no recovered note reports a trailing-count schedule. Needs the reference
  binaries to extract one.
- **Validation.** Trailing-count survey over the two reference encodes
  (blocked, PARENT_UPLOAD_REQUIRED). **Deferred.**

### Scheme 6 — ExSS asset-descriptor seam audit at large private-frame size jumps

- **Mechanism.** An object onset grows the private frame ~50× in one AU
  (52 B silence → ~5.5 KB active). If the DTS:X asset-descriptor signal
  (offsets/sizes) mis-declared across that jump, a terminal would desync at
  exactly onset.
- **Risk.** Low as an audit, but no defect found: the integrated safety
  report already requires `headerByteCount == 40`,
  `assetDescriptorByteCount == 23`, and
  `xllXByteOffset + xllXFrameByteCount == xllByteCount` on **every** frame of
  every verified encode, including the onset AUs of the probe vectors.
- **Validation.** Already enforced per-encode
  (`allDTSXAssetDescriptorsMatchPrivateFrames`). **Kept as audit; no change.**

## 择优 rationale

Scheme 1 is chosen because it is the only candidate that is
**perfect-stream-aligned rather than heuristic** (it forbids grammar the
corpus never exercises instead of reshaping audio or inventing new forms), has
a **reproducible encoder-side defect measured on this VM** whose trigger
byte-range maps one-to-one onto the reported hardware locus (dense height
onset + fast motion, first frames fine, bed fine), explains why every
bitstream verifier stayed green while playback was wrong (each off-ladder byte
is individually valid), and ships with **native regression gates** on both the
synthetic-vector level and the encoded-stream audit level. Schemes 2 and 3
are rejected on prior hardware evidence and corpus-fabrication risk; Schemes
4 and 5 stay documented as deferred follow-ups that require the
PARENT_UPLOAD_REQUIRED reference encodes; Scheme 6 found no defect.

Implementation: cherry-pick of the candidate tip
`cursor/dtsx-xllx-atmos-object-pop-3541` @ `3525484` ("Pin delivery XLL-X
NAVI widths to the official 11/13/14-bit ladder") onto this branch — treated
here as the implementation of Scheme 1, still **not** hardware-proven until
Louis plays the two re-encodes.

## Test results (this branch, Linux Debug CLI)

See the final report in the pull-request description for the exact command
outputs; summary:

- `verify-xllx-native-encoder` — pass, including the new
  `deliveryNavigationWidthLadderPassed` gate (moderate vector 11-bit,
  full-scale vector 13-bit with all extents inside the former hole).
- `verify-dtsx-native-encoder` — pass (all closed-loop, startup-transition,
  bed-timeline, early-programme, render-guard and smoothing gates).
- Controlled probes: `all-sine` active frames 12-bit → **13-bit**;
  `channel-walk` stays 11-bit and **byte-identical** to the `main` encode;
  integrated encode verification (`isVerified`) passes for both.
- Hardware/commercial-stream differential: **external** until the
  PARENT_UPLOAD_REQUIRED binaries land.
