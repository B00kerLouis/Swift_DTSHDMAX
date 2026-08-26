# DTS:X-only defect: private XLL-X silence-form timeline schemes and selection

Branch: `cursor/dtsx-xllx-only-defect-3541`
(base `origin/cursor/dtsx-tbh-firstframe-atmos-3541`, materials from
`origin/cursor/cloud-materials-3541`). Model: `claude-fable-5-thinking-xhigh`.

Status snapshot this document responds to (Louis, 2026-08-26, after the
`dtsx-tbh-firstframe-atmos-3541` tip):

1. Nature's Fury: plays (可播). tbh: **first frame still unplayable**.
2. 爆音 unchanged - **这一版没有任何进展也没有任何退步**. The prior
   P1/P2/P3 tip (delivery priming for the *public* XLL, render-native onset
   passthrough, Core recovery headroom) is hardware-flat: those were not
   the active defect.
3. Pops still correlate with **Atmos master object** onsets/fast moves
   (DAMF/IAB/ADM essence), not DTS:X/XLL-X objects.
4. **Key new insight:** the downmix is shared - **the 7.1 DTSHD / public
   XLL compatibility bed plays OK; only the DTS:X presentation fails.**
   The defect must therefore live on a DTS:X-unique path: the private
   XLL-X layer (heights), its grammar timeline, NAVI/entropy, or DTS:X
   packaging - not in the shared Core/7.1 HDMA code Louis certifies.
5. No ffmpeg anywhere; HDMA and Core must not regress.
6. `cloud-fixtures/reference-streams/{tbh,Dolby_NaturesFury}.dtshd` are
   **still not on this VM** - **PARENT_UPLOAD_REQUIRED**
   (`UPLOAD_BLOCKED.md`, `WHERE_TO_PUT_ENCODES.md`). Everything below is
   validated with `cloud-fixtures/test_X` controllable vectors and
   `cloud-fixtures/perfect-stream-grammar`.

## Root cause: the private silence-form timeline leaks Core-priming
## declarations over audible content (bed OK / DTS:X bad)

The DTS:X delivery carries two streams: the public XLL compatibility bed
(shared with plain HDMA, certified OK) and the private XLL-X extension
(heights + DTS:X presentation). A terminal that plays the 7.1 bed
correctly but fails the DTS:X presentation is reading a broken *private*
timeline. This tip's audit found exactly that, keyed to hot starts:

The official corpus uses three private silence forms on a strict,
frame-indexed timeline:

| Frame | Form | Size |
| --- | --- | --- |
| AU0-AU1 (Core priming) | canonical compact zero form | 48 B |
| AU2-AU3 *only if the whole start is silent* | 4x128 startup silence pair (code 16, no NAVI / code 0x11) | 52/56 B |
| Any other silent source AU | mid-stream 2x256 code-0x20 source silence | 52 B |

`DTSXPrivateStreamEncodingSession.encodeFrame` gated the mid-stream
code-0x20 form at `frameIndex >= primingFrameCount + 2`. On a **hot start**
(bed active from sample zero, heights silent - exactly tbh), the public
partition is 2x256 from AU2, the 4x128 startup forms never apply, and the
gate made source AU2/AU3 fall through to the generic zero path - which
serializes the **48-byte canonical compact zero form: the Core-priming
declaration**. The delivered private timeline read *priming, priming,
priming, priming*, first grammar change at AU4. A terminal keying priming
on that declaration extends the priming window over the first audible
frames - "first frame unplayable", precisely `PROJECT_MEMORY.md`'s
recorded *"first frames unplayable until AU3"*, now confined to the
private layer. The bed stream is untouched and correct, so the 7.1
presentation plays; only DTS:X fails. Nature's Fury starts silent, its
window frames are legitimately startup silence, so it plays.

The onset-pop side is the same timeline defect at the other edge: the
4x128 startup nomination was previously per-frame (`heightsAreSilent`
of that one AU), so a start with Atmos-object-driven height/bed activity
at *one* of the two window frames emitted a lone startup declaration the
corpus never pairs with a half-active window, forcing a 4x128→2x256
reconfiguration against already-audible content in the height decode
path - the bed keeps playing, the DTS:X height path clicks. This matches
"pops at Atmos master object onsets" because master-object onsets are what
make the rendered height/bed planes go active mid-window.

## Schemes considered (≥5, DTS:X-only paths)

### S1 - Source-AU-keyed private silence grammar (PICKED)
Make the mid-stream 2x256 code-0x20 source-silence form available from the
**first source AU** (`frameIndex >= primingFrameCount`), so the 48-byte
compact zero form is emitted exclusively by the two true Core-priming AUs.
Reason: directly removes the priming-declaration leak that extends the
terminal's priming window over tbh's first audible frames; touches only
`DTSXPrivateStreamEncodingSession` (private layer), zero shared-path risk.

### S2 - Contiguous whole-window silent-start gate for 4x128 (PICKED)
Nominate the 4x128 startup grammar only when the start is silent across
the **entire two-AU window** on *both* halves: private height planes
(`startupWindowHeightsAreSilent` in the session) and public bed frames
(`startupWindowBedFramesAreSilent` in `DTSHDMAEncoder`). Any other start
is an ordinary hot start: public partition 2x256, silent-height frames
emit code-0x20. Reason: kills lone/misplaced startup declarations at
Atmos-object-driven onsets (the click mechanism above) while preserving
the Nature's Fury silent-start grammar byte-for-byte.

### S3 - Private silence-form timeline audit in the early-programme
### verifier (PICKED, negative control)
Extend `DTSXEarlyProgrammeGrammarVerifier` to classify every early private
frame's silence form (Core-priming compact / 4x128 startup / mid-stream
0x20 / active) and enforce the official timeline, including 4x128
contiguity from `primingFrameCount`. Reason: the defect class was
invisible to every existing gate; the baseline stream must *fail* a gate
before the fix and pass after it. It does (see results).

