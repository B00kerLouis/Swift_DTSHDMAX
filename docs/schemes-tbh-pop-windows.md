# TBH pop windows — timecode mapping, scheme selection, and windowed probe

Branch: `cursor/dtsx-tbh-pop-windows-3541` (off `origin/main` @ `08b4478` only).
Task: Louis's hardware flags playback pops inside two timecode windows of the
simpler **TBH** master. Find what **rendering** change inside those windows
causes pops (Atmos/IAB object automation → 7.1.4: gain smoother, pan/VBAP,
render guard, bed/height mapping, then the private XLL-X form/Rice/prediction
seams), map timecode → access units, and fix with a perfect-stream-aligned
scheme. No ffmpeg anywhere; project verifiers can be green while terminals
pop, so raw-declaration evidence outranks green gates.

## PARENT_UPLOAD_REQUIRED — every window binary is still missing (no silent pass)

`git fetch origin cursor/cloud-materials-3541` at run time carried **no**
`*.dtshd` and **no** `*.mxf` under `cloud-fixtures/reference-streams/` —
only briefs, grammar notes, and the `test_X` PCM sources. All three assets
Louis named remain required before any claim about what TBH actually
declares or renders inside the flagged windows:

```text
/Users/sunyun_louis/Downloads/tbh.dtshd                → cloud-fixtures/reference-streams/tbh.dtshd
/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd  → cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd
/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf        → cloud-fixtures/reference-streams/QWER_TBH_IAB.mxf
```

The MXF may land as a documented extract covering both windows with margin
(`00:00:20:00–00:00:25:00` and `00:02:50:00–00:02:57:00`); Mac-side push
commands are in `cloud-fixtures/reference-streams/UPLOAD_BLOCKED.md` on the
materials branch. `hdmax verify-reference-streams` on this branch now gates
all three files (the MXF is required for the render investigation) and exits
nonzero with `uploadStatus: PARENT_UPLOAD_REQUIRED` until they land. This
run therefore validates with the in-repo controlled vectors and the
recovered perfect-stream grammar only. **No reference binary was invented,
no check passed silently for lack of input, and no byte-exact
perfect-stream claim is made.**

## Timecode → access-unit mapping (documented contract)

The DTSHD `TIMECODE` chunk carries the authoring rate with a zero start
timecode, and the IAB master's programme is assumed to start at
`00:00:00:00` (a nonzero start offset shifts every row below by a constant;
`map-dtsx-timecode-windows` recomputes any variant in one command). Audio
access units are 512 samples at 48 kHz; the delivery stream prepends
**2 Core-priming access units** (`nuInitLLDecDlyFrames = 0`, the priming
pair is the trim), so `stream AU = content AU + 2`. One 24 fps video frame
is 2 000 samples = 3.906 25 AU: window edges do not land on AU boundaries,
so the mapped AU range is `floor(start) … ceil(end)` (end exclusive) and
the analyzer additionally surveys ±8 AU of margin around each window.

Exact mapping at 24 fps (`hdmax map-dtsx-timecode-windows 00:00:21:06-00:00:24:00
00:02:51:00-00:02:56:00 --frame-rate 24`, end timecodes exclusive):

| Window | Timecode | Video frames | 48 kHz samples | Content AU | **Stream AU** | Duration |
| --- | --- | --- | --- | --- | --- | --- |
| A | `00:00:21:06` – `00:00:24:00` | 510 – 576 | 1 020 000 – 1 152 000 | 1992 – 2250 | **1994 – 2252** | 2.75 s |
| B | `00:02:51:00` – `00:02:56:00` | 4104 – 4224 | 8 208 000 – 8 448 000 | 16031 – 16500 | **16033 – 16502** | 5.00 s |

If the MXF declares 23.976 instead (same nominal timecode clock, 2 002
samples per frame): window A = content AU 1994–2253 (stream 1996–2255),
window B = content AU 16047–16517 (stream 16049–16519). Both mappings have
exact integer sample boundaries. The analyzer reads the rate from the
stream's `TIMECODE` chunk and rejects a conflicting `--frame-rate`.

## Why pops cluster in these two windows (mechanism census on `main` @ `08b4478`)

The windows are where the master's object automation is dense: objects
entering the height layer, moving fast, and switching feeds. Walking the
render → encode pipeline, each automation property maps to a specific
seam machinery that fires *per access unit* exactly there and nowhere else:

