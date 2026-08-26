# DTS:X object-onset pops near programme head: schemes and selection

Status snapshot this document responds to (Louis, 2026-08-26, after the
five-scheme tip - boundary RenderGuard + grammar invariants + Rice <= 22 +
active-start 4x128 refusal + Core-fold):

- Nature's Fury: plays.
- tbh: still fails; the first ~10 seconds do not play normally (NOT fixed).
- Pop loudness roughly unchanged versus the previous tip
  ("爆音量相对上一版差别不大") - the boundary guard alone is insufficient.
- Pattern: master **Object** data - the closer to an object onset / the
  programme head, the higher the pop probability; playback stabilizes later.
- No ffmpeg; verifiers are not 100 % trusted; HDMA and Core encodes are OK on
  hardware and must not regress.
- The official `.dtshd` binaries (`tbh.dtshd`, `Dolby_NaturesFury.dtshd`,
  `TBH_offical.dtshd`) are **still not uploaded** - see
  `cloud-fixtures/PARENT_UPLOAD_REQUEST.md`. Requested bitstream inspection of
  the new software encodes is impossible on this VM; everything below is
  validated with controllable vectors only.

## Root-cause findings for the onset-near-head pattern

What is measurably time-asymmetric in our delivered stream (established by
code audit and controllable vectors on this VM; the official binaries are
needed to confirm which of these the Encoder Suite also treats specially):

1. **The programme head is the terminal's convergence window.** The stream
   opens with two silent Core-priming access units (the terminal's XLL/XLL-X
   pipeline and Core filterbank converge on silence), and the reference
   decoder forces lossy first-frame recovery - `clip23(Core x sqrt(2))` - on
   the first XLL frame it filters and on every seek re-entry. Nature's Fury
   additionally keeps its first *source* access units silent, so every
   startup state change it exercises happens on silence. A hot-start title
   slams full-scale object content into exactly this window.
2. **Height onsets land on private-grammar reconfiguration boundaries.** A
   silence-to-active height transition is exactly where the private XLL-X
   payload switches from the compact silence forms (48/52/56-byte code-15/16
   declarations) to navigated Rice coding: NAVI appears, entropy parameters
   and payload sizes jump. Our render pipeline slews *gains* at the reference
   1/480-full-scale-per-sample bound, but nothing bounded the *audio* onset:
   a stems/wave source (or an object whose essence starts hot) delivered a
   full-scale first sample at the same access unit where the terminal
   reconfigures its height path. Every such coincidence is a pop opportunity;
   TBH's opening is exactly a cluster of them.
3. **The recovery-to-lossless handoff steps by the Core codec error.** While
   the terminal recovers on an access unit it plays the scaled Core alone; on
   the next access unit it switches to exact lossless output. The coded
   residual at the last sample of each access unit is precisely the step that
   handoff delivers on top of the content - and Core codec error is maximal
   at transients, i.e. at object onsets. This is now measured per stream
   (`maximumHandoffBoundaryResidual` in `verify-dtsx-recovery-window`) but
   cannot be calibrated against official behaviour without the binaries.
4. **What is *not* asymmetric:** the delivery public XLL partition search is
   pinned to 2x256 mid-stream (no partition flips at onsets), the hierarchy
   declarations are enforced constant, and Rice unary quotients are bounded
   at 22 everywhere - all previously shipped and re-verified green here, and
   all insufficient on hardware per Louis's report. The remaining pop
   carriers are therefore in the *PCM shape at onsets* and in *unmodeled
   official startup syntax* (blocked on the upload).

## Candidate schemes (new series, O1-O6)

### O1 - Height-layer programme-head onset ramp (~0.77 s, AU-aligned)

At the delivery encoder boundary, ramp the four height planes linearly from
zero over the first 36,864 samples (72 access units, 0.768 s - inside
Louis's suspected 0.5-1 s official onset envelope, AU-aligned so the ramp
completes exactly on an access-unit boundary). The floor bed is untouched.

