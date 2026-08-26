# Atmos-object onset pops: render-path schemes and selection

Status snapshot this document responds to (Louis, 2026-08-26, after the
O1/O2 height-onset-conditioner tip `dtsx-object-onset-pop-3541`):

1. Nature's Fury: plays.
2. tbh: still fails; the first ~10 seconds do not play normally (NOT fixed).
3. **Pops got worse** ("爆音量相对上一版更多") - the O1/O2 delivery-boundary
   height ramps are evidence-negative and must be reconsidered.
4. Correlation refined: the pops track **Atmos master objects** (DAMF/IAB/ADM
   object essence plus automation) during playback and fast moves; the closer
   to an Atmos-object essence onset ("发声 onset") or the programme head, the
   higher the pop rate. Playback stabilizes later.
5. Scope clarification (禁止混淆): "Object" here means Atmos **master**
   objects. The DTS:X delivery carries no XLL-X object metadata - the
   renderer flattens everything to 7.1.4 planes. Fixes belong in the
   Atmos → 7.1.4 path (`DTS714Renderer`, `DTS714VBAPPanner`,
   `DTS714ObjectGainSmoother`, bed/object mix) and/or in how that PCM enters
   the encode - never in invented XLL-X "objects".
6. No ffmpeg anywhere. HDMA and Core encodes are certified OK on hardware and
   must not regress.
7. The official binaries (`tbh.dtshd`, `Dolby_NaturesFury.dtshd`,
   `TBH_offical.dtshd`) are **still not uploaded** -
   **PARENT_UPLOAD_REQUIRED** (see `cloud-fixtures/PARENT_UPLOAD_REQUEST.md`).
   The requested early ~10 s bitstream inspection of the new software encodes
   is impossible on this VM; everything below is validated with controllable
   vectors and Atmos render-path analysis only.

## Root cause: the Atmos-object onset pattern in our render path

Code audit of the Atmos → 7.1.4 path (with the O1/O2 experience folded in as
hardware evidence) localizes three distinct onset-shape defects and one
evidence-negative mitigation:

1. **Programme-start gains are installed as a step (`setImmediately`).**
   `DTS714Renderer` applied every initial declaration (`samplePosition <= 0`)
   and then called `DTS714ObjectGainSmoother.setImmediately`, deliberately
   skipping the smoother ("avoids an artificial program-start fade"). Every
   *later* automation update is bounded by the recovered reference slew
   (1/480 full scale per sample); sample zero was the single place the
   renderer exempted itself from its own continuity contract. A hot-start
   title (tbh: objects active with hot essence at sample zero) therefore
   slams the full object mix - floor **and** height planes - into the first
   source access unit, exactly the window where the terminal is still inside
   first-frame recovery (`clip23(Core x sqrt(2))`), where the Core codec
   error is maximal, and where every XLL/XLL-X navigation and entropy
   structure changes state for the first time. Nature's Fury starts silent,
   so it never exercises this defect - matching the playable/unplayable
   split exactly.
2. **The slew limiter under-runs and over-runs the reference rate.** When a
   retarget's rate exceeded the 1/480-per-sample bound, the smoother forced
   the transition period to a *fixed* 480 samples regardless of the delta:
   sub-full-scale limited moves slewed *slower* than the reference renderer
   (trajectory smear and target lag under dense fast-move automation, i.e.
   retargets every pan sub-block), while a delta above unity gain (positive
   object gain trim) stepped *faster* than the documented bound - a real
   discontinuity carrier on fast trajectories. The reference semantics are
   rate-based, not duration-based: a limited move takes
   `ceil(|delta| * 480 / 2^30)` samples.