| Master behaviour in window | Render-stage response | Coded-stream response | Seam risk |
| --- | --- | --- | --- |
| Object appears (silence → active) | `DTS714ObjectGainSmoother.retarget` ramps from current gain | private frame leaves a silence form for a navigated active frame; per-plane ABIT jumps 0 → ~19–20; NAVI width/trailing re-fit | **silence-form → active grammar seam** (the class `08b4478` fixed for bed-audible zero-height AUs) |
| Object crosses height feeds fast | per-sub-block retargets (250 samples at 24 fps) | active-plane mask flips per AU; each plane alternates ABIT 0 ↔ dense; 256 unary terminator bits per silent plane segment | off-corpus **silent-plane-inside-active-frame** coding form |
| Object gets loud mid-move | render guard may engage (fold/recovery composites) | rendered PCM reshaped before both XLL layers | guard attack/hold/release interplay under *periodic* window overloads |
| Object leaves (active → silence) | smoother slews to zero | navigated active frame returns to `mid-stream-no-navigation` silence | release seam (same class as onset) |
| Bed stays audible under silent heights | — | ordinary navigated frame with four zero planes (`forcesNavigation`) | landed in `08b4478`; must not regress |

None of these can be arbitrated further on this VM: our decoder round-trips
every candidate form bit-exactly, and only the TBH encode (what the
software under test actually declared in the windows) and the IAB master
(what the objects actually did there) can select between them. That is the
blocking dependency this branch converts into one-command questions.

## Schemes considered (7 distinct mechanisms; ≥5 required)

### Scheme 1 — Timecode-window mapping + windowed grammar census + window-mimicking controlled vector ← 择优

- **Mechanism.** Native tooling, zero delivery-byte changes to any existing
  encode:
  1. `map-dtsx-timecode-windows WINDOW... [PRIMING_AUS] --frame-rate VALUE` —
     the exact, auditable timecode → video-frame → sample → content-AU →
     stream-AU conversion above, as a machine-readable record (rational
     arithmetic, exactness flag, priming offset explicit).
  2. `analyze-dtsx-pop-windows INPUT.dtshd OUTPUT.json WINDOW... [MARGIN]
     [--frame-rate VALUE]` — slices the whole-programme grammar timeline to
     the mapped windows (±margin) and reports, per window: every
     terminal-visible declaration change between consecutive access units
     (silence-form transitions, active-plane-mask flips, public partition
     changes, private NAVI width changes, routing/branch/prediction-boundary
     changes, bed-audibility flips, parse failures) with an approximate
     timecode per event, plus height-onset density, ABIT extremes, and the
     largest consecutive-frame ABIT jump — the seam census at exactly the
     positions the hardware flags.
  3. `encode-dtsx-control pop-window-motion:STARTAU-ENDAU[:...]` — a
     deterministic 7.1.4 surrogate that mimics the windows' object-motion /
     height-onset density from controllable vectors: long true silence,
     then per-window a continuous stereo bed under a per-AU rotation of
     gated height bursts (Lfh→Rfh→Lrh→Rrh, in-AU raised-cosine edges, so
     the activity mask flips at every AU boundary without the vector itself
     stepping), a floor-surround rotation interleaved on odd AUs, and a
     bed-audible zero-height AU every eighth slot. Encoded at the true
     mapped AUs (`pop-window-motion:1992-2250:16031-16500`, 16 560 AUs,
     24 fps) it reproduces the full window seam structure of a TBH-length
     programme end-to-end on this VM.
  4. Cherry-picked from PR #23 (instrumentation-only commit `4046d22`,
     kept delivery-byte-safe): `export-dtsx-grammar-timeline`,
     `compare-dtsx-grammar-timelines`, `verify-reference-streams` — the
     latter extended here to also require `QWER_TBH_IAB.mxf`, since the
     render-path half of this investigation is blocked on the master.
- **Why it explains the windows.** The census quantifies precisely the
  seam classes tabulated above, at the mapped AUs. The moment `tbh.dtshd`
  lands, one command answers "what does the delivered grammar do at every
  AU of both windows"; the moment the MXF lands, the same windows can be
  rendered and the surrogate swapped for the real object automation. Until
  then the surrogate pins the *encoder's* window behaviour (all seams
  verified clean and corpus-shaped on this VM), which cleanly splits the
  fault space: if the hardware pops on content whose declared window
  grammar is corpus-identical, the defect is in a deferred corpus-keyed
  form (schemes 4–6), not in seam placement.