### S4 - Hot-start startup-transition byte-exact gates (PICKED,
### regression pin)
Add `verifyTerminalHotStartStartupTransition()` to
`DTSXNativeEncoderVerifier`: three scenarios (hot from sample zero, hot
from the second window AU, heights entering at the second window AU) with
SHA-256-pinned expectations for the priming/silence/active private frames
and all-2x256 public partitions. Reason: pins the fixed timeline so a
future refactor cannot silently re-introduce the leak.

### S5 - Differential HDMA-only vs DTS:X isolation (PICKED as the
### diagnostic method, no code change)
Encode the same 7.1(.4) content through the plain HDMA path and the DTS:X
path; the HDMA product is verified decoded-bit-exact (`verify-hdma`
`isBitExact = true`), so every terminal-visible delta is confined to the
private XLL-X layer, which `extract-xllx` timelines make directly
readable. Reason: this is what localizes the defect to the private layer
and is exactly Louis's "bed OK / DTS:X bad" observation, reproduced
offline.

### S6 - NAVI/Rice entropy conditioning at first active height AU
### (REJECTED)
Extracted timelines show active height frames already enter ordinary
2x256 coding immediately with bounded official Rice (unary quotient ≤ 22;
`verify-xllx-native-encoder` bounded-unary and parameter-search gates all
pass). Two previous onset-conditioning rounds were evidence-negative on
hardware. Touching entropy without a failing gate risks another flat or
regressive round.

### S7 - DTS:X ExSS/asset-descriptor repackaging (REJECTED)
The asset/ExSS descriptors are static per stream; a packaging defect would
fail the DTS:X presentation uniformly, not frame-indexed and
hot-start-keyed (NF plays, tbh's first frame fails, pops key to onsets).
The symptom shape demands a frame-indexed grammar defect, which S1/S2
found.

## Files changed

| File | Change |
| --- | --- |
| `Swift_DTSHDMAX/DTSXLL/DTSXPrivateFrameEncoder.swift` | S1: code-0x20 available from `primingFrameCount`; S2: `startupWindowHeightsAreSilent` whole-window gate for the 4x128 nomination |
| `Swift_DTSHDMAX/DTSHDMA/HDMAEncoder.swift` | S2: `startupWindowBedFramesAreSilent` public half; hot-start downgrades the nominated window to 2x256 instead of dropping the nomination per-frame |
| `Swift_DTSHDMAX/DTSValidation/DTSXEarlyProgrammeGrammarVerifier.swift` | S3: private silence-form classification + timeline audit (`privateSilenceFormsFollowOfficialTimeline`, violation counts/indices, 4x128 contiguity) folded into `isEarlyProgrammeSafe` |
| `Swift_DTSHDMAX/DTSValidation/DTSXNativeEncoderVerifier.swift` | S4: `terminalHotStartStartupTransitionPassed` gate, three scenarios, SHA-256-pinned private frames |

## Test results (no ffmpeg; `cloud-fixtures/test_X` + grammar notes)

All encodes/verifications ran with the rebuilt debug CLI on this branch.

**Negative control (pre-fix baseline, FULLSCALE_C hot start):**
`verify-dtsx-early-programme` fails - `isEarlyProgrammeSafe = false`,
`privateCorePrimingFormFrameIndices = [0, 1, 2, 3]` (the leak),
`privateSilenceFormViolationCount = 2`, first violation at frame 2.

**Fixed encoder, all 10 test_X vectors** (8 via `encode-dtsx-control`
patterns, `LFH_RFH`/`LFH_RFH_OPPOSED`/`ALL_MUTE` additionally via the
staged per-channel WAVs interleaved to 12-channel 7.1.4 WAVE and encoded
with `encode-dtsx-native-wave`): every vector passes
`verify-dtsx-early-programme` with
`privateSilenceFormsFollowOfficialTimeline = true`, zero violations, and
priming confined to `[0, 1]`. Partition/timeline highlights:

| Vector | Private AU0..AU5 bytes | 4x128 frames |
| --- | --- | --- |
| FULLSCALE_C (hot bed) | 48, 48, 52, 52, 52, 52 | none (fixed; was 48,48,48,48,…) |
| LFH_ONLY (heights hot) | 48, 48, 1700, 1700, 1700, 1700 | none |
| SILENCE / ALL_MUTE | 48, 48, 52, 56, 52, 52 | [2, 3] - NF silent-start grammar preserved |

**Suite gates (fixed binary):**

- `verify-dtsx-native-encoder`: `isVerified = true`, including the new
  `terminalHotStartStartupTransitionPassed = true`.
- `verify-xllx-native-encoder`: all 15 gates pass.
- `verify-hdma` (7.1 WAV round trip): `isBitExact = true` - the shared
  HDMA/Core path is untouched.
- `verify-dtsx-render-guard` 3/3, `verify-dtsx-render-startup` 9/9,
  `verify-core-syntax` passes on both the DTS:X and HDMA encodes.

## Materials status

- `cloud-fixtures/test_X/` and `cloud-fixtures/perfect-stream-grammar/`:
  present in git and used throughout.
- `cloud-fixtures/reference-streams/{tbh,Dolby_NaturesFury}.dtshd`:
  **PARENT_UPLOAD_REQUIRED** - still absent from the VM (Mac Downloads
  not mountable). Byte comparison against Louis's encodes remains
  impossible here and was **not** silent-passed; once uploaded, run
  `verify-dtsx-early-programme` on both to confirm the official streams
  satisfy the new private-timeline gate and the fixed encoder's timelines
  match theirs.