3. **O1/O2 (delivery-boundary height ramps) are the wrong stage and the
   wrong scope, and hardware confirmed it.** The conditioner reshaped the
   *mixed* height planes at the encode boundary: (a) it could not touch the
   floor contributions of the same hot objects, so the Core recovery burst -
   the one channel the reference decoder provably plays at the head - was
   delivered unchanged; (b) the 0.768 s head ramp manufactured 72
   consecutive access units of artificially quiet, per-sample-rescaled
   height content, forcing the private XLL-X entropy coder through its
   smallest-parameter regimes and through continuous parameter churn across
   the entire convergence window - the exact "quiet content / small widths"
   regime that hardware previously presented as noise-gate dropouts and an
   unreadable first active frame; (c) plane-level onset detection cannot see
   an object onset that overlaps other active content on the same plane.
   Louis's report - **more** pops with O1/O2 - is consistent with (b)
   dominating. The mitigation is evidence-negative and is removed.
4. **What stays healthy:** `DTS714VBAPPanner` target gains are continuous in
   position (equal-power floor rows, bilinear height patch, smooth
   floor/height blend, normalization never near zero); discontinuous target
   sources (snap flips, elevation toggles) are bounded by the smoother; the
   composite-headroom guard (`DTS714RenderGuard`) bounds plane/fold/recovery
   overloads with a slew-bounded envelope on fast hot trajectories. No
   defect found in the pan math itself.

## Candidate schemes (A-series)

### A1 - Revert the O1/O2 delivery-boundary height-onset conditioner

Remove `DTS714HeightOnsetConditioner` (programme-head ramp + plane-level
silence-to-active onset slew) from the delivery source pipeline; keep the
composite-headroom `DTS714RenderGuard` stage, which is bit-exact passthrough
unless a downstream contract would overload.

- Evidence for: direct hardware A/B - pops increased with the conditioner;
  mechanism (root cause 3) explains why; the certified paths never needed
  it.
- Evidence against: none; the conditioner's own transparency class (silent
  heights) is unaffected by removal by construction.
- Risk: none to NF/HDMA/Core - delivery and bypass streams become
  byte-identical again for every in-headroom source (regression-gated).
- **Selected: implemented.**

### A2 - Reference-slew programme start in the renderer

Replace the sample-zero `setImmediately` with the smoother's own bounded
approach: every object's gain state starts at digital silence and slews to
its initial declared gains at exactly the reference maximum rate (1/480 full
scale per sample), i.e. a full-gain object reaches target within 480 samples
(10 ms), entirely inside the first source access unit.

- Mechanism: extends the renderer's existing continuity contract to the one
  boundary that violated it. Bounds the hot-start first-AU energy in *all
  twelve* planes - including the floor contributions that dominate the Core
  first-frame-recovery burst, which height-only O1/O2 could never reach -
  and does so at the stage that knows the object structure.
- Evidence for: the failing title is hot-start, the playable title is
  silent-start; the smoother's slew constant was recovered from reference
  renders; a 10 ms bounded rise spans one access unit, so it cannot create
  the multi-AU quiet-content regime that made O1 harmful.
- Evidence against: whether the official renderer starts its gain state at
  silence cannot be byte-confirmed until the official binaries arrive.
- Risk: silent-start programmes (NF class) are bit-exact by construction
  (ramped gains multiply silent essence); beds are never touched; editorial
  cost is 10 ms of object ease-in at the programme head, currently unplayable.
- **Selected: implemented.**

### A3 - Atmos-object fade-in on essence appearance (mid-programme)

Per-object detection of essence silence-to-active transitions with a
reference-slew fade of that object's contribution only.

- Evidence for: matches the "发声 onset" correlate at all programme times;
  object-scoped, so overlapping content and beds stay untouched.
- Evidence against: **hot essence onsets with static gains are steps in
  official renders too** - the official reference renderer multiplies
  essence by (static) gains exactly as we do, official discs contain such
  onsets, and official terminals play them. O2 - the plane-level cousin of
  this scheme - measurably *increased* pops on hardware. Reshaping programme
  material at onsets is therefore evidence-negative as a class; the enabler
  is terminal convergence state (first ~10 s), not the mere existence of the
  step.
