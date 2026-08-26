# Bed-active / height-silent gaps: private silence-form schemes and selection

Branch: `cursor/dtsx-bed-active-silence-gaps-3541`
(base `origin/cursor/dtsx-xllx-only-defect-3541`, materials from
`origin/cursor/cloud-materials-3541`). Model: `claude-fable-5-thinking-xhigh`.

Hardware status this document responds to (Louis, 2026-08-26, after the
`dtsx-xllx-only-defect-3541` tip — partial win):

1. Nature's Fury: plays (可播).
2. tbh: **仅 bed 发声的位置不可播** — the first ~10 seconds **and the
   programme tail** (片尾), not only the first frame. Height-active
   regions improved.
3. 爆音更少 than the previous tip; residual Atmos-master-object pops in
   the first few frames / fast channel switches.
4. The 7.1 HDMA/XLL compatibility bed still plays; DTS:X-only defect.
5. Prior S1 confined the compact zero form to the priming AUs — hardware
   moved, incomplete. Extend to mid-stream and end-of-programme private
   silence when the bed is active and the heights are silent.
6. No ffmpeg. Atmos master Objects ≠ DTS:X objects. HDMA/Core OK.

## Root cause: private silence *declarations* under an audible bed

The private XLL-X layer has exactly three recovered compact/no-NAVI zero
forms, and the corpus exercises every one of them only on access units
that are silent **as a whole** — silent heights over a silent bed:

| Form | Size | Officially observed context |
| --- | --- | --- |
| Compact zero (code 15, no NAVI) | 48 B | the two Core-priming AUs |
| 4x128 startup pair (navigated + code-0x80 no-NAVI) | 52/56 B | the two window AUs of a *fully silent* start (NF) |
| 2x256 code-0x20 no-NAVI | 52 B | fully silent source AUs (NF mid-programme silence, ALL_MUTE_X) |

They are **access-unit silence declarations**, not a cheap coding of four
zero planes. There is no recovered official instance of any of them under
an audible bed.

The previous tip keyed these forms on the **height planes alone**. Every
bed-active + height-silent access unit therefore carried a 52-byte
code-0x20 silence declaration while the bed was audible. A terminal that
honors the declaration treats the DTS:X presentation as idle/not
renderable for that access unit; the public 7.1 bed (the same downmix)
decodes on the independent compatibility path and keeps playing. That is
precisely the observed failure geometry:

- tbh's head: bed hot from sample zero, heights enter around ~10 s → the
  entire bed-only head is a run of misplaced silence declarations →
  DTS:X unplayable for exactly the first ~10 s.
- tbh's tail: heights fall silent before the bed does → the bed-only tail
  is another run of the same misplaced declarations → 片尾 unplayable.
- Height-active regions: ordinary navigated frames → play (the improvement
  hardware confirmed after the previous tip).
- Nature's Fury: every silence form sits on genuinely silent access units;
  audible content carries active heights → plays.
- The earlier "first frames unplayable until AU3" was the same defect one
  layer earlier (priming declarations over audible AUs); the previous
  tip's fix moved hardware in the right direction because it shortened the
  misdeclared region, but replaced one silence declaration with another.

The fix: key the frame class on **whole-access-unit audibility** (all
twelve 7.1.4 source planes; the delivered bed is a linear fold of the same
planes). A bed-audible height-silent access unit now encodes through the
ordinary navigated delivery path — branch-zero routing, fixed-order-zero
prediction, official mean-magnitude Rice over all-zero residuals, explicit
NAVI — producing a deterministic 316-byte frame that decodes to exact zero
heights. This is the same per-plane zero grammar the official corpus
already exercises inside active frames whose remaining planes are silent
(LFH_ONLY-class vectors), extended to all four planes; it is a normal
decodable frame, so the terminal's DTS:X presentation stays engaged and
renders zero heights over the playing bed. Fully silent access units keep
their byte-exact silence forms everywhere on the timeline — head,
mid-stream, and trailing.

## Schemes considered (≥6, DTS:X-only paths) and 择优