- **Risk.** None to playback: existing delivery encodes are byte-identical
  to `main` by construction and by measurement (SHA-256, below). The new
  vector only adds a new pattern name. Inspection-side risk (a wrong
  census) is bounded by reusing the verified parsers and by the
  self-consistency loop below.
- **Validation without ffmpeg.** (a) Byte-identity of all pre-existing
  controlled DTS:X + HDMA encodes against `main`. (b) Existing native gates
  stay green. (c) Self-consistency: the surrogate's constructed seams must
  be reported at exactly the constructed AUs by both the timeline export
  and the window census; mapping output must equal the hand-derived table
  above; a stream self-compare must be identical. (d)
  `verify-reference-streams` must stay honestly red on this VM.

### Scheme 2 — Re-land the NAVI 11/13/14 width ladder — REJECTED (hardware-failed history)

- **Mechanism.** PR #20 / PR #22 pinned two-segment private NAVI widths to
  an "official" `[11, 13, 14]` ladder, moving 2 049–4 096-byte segments to
  13-bit four-data-byte words.
- **Verdict.** Louis's hardware rendered **both** tip branches completely
  wrong — categorically worse than the residual pops. Recorded here as
  failed history per the brief: the ladder (or its four-data-byte
  serialization) does not exist on real terminals, and since steady dense
  content plays fine on `main`'s 12-bit words, NAVI width selection is not
  the window-pop mechanism either. **Must not be re-applied.**

### Scheme 3 — Renderer-side onset conditioning (gain ramps from silence, softer retarget slew, window-scoped smoothing) — REJECTED (hardware-worsened class)

- **Mechanism.** Reshape rendered PCM at the window seams:
  `beginFromSilence` object starts, longer slews for dense retargets, or a
  window-scoped onset softener at the encode boundary.
- **Verdict.** This exact class was hardware-tested twice and **increased**
  pops (`beginFromSilence` renderer variant; the delivery-boundary
  height-onset conditioner with its 72-AU head ramp), and the "rate-exact"
  slew variant steepened dense fast-move retargets measurably. Official
  renders deliver hot programme heads unfaded; the clean public bed folded
  from the same planes proves rendered PCM is not the breaking layer. The
  parent's directive explicitly prefers perfect-stream-aligned fixes over
  heuristic ramps already worsened on hardware. Rejected.

### Scheme 4 — Encode silent planes inside navigated active frames as linear width-0 instead of ABIT-0 Rice — DEFERRED (single-command corpus query once `tbh.dtshd` lands)

- **Mechanism.** Every window AU with a moving object has 1–3 *silent*
  height planes that `main` Rice-codes at ABIT 0 (256 unary terminator bits
  per segment); the recovered compact silence forms use the linear
  zero-width declaration instead. If official *active* frames declare
  silent planes linear-zero, our form is off-corpus on exactly the
  fast-switch AUs — a precise, window-clustered pop mechanism.
- **Risk.** High without evidence: same unverifiable-mutation class that
  produced the ladder failure; both forms round-trip bit-exactly locally.
- **Validation.** `analyze-dtsx-pop-windows tbh.dtshd out.json <windows>`
  reports the per-plane entropy modes of every window AU; the census
  answers this in one command. Blocked: PARENT_UPLOAD_REQUIRED.

### Scheme 5 — ABIT estimator variant (zigzag-mapped mean vs raw-magnitude mean) at onset boundaries — DEFERRED (needs corpus)

- **Mechanism.** `initialRiceParameter` keys on the raw mean magnitude; the
  writer zigzag-maps (~2×) before coding. An official mapped-mean estimator
  would shift dense-segment ABIT by ~1 — the largest relative effect on the
  window AUs where ABIT jumps 0 → ~19 (measured on the surrogate).
- **Risk.** Medium-high: perturbs every active frame programme-wide;
  locally undecidable (any consistent ABIT decodes bit-exactly).
- **Validation.** The window census emits per-segment ABIT beside segment
  byte counts; regressing corpus ABITs against decoded residual statistics
  selects the estimator. Blocked on the same binaries.

### Scheme 6 — Entropy-state reuse / common-parameter declarations on stable window runs — DEFERRED (needs corpus; currently contradicts a landed gate)

