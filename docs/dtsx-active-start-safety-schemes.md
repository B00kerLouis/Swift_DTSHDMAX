# DTS:X active-start safety: candidate schemes and selection

Status snapshot this document responds to (Louis, 2026-08-26):

- Nature's Fury new encode plays; TBH new encode still fails for the first
  ~10 seconds.
- Loud pops ("bao yin") are reduced versus the previous tip but still present.
- Requested investigation directions: compression versus the perfect stream,
  object fade in/out (~1 s), downmix clipping, XLL-X safety bounds.
- No ffmpeg available; HDMA and Core encodes are locally OK and must not
  regress. Official `.dtshd` binaries are still not uploaded
  (see `cloud-fixtures/PARENT_UPLOAD_REQUEST.md`), so official-stream byte
  regression remains blocked and everything below is validated with
  controllable vectors only.

## Established facts the schemes build on

1. The reference decoder plays `clip23(Core x sqrt(2))` alone on the first
   XLL frame it filters and on every seek re-entry, and computes the same
   intermediate in steady state. The Core-residual hierarchy additionally
   promises that the target `Lss + coeff x LsrMix` fits signed 24-bit while
   the official constant matrix (scale/coefficient code 473) is declared.
2. The recovered official corpus keeps, on every observed frame:
   the primary residual channel mask at `0x00`, the hierarchy scale and
   surround coefficient codes at the constant `473`, Rice unary quotients at
   or below 22, and the mid-stream 2x256 public partition (4x128 appears only
   on the fully silent frame-indexed startup transition).
3. `DTS714RenderGuard` (already on this branch's base) bounds the twelve
   rendered planes against plane range, the legacy Q15 height fold, and the
   Core-residual recovery composite - but it runs **only inside
   `DTS714Renderer`**, i.e. only for Atmos-master inputs. The 7.1.4
   stems/WAV entry points (`encode-dtsx-source`, `encode-dtsx-native-source*`,
   `encode-dtsx-native-wave`, direct `DTSXNativeHDMAEncoder` callers) hand raw
   planes to the encoder with **diagnostics only**.
4. Measured on this VM (Linux, `verify-dtsx-render-guard`, controllable hot
   vector, no official binaries needed): the unguarded encode path hard-clips
   the compatibility-bed fold on 2,328 samples and leaves the official
   constant matrix (deviating coefficient codes) on 10 of 10 access units.
   The guarded path emits zero fold clips and zero deviating frames from the
   same content. Grammar the reference corpus never exercises - per-frame
   coefficient escapes and residual-mask flips - is exactly the class a
   terminal cannot be assumed to parse, and it appears precisely while the
   content stays hot, matching "the first ~10 seconds do not play, then it
   recovers" on a hot-start title (TBH) while a silent-start title (Nature's
   Fury) plays.

## Candidate schemes

### Scheme 1 - Encoder-boundary composite-headroom guard (universal source conditioning)

Move the downstream-headroom guard from the Atmos renderer to the DTS:X
encoder boundary: `DTSXNativeHDMAEncoder` applies `DTS714RenderGuard` to
every 7.1.4 source (stems directories, wave sets, external planes) before the
private XLL-X session and the compatibility-bed fold are built, and records
the guard report in the encode report. Content that never overloads any
composite passes through bit-exact (the guard is transparent by
construction), so the Atmos path - already guarded at render - is unaffected.

- Pros: closes the only unguarded delivery entry point; kills the measured
  defect class (fold hard clips = irreversible bed cracks delivered as
  clicks; coefficient escapes and mask flips = per-frame declaration changes
  the corpus never exercises, active exactly while content is hot); proven
  mechanism (slew-bounded anticipatory envelope, release 1/4800, no zipper
  steps); deterministic; fully testable with controllable vectors and the
  existing negative control, no ffmpeg, no official binaries.
- Cons / risks: for genuinely overloading sources the delivered PCM is
  rescaled (by design - the alternative today is a hard-clipped fold plus
  corpus-alien grammar); one transient copy of the source planes during
  conditioning.

### Scheme 2 - Codec-error-aware recovery margin (compression versus perfect)

The linear guard cannot see lossy Core codec error: the recovery output is
`clip23(sqrt(2) x decodedCore)` and decodedCore = fold/sqrt(2) + error. A hot
onset with our research-profile Core (fixed ABITS, 25-level quantizer) can
push the recovery composite past full scale even when the linear composite is
guarded. This scheme re-encodes each access unit after measuring the decoded
Core, applying an additional bounded margin so `recovery + sqrt(2) x error`
also fits, and reports per-AU recovery-clip counts.

- Pros: directly addresses the residual start/seek burst ("bao yin") the
  linear guard cannot remove; quantifies the compression gap versus the
  perfect stream per access unit.
- Cons / risks: needs a two-pass Core encode against serial QMF/LFE history
  (invasive restructuring of the streaming pipeline); the measured error
  margin on guarded content is bounded (recovery overshoot is a fraction of
  a dB at worst-case onsets) so the audible payoff is small relative to
  Scheme 1; a static global margin variant would alter all content including
  already-playable Nature's Fury.

### Scheme 3 - Programme-boundary object fade (~1 s) in the renderer

Fade object contributions in over ~1 s at programme start and out over the
final ~1 s (bed untouched), so the terminal's forced first-frame recovery and
decoder convergence window only ever see quiet object content.