### S1 — Whole-access-unit-keyed private frame class (PICKED, root fix)
Compact/no-NAVI silence forms are legal only when the entire access unit
is silent across all twelve source planes; bed-audible height-silent AUs
carry the ordinary navigated zero-height delivery frame, from the first
source AU through the zero-padded final AU. Reason: single rule explains
head + tail + NF + height-active evidence simultaneously; touches only the
private session/frame encoder; the silence timeline for genuinely silent
content is byte-preserved (NF silent-start grammar untouched).

### S2 — Mid-stream and end-of-programme timeline audit (PICKED)
`DTSXEarlyProgrammeGrammarVerifier` now reconstructs the lossless bed
(Core + XLL residual, sample-exact = source) to classify access-unit
audibility, requires the navigated zero-height class on bed-audible
height-silent AUs and silence forms only on fully silent AUs, and audits
an **equally sized end-of-programme window** in addition to the head
window. Reason: the defect class lived beyond every existing gate's
window; the tail-only control below is invisible to a head-only audit.

### S3 — Session classification pinned against startup re-entry (PICKED)
The 4x128 silent-start nomination now keys on whole-window full-source
silence inside the session (the HDMA rendered-bed gate stays as an
independent second guard), and the new
`verifyTerminalBedOnlyProgrammeTimeline` gate pins byte-exactly that
mid-stream height dropouts and tails never re-enter startup or priming
grammar: hot-start scenarios, dropout → re-silence, fully silent tail
after a hot start (mid-stream 0x20, never the startup pair), and the
padded final access unit.

### S4 — End-of-programme trailing-AU coverage (PICKED, folded into S1+S3)
The trailing zero-padded access unit inherits the same audibility key: a
partial final AU with bed content is audible → navigated zero-height
frame; trailing all-silent AUs → mid-stream 0x20. Pinned by the
`paddedTail` and `silentTail` scenarios. Reason: 片尾 includes the
encoder-generated padding, which the previous timeline never audited.

### S5 — Periodic navigated "refresh" inside long 0x20 runs (REJECTED)
A refresh cadence assumes the terminal plays the first seconds of a 0x20
run and drops out after a timeout. Hardware says the head fails **from the
start** of the bed-only region, so the defect is the form itself, not run
length; and no corpus evidence supports any refresh interval. Inventing
one risks another unplayable grammar.

### S6 — Dedicated terminal/closing silence form via control code 0x10
### (REJECTED for now)
The recovered no-NAVI profile admits control code 0x10 (6-byte side-info,
4x128 variant), but its officially exercised position is unrecovered on
this VM. Declaring it a tail form would be invention; deferred until the
reference streams are uploaded (see materials status).

### S7 — Render-path Atmos-object onset work (REJECTED this round)
Two previous render rounds were hardware-flat or regressive, and the
residual first-frame/channel-switch pops were observed while the private
timeline still declared silence under audible content — several reported
pop sites sit inside regions this fix changes. Re-evaluate on hardware
after this tip; do not touch the renderer without fresh evidence.

### S8 — Differential bed-only vs height-active encode isolation (PICKED
### as method, no code change)
Baseline-vs-fixed encodes of controllable vectors across the full
programme length, `extract-xllx` timelines, and byte comparison localize
every change to the private layer and prove the silent-content timeline is
untouched (below).

## Files changed

| File | Change |
| --- | --- |
| `Swift_DTSHDMAX/DTSXLL/DTSXPrivateFrameEncoder.swift` | S1: per-AU whole-source silence flags in the session; silence forms gated on them; new forced-navigation encode path for bed-audible zero-height AUs; 4x128 nomination keys on whole-window full-source silence |
| `Swift_DTSHDMAX/DTSHDMA/HDMAEncoder.swift` | S3: rendered-bed startup gate retained as independent second guard (comment updated to the new grammar) |
| `Swift_DTSHDMAX/DTSValidation/DTSXEarlyProgrammeGrammarVerifier.swift` | S2: lazy lossless bed reconstruction, audibility-keyed frame-class rules, end-of-programme window, new report fields (`trailingWindowStartAccessUnitIndex`, `trailingMeasuredAccessUnitCount`, `bedAudibleAccessUnitCount`, `privateBedAudibleZeroHeightFrameCount`) |
| `Swift_DTSHDMAX/DTSValidation/DTSXNativeEncoderVerifier.swift` | S3/S4: hot-start expectations moved to the new timeline (SHA-pinned 316-byte navigated zero frame, decoded-zero-heights checks), new `terminalBedOnlyProgrammeTimelinePassed` gate (dropout, silent tail, padded tail) wired into `isVerified` |