- Mechanism: the terminal's convergence window (priming, first-frame
  recovery, first NAVI/entropy state changes) only ever sees quiet-to-rising
  height content - the closest controllable approximation of the silent-start
  class (Nature's Fury) that is known to play, applied only to the layer
  (object/height) that carries the failure.
- Evidence for: the discriminator is *silent start plays, hot start fails
  while content stays hot, and stabilizes later*; the height layer is the
  DTS:X-specific delivery path (the floor bed through Core/XLL is the
  HDMA-certified-OK path); Louis independently proposed a 0.5-1 s object
  fade for the first seconds.
- Evidence against: cannot be confirmed as official Encoder Suite behaviour
  until the binaries arrive; a ~10 s hard failure cannot be *explained* by
  the first 0.77 s alone (but the pattern says probability decays with time,
  not that the failure is uniform).
- Risk to NF/HDMA: none by construction - multiplying zeros is bit-exact, so
  any programme whose heights are silent through the head window (the NF
  class) passes through unchanged; HDMA/Core paths never see this code.
  Editorial cost: hot-start titles' height layer eases in over 0.77 s
  (currently that window does not play at all).

### O2 - Height-plane silence-to-active onset continuity slew (reference slew, 10 ms)

At every height-plane transition from >= 512 samples of silence to activity,
test the onset against the reference renderer's slew envelope
(`E[k] = (k+1) x fullScale / 480`). Onsets already inside the envelope pass
through bit-exact; onsets that violate it (hard steps no reference-rendered
pan could produce) are ramped over 480 samples (10 ms).

- Mechanism: the silence-to-active access unit is exactly where the private
  grammar reconfigures (silence form -> navigated Rice). A hard step at that
  boundary races the terminal's height-path reconfiguration; a
  reference-slew-bounded onset makes any un-mute/reconfiguration race
  inaudible and removes the worst-case first-sample energy.
- Evidence for: matches the onset-correlated pop pattern at *all* programme
  times, with the near-head correlation covered by O1; rendered-object
  onsets whose gains ramp through `DTS714ObjectGainSmoother` already satisfy
  the envelope, so the official render behaviour is the transparent case.
- Evidence against: onsets from hot object *essence* (audio that starts loud
  with static gains) are steps in official renders too, and official
  terminals play official streams - so this bounds a symptom whose official
  handling is unknown until the binaries arrive.
- Risk to NF/HDMA: silent planes and naturally slewed onsets are bit-exact
  passthrough (proved by gates); 10 ms of onset shaping on hard-cut stems is
  below editorial relevance; floor bed untouched.

### O3 - Recovery-handoff divergence audit (first frame / seek re-entry)

Measure, for every access unit, the coded residual at the last sample (the
exact PCM step a terminal delivers when it exits `clip23(Core x sqrt(2))`
recovery into lossless output at that boundary) and the maximum residual of
the first source access unit. Implemented in `verify-dtsx-recovery-window`
(`maximumHandoffBoundaryResidual`, `maximumHandoffBoundaryResidualFrameIndex`,
`firstSourceAccessUnitMaximumResidual`), report-only.

- Mechanism: quantifies the residual pop channel that grammar audits cannot
  see; identifies which access units are dangerous to recover on; runs
  unchanged against the official binaries the moment they are uploaded (the
  official titles will calibrate what magnitude is "normal").
- Evidence for: the recovery contract is documented reference-decoder
  behaviour; Core codec error is provably largest at onsets.
- Evidence against: measurement alone removes no pop.
- Risk: none (no stream change).

### O4 - Private-grammar pre-arm (silence form -> active form one AU early)

Emit the access unit *before* each height onset with ordinary navigated Rice
coding of zero planes instead of the compact silence declaration, so the
terminal's NAVI/entropy reconfiguration happens while the heights are still
silent and the onset lands in an already-armed pipeline. Zero audio change.

- Mechanism: decouples grammar reconfiguration from content onset in time.
- Evidence for: pure grammar change, lossless, no editorial cost.
- Evidence against: requires knowing whether official streams pre-arm - the
  recovered corpus notes say the official stream uses the compact silence
  form "whenever an ordinary source AU has silent height planes", which
  argues official does *not* pre-arm; hardware already rejected two
  "syntactically legal but corpus-alien" families (Linear controls, Branch-2
  controls). Shipping a third unverified grammar family is the same gamble
  that produced earlier failures.
- Risk: medium-high until the binaries arrive. **Deferred.**

### O5 - Codec-error-aware Core margin (two-pass per-AU re-encode)

Re-encode each Core access unit after measuring its decoded output so that
`clip23(sqrt(2) x decodedCore)` never clips and the handoff residual (O3's
metric) stays under a bound even at hot onsets.

- Mechanism: directly shrinks the recovery-window burst and the handoff step.
- Evidence for: attacks the only lossy link in the chain at exactly the
  onset samples.
- Evidence against: measured recovery overshoot on guarded content is a
  fraction of a dB; requires restructuring the streaming Core pipeline into
  two passes against serial QMF/LFE history; the bound itself needs official
  calibration (O3 against the official binaries).
- Risk to NF/HDMA: high (touches Core, the certified-OK layer). **Deferred**
  until O3 numbers from the official titles justify it.

### O6 - XLL-X segment-continuity bounds at onset AUs (ABIT delta / part-A suppression)

Constrain how fast the private Rice parameters (ABIT, part-A/part-B split)
may change across the silence-to-active boundary, so the onset access unit's
entropy declarations stay near the silence state instead of jumping to the
content optimum in one step.

- Mechanism: if the terminal's bounded reader mis-tracks fast parameter
  jumps, smoothing them helps.
- Evidence for: onset AUs are where parameters jump the most.
- Evidence against: no corpus evidence that official encoders bound
  parameter deltas; costs bits; the Rice <= 22 unary bound already caps the
  worst-case code length a terminal must absorb. Another corpus-alien
  gamble. **Deferred.**

## Selection (择优)

**Chosen and implemented: O1 + O2 (one conditioner at the delivery
boundary) + O3 (diagnostic).** Reasons, in evidence order:

1. O1/O2 are the only candidates that directly target the reported
   correlate - object onset proximity and programme-head proximity - while
   being **provable on this VM**: transparency for the silent-start class,
   envelope bounds at onsets, closed-loop bit-exactness, grammar safety, and
   a raw-step negative control are all gated by `verify-dtsx-onset-guard`.
2. They cannot regress the certified paths by construction: the floor bed
   (Core + public XLL - the HDMA-certified layers) is never touched, silent
   height windows are bit-exact passthrough (delivery and bypass streams are
   byte-identical on the NF-class gate vector), and no bitstream grammar
   changes at all - the stream stays inside the already-green perfect-stream
   invariants.
3. O3 is the cheapest instrument that converts the next hardware report into
   calibration data and runs unchanged against the official binaries.
4. O4/O6 ship unverified grammar families - the exact class hardware has
   already rejected twice; O5 modifies the certified Core layer for a
   bounded payoff. All three stay documented follow-ups pending the
   PARENT_UPLOAD_REQUIRED binaries.

The prior five-scheme work (boundary RenderGuard, grammar invariants,
Rice <= 22, 4x128 refusal, Core-fold) is kept unchanged underneath - Louis's
report shows it is necessary but not sufficient; this series stacks the
onset-shape dimension on top of it.

## Implementation on this branch

1. `DTS714HeightOnsetConditioner` (new): programme-head ramp (O1) +
   silence-to-active onset slew (O2) on the four height planes only;
   `DTS714DeliverySourceConditioner` chains it with `DTS714RenderGuard` as
   the single shared delivery-boundary pipeline.
2. `DTSXNativeHDMAEncoder`: the `delivery` source-guard policy now runs the
   shared pipeline; the encode report carries `sourceOnsetConditioning`.
   `bypassForDifferential` skips both stages (negative controls unchanged).
3. Closed-loop verifiers (`DTSXPrivateHeightVerifier`,
   `XLLCoreNativeVerifier.verifyDTSXCompatibilityBed`,
   `XLLCoreOracleVerifier.verifyDTSXCompatibilityBed`) compare against the
   identically conditioned expectation, so file-to-source verification stays
   bit-exact for delivery encodes.
4. `XLLRecoveryStartupVerifier`: O3 handoff-divergence fields (report-only).
5. `verify-dtsx-onset-guard` (new CLI gate): silent-start transparency and
   delivery/bypass byte identity, head/onset envelope compliance, no
   artificial discontinuity at the head-window exit, closed-loop
   bit-exactness, early-programme grammar safety on the conditioned encodes,
   and the honest negative control through the bypass.