- Risk: repeats the O2 mistake at a different stage; editorializes every
  hard cut in the programme.
- **Rejected** on the O2 hardware evidence; revisit only if the official
  binaries show the Encoder Suite conditioning essence onsets.

### A4 - Exact reference-rate slew for fast Atmos trajectories

Fix the smoother's slew-limited period from a fixed 480 samples to the
rate-exact `ceil(|delta| * 480 / 2^30)` samples per channel, so every
limited transition moves at exactly the reference bound - never slower
(sub-full-scale moves under dense automation no longer lag their targets)
and never faster (above-unity gain deltas can no longer exceed the
per-sample bound).

- Evidence for: root cause 2; the recovered constant is a *rate*; the fix
  strictly tightens conformance to it on both sides.
- Evidence against: pure fidelity/bound correction; by itself it does not
  explain the head-window failure (covered by A2).
- Risk: transitions only ever get closer to the reference bound; the
  per-sample step stays `<= ceil(2^30 / 480)`; regression-gated.
- **Selected: implemented** (also carries A2: the programme start is a
  maximum-rate retarget from silence).

### A5 - Encode-boundary conditioning limited to proven contracts

Policy consequence of A1 + A2: the encode boundary conditions sources only
against *proven downstream contracts* (plane range, legacy Q15 fold,
Core-residual recovery composite - `DTS714RenderGuard`), never against
heuristically detected onsets. All onset shaping lives in the renderer where
the Atmos object structure is known. Delivery and bypass encodes of any
in-headroom source are byte-identical, restoring an auditable invariant that
O1/O2 destroyed (their delivery streams differed from bypass on every
hot-start source, making every closed-loop comparison depend on replicating
conditioner behavior).

- **Selected: implemented** (falls out of A1; regression-gated by the new
  render-startup verifier).

### A6 - Official startup grammar for hot Atmos-rendered starts

If the official encodes prove that the Encoder Suite emits different early
syntax for hot starts (longer priming, different first-AU segmentation,
onset-aligned entropy declarations, a delayed first source AU), replicate
that grammar.

- Evidence for: would explain the full ~10 s convergence window that a 10 ms
  render fix cannot cover by itself.
- Evidence against: requires the official binaries; hardware has already
  rejected two "syntactically legal but corpus-alien" grammar families, so
  shipping unverified startup grammar is the same gamble that produced
  earlier failures.
- **Deferred: blocked on PARENT_UPLOAD_REQUIRED.** `XLLRecoveryStartupVerifier`'s
  handoff-residual diagnostics (O3) are kept report-only and run unchanged
  against the official binaries the moment they arrive.

## Selection (择优)

**Implemented: A1 + A2 + A4 (+ A5 as the policy consequence). Rejected: A3.
Deferred: A6 (blocked on upload).** Reasons, in evidence order:

1. A1 is the only action with a direct hardware A/B behind it: Louis reports
   strictly more pops with the O1/O2 conditioner than without it. Keeping an
   evidence-negative mitigation in the delivery path is indefensible.
2. A2 targets the exact discriminator between the playable and unplayable
   titles (hot vs silent programme start) at the stage Louis directed the
   fix to (the Atmos render), through machinery that already exists and is
   already trusted for every mid-programme update - and unlike O1/O2 it also
   bounds the floor-plane object energy that feeds the Core recovery burst.
   Its silent-start transparency is provable on this VM.
3. A4 removes the only place the render path could exceed the reference
   slew bound (fast trajectories with gain trim above unity) and the only
   place it systematically under-ran it (limited moves under dense
   automation), with a strictly-tighter-bound argument and a regression gate.
4. A3 belongs to the same class as O2, which hardware just rejected;
   implementing it would repeat the previous tip's mistake with a smaller
   blast radius. A6 without binaries is a corpus-alien grammar gamble that
   hardware has punished twice.