- **Mechanism.** `main` re-declares per-channel parameters every segment
  (`bUseSegStateCodeParm = 0`, `ncSegType = 0`). If the corpus reuses state
  on steady runs, perpetual re-declaration could read as per-segment
  reconfiguration — plausible for switch-adjacent AUs.
- **Risk.** High: the early-programme verifier classifies state reuse as
  research-only syntax (recovered from priming-frame failures); only corpus
  evidence can arbitrate. The census counts these declarations per window
  directly. Blocked.

### Scheme 7 — Render-guard window audit on the real master (guard engagement census inside the mapped windows) — DEFERRED (needs `QWER_TBH_IAB.mxf`)

- **Mechanism.** A hot object mid-crossing peaks the Q15 fold at ~1.207×
  and the recovery sum at ~1.414×; if TBH's window objects are hot, the
  anticipatory guard engages exactly there, and its hold/release plateau
  interacts with the window's periodic overloads. The existing
  `guardReport` already carries the engagement census
  (`overloadSampleCount`, `maximumGainStepQ30`, `minimumGainQ30`); mapped
  through this branch's TC→sample conversion it becomes a per-window
  render-stage audit, complementing the coded-stream census.
- **Risk.** None (measurement only), but meaningless without the master's
  actual object automation: the surrogate deliberately stays in headroom
  (verified transparent), and synthetic hot vectors would re-manufacture
  evidence. Blocked: PARENT_UPLOAD_REQUIRED (MXF).
- **Validation.** Render the window ranges of the MXF via
  `render(iab:guardReport:)` once uploaded; the guard report plus the
  window mapping localize any engagement to timecode.

### Scheme 8 — Fabricate a bridge/transition private frame at the window seams — REJECTED (invents grammar)

- **Mechanism.** Emit a state-establishing transitional form on the first
  active AU after a silence run (forced-minimal ABIT, re-declaration frame).
- **Verdict.** The recovered corpus shows ordinary navigated active frames
  directly after silence forms; no bridge form exists to copy. Inventing
  grammar is the defect class already burned twice. Rejected.

## 择优 rationale

Scheme 1 is chosen because:

1. **It is the only scheme decidable on this VM today.** Schemes 4–6 mutate
   delivery grammar in ways local round-trips cannot arbitrate — the exact
   epistemic trap that produced two hardware-rejected branches — and
   scheme 7 needs the master. The brief's own fallback ("strongest safe
   probe you can justify from controllable vectors that mimic
   object-motion / height-onset density in those windows") names scheme
   1's deliverable.
2. **It cannot regress the OK HDMA + Core encodes**: no delivery byte
   changes; byte-identity against `main` is part of its validation.
3. **It makes the window questions one-command answerable** the moment
   Louis's uploads land: scheme 4/5/6 each reduce to reading the window
   census of `tbh.dtshd`; scheme 7 reduces to a guard report over the
   MXF's mapped sample ranges. The TC→AU contract is now executable code
   with an exactness flag rather than a hand calculation.
4. **The surrogate pins the encoder's window behaviour now.** A TBH-length
   encode with the true mapped seam density verifies clean end-to-end
   (closed-loop verified, corpus-shaped forms, pinned 2×256 partition,
   bounded unary, stable routing, zero parse failures), so if hardware
   still pops on corpus-identical window grammar, the remaining fault
   space is exactly schemes 4–6 — a decision the uploads settle.
5. The rejected schemes (2, 3, 8) are recorded with their hardware
   verdicts so no future agent re-lands them.

## Verification record (this branch, Swift 6.0.3, Linux Debug CLI)

Toolchain: `swiftc -O -D DEBUG` over all repository sources on Ubuntu
24.04 (Swift 6.0.3-RELEASE), with the untracked one-line Linux `main.swift`
shim calling `DTSHDMACommandLine.run` (the tracked `main.swift` /
`HDMAXFramework.swift` are the macOS `@objc` bridge). `main` @ `08b4478`
was built from a clean worktree with the identical toolchain and flags.

### Byte-identity against `main` @ `08b4478` (no-regression proof)

Every pre-existing delivery encode compared SHA-256-identical:

```text
encode-dtsx-control silence       96 AU  96b5a1a858f2de9a...  IDENTICAL
encode-dtsx-control channel-walk  96 AU  06b53fc853806ad2...  IDENTICAL
encode-dtsx-control all-sine      96 AU  986d53209bb1dd4e...  IDENTICAL
encode-dtsx-control impulse:Lfh   96 AU  cb35af91b0956bcc...  IDENTICAL
encode-hdma 5.1 (generated, 96)           666a9b6152601e08...  IDENTICAL
```