- Pros: matches Louis's observation hypothesis about official Encoder Suite
  behaviour; guarantees a playable AU0 regardless of content; no bitstream
  grammar change at all.
- Cons / risks: cannot explain or fix ten seconds of sustained failure (a
  fade covers ~94 access units, the symptom spans ~960); intentionally alters
  delivered audio on every title including currently-playable ones; the ~1 s
  constant is unverifiable until the official TBH binaries are uploaded;
  fade-in of a hot master start is an audible editorial change.

### Scheme 4 - Core transient compression upgrade

Improve the Core encoder's bit allocation on transient onsets (per-subsubframe
scale selection / transient modes) so Core codec error - and therefore the
public XLL residual tail - shrinks at exactly the hot moments.

- Pros: attacks the "compression versus perfect" gap at the root; smaller
  residual tails lower Rice parameters and payload sizes everywhere.
- Cons / risks: highest regression risk of all schemes (Core and HDMA are
  currently reported OK on hardware and the priming/recovery grammar depends
  on Core layout); new Core syntax cannot be differentially validated against
  the official corpus until binaries are uploaded; large scope.

### Scheme 5 - Delivery-grammar hard invariants (fail-fast + stream gate)

Make the official-corpus declaration invariants enforceable instead of
best-effort: the delivery XLL encoder refuses to emit a frame whose hierarchy
escapes the constant matrix (coefficient != 473) or whose primary residual
mask leaves `0x00`, and the early-programme verifier audits the declarations
(mask / scale / coefficient codes / storage depth) of every access unit in
the startup window in addition to partitions and unary bounds.

- Pros: converts silent grammar excursions into loud, diagnosable encode
  failures; the stream-side declaration audit is exactly the check that will
  run against the official binaries when they arrive (declaration-exact
  regression); nearly free at runtime.
- Cons / risks: fail-fast alone produces no playable stream for hot content -
  it needs Scheme 1 as the resolution path; over-strict invariants could
  reject content classes the corpus does allow (mitigated by enforcing only
  on the delivery coding mode and keeping research/differential modes free).

### Scheme 6 - Scalable-LSB entropy relief (lossless tail compression)

Use the XLL scalable-LSB split on heavy-tailed segments so Rice codes only
carry the MSB part, cutting worst-case quotients and ABIT escalation without
losing losslessness.

- Pros: lossless; reduces XLL-X payload pressure on hot content.
- Cons / risks: whether the official corpus ever exercises nonzero LSB widths
  is unknown until binaries arrive; hardware already rejected one
  "syntactically legal but corpus-alien" control family (Linear controls
  were not recognized), so shipping another unverified field family is the
  same gamble that produced earlier failures. Rejected for now.

## Selection (rationale for the chosen scheme)

**Chosen: Scheme 1 combined with the enforcement half of Scheme 5** (they are
one coherent unit: the guard makes hot sources satisfy the invariants; the
enforcement makes it impossible to ship a stream that does not).

Reasoning, in evidence order:

1. The discriminating observation is *silent-start plays, hot-start fails
   while content stays hot*. Of all candidates, only the unguarded-source
   defect class reproduces that signature measurably today: the negative
   control shows corpus-alien declarations on 100% of hot access units and
   thousands of fold hard clips, and both disappear under the guard.
2. It is the only scheme that fixes both remaining symptom families at once:
   sustained early-programme unreadability (declaration excursions while
   hot) and residual pops (fold hard clips baked losslessly into the bed).
3. It is provable without ffmpeg and without the official binaries: the
   existing controllable vectors already exercise the defect and the fix
   end-to-end, and the new stream-side declaration audit doubles as the
   official-binary regression command for later.
4. It is the lowest-regression option: transparent for every source that
   never overloads (bit-exact passthrough), no change to Core, HDMA,
   priming, partitions, or Rice selection - the certified-OK layers stay
   byte-identical for in-bounds content.
5. Schemes 2/3/4/6 are retained as documented follow-ups: 2 and 4 need the
   official binaries to calibrate (compression gap), 3 needs the official
   TBH decode to confirm the ~1 s constant, 6 is a corpus-alien gamble.

## Implementation on this branch

1. `DTSXNativeHDMAEncoder` gains `sourceGuardPolicy` (`delivery` default,
   `bypassForDifferential` for negative controls); both encode paths condition
   the source through `DTS714RenderGuard` and record the report
   (`sourceRenderGuard`) in `DTSXNativeEncodingReport`.
2. The delivery configuration enforces official hierarchy grammar in
   `XLLEncoder`: a coefficient escape from 473 or a nonzero primary residual
   mask on the delivery coding mode is now a diagnosable encode error rather
   than silently emitted syntax.
3. `DTSXEarlyProgrammeGrammarVerifier` audits hierarchy declarations (primary
   mask `0x00`, secondary mask `0x03`, scale codes 473, coefficient codes 256
   except the two constant 473 rear-mix slots, storage depth 24) across the
   whole startup window; `isEarlyProgrammeSafe` requires them.
4. `DTS714RenderGuardVerifier` proves the new boundary: raw hot planes through
   the delivery encoder keep every invariant, the differential bypass still
   exhibits the defect (the negative control stays honest), and the quiet
   vector remains bit-transparent.