## Test results (no ffmpeg; `cloud-fixtures/test_X` + grammar notes)

Debug CLI built from this branch (Swift 6.1.2, Linux x86_64); baseline
binary built from the base tip for differentials.

**tbh-shaped differential (bed hot AU0–7, heights active source frames
3–4 only), private frame byte timeline (priming, head, active, tail):**

| Binary | AU byte counts |
| --- | --- |
| baseline (hardware-failing) | 48, 48, **52, 52, 52**, 3168, 3164, **52, 52, 52** |
| fixed | 48, 48, **316, 316, 316**, 3168, 3164, **316, 316, 316** |

Head and tail bed-only AUs leave the silence declaration for the
deterministic navigated zero-height frame
(SHA-256 `7c312a85…`, pinned); height-active frames are byte-identical.
The baseline stream fails the new gate; the fixed stream passes.

**Negative controls (new verifier on baseline encodes):**
- FULLSCALE_C: `isEarlyProgrammeSafe = false`,
  `privateSilenceFormViolationCount = 4` (all four bed-audible AUs),
  first violation at frame 2.
- Tail-only control (silent source frames 0–959, bed hot 960–1099): the
  head window is completely clean — a head-only audit passes it — and the
  tail window fails it with 140 violations, first at frame 962. The fixed
  encoder emits 140 navigated zero-height frames there and passes.

**Byte-exactness (silent-content timeline untouched):** baseline vs fixed
encodes of ALL_MUTE, SILENCE (both with the 4x128 startup pair at [2, 3]),
and LFH_ONLY are **byte-identical**. Only bed-audible height-silent
content changes.

**All 11 test_X vectors** (encoded from `pcm-sources/` directories with
`encode-dtsx-native-source`): every vector passes
`verify-dtsx-early-programme` with zero violations, priming confined to
[0, 1], and the expected classification — e.g. FULLSCALE_C
`bedAudible = 4, navigatedZero = 4`; IMPULSE_L `1/1`; LFH_ONLY
`bedAudible = 4, navigatedZero = 0` (active heights); ALL_MUTE/SILENCE
`bedAudible = 0` with startup pair preserved.

**Suite gates (fixed binary):**
- `verify-dtsx-native-encoder`: `isVerified = true`, including the updated
  `terminalHotStartStartupTransitionPassed` and the new
  `terminalBedOnlyProgrammeTimelinePassed`.
- `verify-xllx-native-encoder`: all gates pass.
- `verify-hdma` (7.1 WAV round trip): `isBitExact = true` — the shared
  HDMA/Core path is untouched.
- `verify-dtsx-render-guard`, `verify-dtsx-render-startup`,
  `verify-dtsx-recovery-window`: pass.
- `verify-dtsx-714-native` / `verify-dtsx-private-heights-native` /
  `verify-dtsx-compatibility-bed-native` on the tbh-shaped encode: all
  bit-exact.
- `verify-core-syntax`: passes on both the DTS:X and plain HDMA encodes.

## Materials status

- `cloud-fixtures/test_X/` and `cloud-fixtures/perfect-stream-grammar/`:
  present in git and used throughout.
- `cloud-fixtures/reference-streams/{tbh,Dolby_NaturesFury}.dtshd`:
  **PARENT_UPLOAD_REQUIRED** — still absent from this VM (Mac Downloads
  not mountable; only `README/UPLOAD_BLOCKED/WHERE_TO_PUT_ENCODES`
  placeholders exist). Not silent-passed. Once uploaded:
  1. run `verify-dtsx-early-programme` on both official streams — the new
     audibility-keyed gate is the first that can *positively confirm*
     which private frame class official encoders emit on bed-audible
     height-silent access units, and on the trailing window;
  2. if the official class there is a navigated zero-height frame,
     compare its NAVI/entropy declarations against the pinned 316-byte
     form; if it is something else (e.g. the code-0x10 variant), S6
     re-opens with real evidence instead of invention.