(The same five hashes as PR #23's record — three independent builds now
agree.) HDMA + Core delivery is untouched by construction and measurement.

### Existing native gates — all PASS

```text
verify-xllx-native-encoder                          PASS (12/12 isBitExact)
verify-dtsx-native-encoder                          PASS (isVerified true)
verify-core-syntax   (channel-walk encode)          PASS (98/98 synchronized)
verify-hdma          (generated 5.1, 96 frames)     PASS (isBitExact true)
verify-dtsx-early-programme (channel-walk encode)   PASS (isEarlyProgrammeSafe)
verify-dtsx-render-guard                            PASS (isVerified true)
verify-dtsx-render-startup                          PASS (isVerified true)
```

### Mapping + windowed census self-consistency — all PASS

1. **Mapping equals the hand-derived contract.**
   `map-dtsx-timecode-windows` reproduces the table above exactly at 24
   and 23.976 fps, `sampleBoundariesAreExact: true` for both windows,
   priming offset 2 explicit in every row.
2. **Constructed seams are reported at constructed AUs.**
   `pop-window-motion:24-34:60-76` (96 AU, 24 fps) encodes with integrated
   closed-loop verification green; the grammar timeline reports height
   onsets at stream AUs 26–32, 34–35 and 62–68, 70–76 (every window AU
   except the constructed bed-only slots), `navigated-silence: 3` for
   exactly the three bed-audible zero-height AUs (33, 69, 77), activity
   transitions closing each window, `mid-stream-no-navigation` everywhere
   outside, the 4×128 partition only on the silent-start pair, and zero
   parse failures.
3. **The window census agrees with the timeline on the same stream** and
   names the seam declarations per event (silence-form flip, mask
   rotation, NAVI-width appearance, prediction-boundary change,
   bed-audibility flip), each with in-window/margin attribution and
   approximate timecode. Onset density and ABIT-jump metrics match
   construction (single-plane bursts at ABIT ≤ 19, maximum
   consecutive-frame ABIT jump 19 at the silence→active seams).
4. **Full-scale surrogate at the true mapped AUs.**
   `pop-window-motion:1992-2250:16031-16500` (16 560 content AUs ≈ 2 min
   56.6 s at 24 fps) encodes verified in 74 s;
   `analyze-dtsx-pop-windows` over the real windows reports: window A
   = 258 AUs, 226 active + 32 bed-audible zero-height, 82.2 onsets/s;
   window B = 469 AUs, 411 active + 58 bed-audible zero-height, 82.2
   onsets/s; all 637 programme onsets inside the two windows; partition
   pinned 2×256 throughout both windows; private NAVI width 11 constant;
   public unary quotient ≤ 20, private ≤ 22 bound respected; zero parse
   failures; both windows `windowIsWithinStream: true`.
5. **Self-comparison is exactly zero.** `compare-dtsx-grammar-timelines`
   of the surrogate against itself: `grammarIsIdentical: true`.

### Reference-stream gate — honest RED (expected, the escalation artifact)

```text
$ hdmax verify-reference-streams
error: PARENT_UPLOAD_REQUIRED: reference encodes are missing from
cloud-fixtures/reference-streams (tbh.dtshd, Dolby_NaturesFury.dtshd,
QWER_TBH_IAB.mxf); ...   uploadStatus: PARENT_UPLOAD_REQUIRED   exit 1
```

The gate now also requires `QWER_TBH_IAB.mxf` (or a documented
window-covering extract) because the render half of this investigation is
blocked on the master. No byte-exact perfect-stream verification is
claimed anywhere in this record. ffmpeg was not used.

## One-command playbook once the uploads land

```bash
# What does TBH declare inside the pop windows? (schemes 4/5/6 arbitration)
hdmax analyze-dtsx-pop-windows cloud-fixtures/reference-streams/tbh.dtshd \
  tbh-windows.json 00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00

# Field-level diff against the perfect NF stream / any candidate re-encode
hdmax compare-dtsx-grammar-timelines REFERENCE.dtshd CANDIDATE.dtshd

# Presence + SHA-256 gate (auto-recognizes the canonical perfect NF hash)
hdmax verify-reference-streams
```