The pre-O1/O2 five-scheme work (boundary RenderGuard, grammar invariants,
Rice <= 22, active-start 4x128 refusal, Core-fold guard) is retained
unchanged underneath; this series replaces only the evidence-negative onset
conditioning with render-native continuity.

## Implementation on this branch

1. `DTS714HeightOnsetConditioner` deleted (A1). `DTS714DeliverySourceConditioner`
   (shared by the encoder and every closed-loop verifier) now runs only the
   composite-headroom `DTS714RenderGuard`; the
   `sourceOnsetConditioning` report field is gone.
2. `DTS714ObjectGainSmoother.retarget` computes rate-exact slew-limited
   periods (A4); `DTS714Renderer` starts every object's gain state at
   silence and approaches the initial declarations at the maximum reference
   rate (A2), keeping beds untouched.
3. `DTS714HeightOnsetGuardVerifier` and `verify-dtsx-onset-guard` replaced by
   `DTS714RenderStartupVerifier` / `verify-dtsx-render-startup`: hot-start
   render obeys the reference-slew envelope and converges bit-exactly to the
   static-gain mix; silent-start render is bit-exact untouched; mid-programme
   essence onsets after startup are delivered unfaded (the A3 negative
   control); delivery and bypass encodes of the rendered hot start are
   byte-identical (A1/A5); the encoded stream stays closed-loop bit-exact
   and early-programme grammar safe.
4. `DTS714ObjectGainSmoothingVerifier` extended for the rate-exact periods,
   the maximum-rate start path, and the above-unity-delta bound.
5. `XLLRecoveryStartupVerifier` handoff diagnostics (O3) unchanged,
   report-only, awaiting the official binaries for calibration. Its
   aggregate-ratio gate additionally accepts peak divergence at the codec
   noise floor (<= 64 LSBs, -102 dBFS): the ratio exists to catch a Core
   that does not carry the declared fold (content-proportional divergence)
   and is meaningless when both sides are a few LSBs of codec noise. The
   removed O1 head ramp had been "passing" this gate on height vectors only
   by zeroing their content outright - a live demonstration of the
   PROJECT_MEMORY warning that green verifiers can hide deleted content.

## Verification on this VM (no ffmpeg anywhere)

- `verify-dtsx-render-startup` (new): green. Hot-start object first sample
  12,476 versus 5,988,281 unbounded (the removed step), rise completes in
  479 samples, zero envelope violations, converged bit-exactly to the
  static mix, bed bit-exact, silent head window bit-silent, mid-programme
  essence onset delivered unfaded, delivery == bypass bytes, closed-loop
  bit-exact, early-programme grammar safe.
- `verify-dtsx-render-guard`, `verify-xllx-native-encoder`,
  `verify-dtsx-native-encoder` (includes the extended gain-smoothing
  regression: rate-exact slew periods, maximum-rate start, above-unity
  delta bound): green.
- All 11 controllable `test_X` vectors encode and pass
  `verify-dtsx-early-programme`, `verify-dtsx-private-heights-native`, and
  `verify-dtsx-714-native` (closed-loop bit-exact, grammar safe).
- `verify-dtsx-recovery-window` on the 11 vectors: silent and height-onset
  classes pass. Pre-existing failures, byte-identical to the base tip and
  untouched by this change: `FULLSCALE_C` (16 recovery-clip samples -
  deferred Core-margin scheme O5), `IMPULSE_L`, `FRAME_EDGE_Lsr`,
  `CHANNEL_WALK_COMPACT` (aggregate-ratio false positives on sparse
  synthetic transients where Core codec error dominates). `IMPULSE_LFH`
  "passed" at the base tip only because the O1 head ramp deleted the
  impulse; with real content restored it joins the same pre-existing
  transient-ratio class.
- Official-binary regression: **PARENT_UPLOAD_REQUIRED** (unchanged).
