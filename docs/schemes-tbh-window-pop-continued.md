# TBH window pops, continued — scheme census and the landed NAVI-width repair

Branch: `cursor/dtsx-tbh-window-pop-continued-3541`, created off `origin/main`
@ `08b4478` with the four prior-tip commits from
`cursor/dtsx-tbh-render-unsafe-3541` @ `30e6ec3` fast-forward integrated
(window tools, grammar timeline, reference gate, window-mimicking control
vector, and the corpus zero-plane declaration). Hardware verdict driving this
run: the pops inside `00:00:21:06`–`00:00:24:00` (stream AU 1994–2252) and
`00:02:51:00`–`00:02:56:00` (stream AU 16033–16502) survived both prior tips —
PR #24 (tools only, grammar identical to `main`) and PR #25 (corpus zero
declaration). HDMA and Core stay OK. No ffmpeg anywhere. No NAVI 11/13/14
ladder re-land.

Model: `claude-fable-5-thinking-xhigh`.

## Timestamped materials inventory — PARENT_UPLOAD_REQUIRED (mandatory, not skipped)

`git fetch origin cursor/cloud-materials-3541` at run start (2026-08-27T09:12Z)
carried **no** stamped reference binaries anywhere on the branch —
`cloud-fixtures/reference-streams/` holds only `README.md`,
`UPLOAD_BLOCKED.md`, and `WHERE_TO_PUT_ENCODES.md`. None of the requested
stamped names exist (expected stamp convention `YYYYMMDDTHHMMZ`, parent
example `20260827T0908Z`):

```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd                 MISSING
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd   MISSING
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf          MISSING
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt       MISSING
```

`hdmax verify-reference-streams` fails with the PARENT_UPLOAD_REQUIRED
message (re-checked after the fix landed, 2026-08-27T10:45Z: the materials
branch still carries only `README.md`, `UPLOAD_BLOCKED.md`, and
`WHERE_TO_PUT_ENCODES.md`). This run therefore validates on the in-repo
`test_X` PCM sources,
the recovered perfect-stream grammar, and the PR #24 window-mimicking
surrogate; **no byte-exact perfect-stream claim is made and no check passed
silently for lack of input**. Escalation to the parent remains open.

## What still fires inside the windows (measured on this VM)

The whole render → encode pipeline was re-audited on this branch with the
integrated tips in place. Render side: `DTS714Renderer` mixes events at
sample resolution, `DTS714ObjectGainSmoother` slews every retarget at the
reference 1/480 bound (IAB pan sub-blocks arrive as 250-sample retargets at
24 fps), `DTS714VBAPPanner` gain surfaces are continuous in position, and
`DTS714RenderGuard` is an anticipatory attack/hold/release envelope that is
bit-exact passthrough in headroom. Public XLL delivery pins the partition to
2×256 (`terminalOfficialRice` searches nothing else mid-stream), hard-throws
on hierarchy-coefficient escapes from the constant matrix code 473 and on
residual-mask escapes from the corpus-constant 0x00. Private delivery is
branch-0, fixed-order-zero, official bounded-unary Rice, with the corpus
zero-plane declaration integrated.

The per-frame grammar timeline over the window-mimicking surrogate then
leaves exactly **one** class-level declaration flip inside the windows, and
it sits on exactly the hardware-flagged access units:

```text
frame 16  mask 4  bed T  navWidth 11  segs [677, 673]  1400 B  (active)
frame 17  mask 0  bed T  navWidth 12  segs [2, 1]        52 B  (zero heights)
frame 18  mask 1  bed T  navWidth 11  segs [676, 674]  1400 B  (active)
```

Every bed-audible zero-height access unit inside the windows — the seam class
the object automation creates when the height mask flips — carries a private
NAVI declared at **bit width 12**. Every other navigated frame in the
programme (all window active frames, all steady frames) sits on the canonical
mid-stream width **11**. The recovered corpus attests private NAVI widths 8
(the compact navigated 4×128 startup silence, `[2, 1, 1, 1]`), 11 (every
qualified mid-stream reference vector — the encoder's own canonical width,
retained "so qualified/reference vectors remain byte-identical"), and the
four-data-byte 13/14-bit extents of oversized official active frames. A
**12-bit NAVI on a compact navigated frame is attested nowhere**, and the
11↔12 width flapping at 24 fps exists only inside the two pop windows.

Why the encoder emits 12 there: `[2, 1]` serialized at the canonical width 11
(`0x00 0x20 0x00`) is byte-identical to `[3, 1]` at width 12, so the
reverse-engineered navigation parser — which infers the width by
CRC/frame-size consistency search because the real width rule is not public —
reports two candidates, and the encoder's blanket parse-back-uniqueness guard
rejects width 11 and escapes to 12. That guard is **our** crutch; a real
terminal decoder does not guess the width by search, it applies the official
rule. The uniqueness guard therefore forced the delivery emitter off the
corpus-dominant width on exactly the window seam class. The prior tip landed
the corpus zero declaration (correct, kept) but introduced this width escape
in the same frames — consistent with hardware still popping after PR #25.

## Schemes considered (nine distinct mechanisms; ≥5 required, one implemented)

### Scheme 1 — ObjectGainSmoother / pan sub-block discontinuity at window AUs — REJECTED (audited clean, and the class is hardware-burned)

Full re-audit of the object path: IAB `ObjectDefinition` sub-blocks are
emitted as events at exact sub-block sample positions and every update passes
through `retarget(_:over:)` with the 250-sample sub-block period; the
smoother advances before each mixed sample, lands targets exactly, and
retargets from the exact current gain. The VBAP floor/height surfaces are
continuous trigonometric blends (no patch-boundary steps), and snap
transitions ride the same 1/480-bounded slew. No discontinuity exists to fix,
and the hardware record already burned renderer-side onset conditioning:
`beginFromSilence`, the delivery-boundary onset conditioner, and the
rate-exact slew all measurably increased pops. The render stage is left
bit-identical on this branch.

### Scheme 2 — RenderGuard / encoder-boundary plane handoff on height mask flips — REJECTED (audited clean)

`DTS714RenderGuard` applies one shared envelope: anticipatory attack bounded
at 1/480 per sample, 480-sample hold, 1/4800 release, with post-guard
constraint re-verification (`residualClippedSampleCount` is a hard gate). It
cannot introduce a step at a mask flip, and in-headroom content passes
bit-exact (`verify-dtsx-render-guard` PASS below). The encoder-boundary
conditioner is the same code (`DTS714DeliverySourceConditioner`), so the
handoff is idempotent by construction. No defect found; nothing to change.

### Scheme 3 — Private prediction/reflection transitions zero↔active mid-window — REJECTED (no transition exists in delivery)

Delivery mode is branch-0, fixed-order-zero for every plane of every frame:
`adaptivePredictionOrderHistogram` and `fixedPredictionOrderHistogram` are
pinned by stream-finalization guards, and the window census confirms constant
prediction boundary (10 bytes) and branch 0 across zero and active frames.
There is no coefficient state to transition; the scheme is a no-op on this
grammar.

### Scheme 4 — Public XLL residual/scale/hierarchy vs height onsets — REJECTED (already pinned by throwing guards)

Delivery public XLL cannot escape the official constants: the hierarchy
coefficient search throws on any deviation from the constant matrix code 473,
the primary residual mask throws on any deviation from the corpus-constant
0x00, the mid-stream partition search is restricted to 2×256, and the window
census shows the public unary quotient at/below the official bound of 22 with
no partition or mask flips anywhere in the windows. Nothing off-corpus
remains on the public side to repair.

### Scheme 5 — ExSS / asset-descriptor / presentation seam — REJECTED (no evidence)

Per-AU ExSS headers hold constant 40-byte headers and 23-byte asset
descriptors, and every asset descriptor closes its XLL frame exactly
(`exssAssetDescriptorClosesXLLFrame` true across the surrogate; enforced by
`allDTSXAssetDescriptorsMatchPrivateFrames` in integrated verification). The
brief allows this scheme only with evidence; there is none.

### Scheme 6 — Re-land the NAVI 11/13/14 width ladder — REJECTED (hardware-failed, forbidden)

PR #20/#22 invented a four-data-byte 13-bit serialization and pinned an
`[11, 13, 14]` ladder; Louis's hardware rendered both tips categorically
worse. Forbidden by the brief; recorded so no future agent re-lands it. Note
the landed scheme 9 below is the opposite of a ladder: it removes an invented
width (12) from the delivery output and restores the observed canonical one,
without touching the width-candidate machinery for active frames.

### Scheme 7 — Heuristic onset ramps (window-scoped smoothing, softer slews) — REJECTED (hardware-worsened, forbidden)

Every renderer-side onset-shaping attempt measurably increased pops on
hardware, and official renders deliver hot programme heads unfaded. Forbidden
by the brief.

### Scheme 8 — Zero-plane entropy declaration revisit (per-channel linear-0 beside dense Rice planes) — DEFERRED (corpus-blocked)

The integrated PR #25 fix declares all-zero segments with the corpus shared
form (`0x80 0x00` / `0x40`) and zero planes beside dense planes as
per-channel signed-linear width 0. The shared form is byte-attested by every
recovered silence template; the mixed-segment per-channel form is the only
locally unattestable extrapolation left in the windows. Whether official
encoders instead Rice-code a zero plane beside active planes is one census
command on `tbh_<STAMP>.dtshd` (`analyze-dtsx-pop-windows` reports per-plane
declarations); until the upload lands this is not locally decidable in either
direction, and flipping it back to the 256-bit unary-run form that PR #24-era
hardware already rejected would be regression, not repair. Blocked:
PARENT_UPLOAD_REQUIRED.

### Scheme 9 — Restore the canonical mid-stream NAVI width on compact navigated frames ← 择优 (landed)

- **Mechanism (as landed, commit `393d3bf`).** Delivery declarations only;
  no PCM path is touched:
  1. `DTSXPrivateNavigation.parse(body:navigationStartByteOffset:segmentCount:)`
     gains an opt-in `preferringCanonicalMidStreamWidth` mode: when the
     CRC/frame-size consistency search returns multiple width candidates,
     the parse resolves to the candidate at the canonical mid-stream width
     11 — but only when exactly one candidate carries width 11 **and** the
     two-segment profile. The multi-candidate case is precisely the
     compact-frame byte collision (`[2,1]`@11 ≡ `[3,1]`@12, three data
     bytes `0x00 0x20 0x00`); the corpus-dominant interpretation is the
     deterministic resolution a width-search parser can defend.
  2. The resolution is **class-gated at the AST level**: only frames
     declaring the ordinary navigated delivery class (primary six-bit code
     17, the ten-byte prediction header) may resolve an ambiguous word.
     Implementation surfaced two byte-level facts that make this gate
     load-bearing, both caught by `verify-dtsx-native-encoder` during
     development and fixed before landing:
     - the code-16 no-NAVI silence side information (`0x00 0x20` + its own
       CRC16) is **byte-identical** to a width-11 `[2,1]` NAVI word
       (`0x00 0x20 0x00` + CRC16 `0xca 0x7a`), so an unscoped resolution
       misreads every mid-stream silence declaration as navigation;
     - the encoder's canonical-first width ladder would otherwise migrate
       the compact 4×128 startup silence form (`[2,1,1,1]`, corpus width
       **8**) up to width 11, so the two-segment scoping is mandatory too.
  3. `selectNavigation` (encoder parse-back) opts in to the same rule, so
     the canonical width 11 it already tries first stops being rejected by
     the old blanket uniqueness guard. The bed-audible zero-height delivery
     frame then serializes its NAVI at width 11 (`0x00 0x20 0x00 0xca
     0x7a`), same 52-byte frame envelope, and the private NAVI width
     becomes **constant 11 across every navigated frame of the windows** —
     the flip seam is gone.
  4. Decoder containment: `decodeGeneric` now falls through to the
     entropy-boundary autodetect path when a navigation-guided decode
     fails, so a foreign frame whose true form really is the wider misread
     (a class our encoder never emits and the corpus never shows) still
     decodes exactly as before. The legacy five-byte two-segment parser
     (no callers) keeps the strict uniqueness rule. The native encoder
     verifier's zero-height frame pin is updated
     (`b32005…` width 12 → `65de03…` width 11) with the full provenance
     chain preserved in the comment.
- **Why it is the strongest justified fix.** It removes the single remaining
  class-level off-corpus declaration that fires exactly on the flagged
  access units: width 12 on a compact navigated frame is attested nowhere,
  the 11↔12 flapping exists only inside the two windows, and the replacement
  value is not invented — 11 is the encoder's own canonical width, retained
  specifically because qualified reference vectors are byte-identical at it.
  It also completes the PR #25 story coherently: the PR #24-era grammar
  encoded this class as 316-byte Rice-run frames whose larger segments made
  width 11 parse uniquely; PR #25's corpus zero declaration shrank the
  segments to `[2,1]`, created the byte collision, and its parse-back guard
  escaped the width to 12 on exactly the window seam class — hardware kept
  popping. After this branch the window frames carry corpus zero
  declarations, corpus width, corpus partition, corpus prediction — every
  locally attestable field is on its observed form.
- **Blast radius (measured below).** Exactly the bed-audible zero-height
  navigated frames: on the TBH-length surrogate the whole-programme grammar
  differential against the integrated PR #25 tip is **90 frames** (32 in
  window A + 58 in window B), every one of them a single-field
  `privateNavigationBitWidth` 12→11 change; 16,472 of 16,562 frames are
  grammar-identical, decoded PCM is identical (0 mismatched samples), and
  every active frame, both silence forms, priming, HDMA, and Core are
  byte-identical.
- **Risks, honestly stated.** (a) Whether official encoders emit a `[2,1]`
  navigated frame at width 11 for this class is not directly byte-attested —
  no active-programme official capture exists on this VM. What is attested:
  11 is the only observed ordinary mid-stream width, 8 belongs to the 4×128
  compact startup form, 13/14 to oversized four-data-byte frames, and 12 to
  nothing. The change strictly reduces off-corpus exposure and strictly
  reduces per-AU declaration flapping. Final arbitration is one census
  command on `tbh_<STAMP>.dtshd`. (b) A foreign stream whose NAVI truly is
  `[3,1]`@12 with the colliding byte pattern would now first be read as
  `[2,1]`@11; the decoder containment (entropy-boundary fallback) keeps such
  frames decoding correctly, and our own encoder cannot produce that form
  (a 3-byte first entropy segment does not exist in the delivery grammar:
  all-zero segments are 2 bytes, per-channel active segments are ≥ 6).

## 择优 rationale (why scheme 9 and only scheme 9)

1. It is the only locally **provable** off-corpus delivery form left in the
   windows after the integrated tips, and its trigger set is exactly the
   defect's trigger set (the census differential touches the zero-height
   window AUs and not one frame more).
2. The replacement value carries the strongest available attestation short
   of the blocked uploads: the encoder's own canonical width, byte-anchored
   by qualified reference vectors.
3. Schemes 1–5 were re-audited on this branch and are either clean, already
   pinned by throwing guards, or evidence-free; schemes 6–7 are
   hardware-burned classes the brief forbids; scheme 8 is corpus-blocked and
   stays executable as a one-command census the moment the uploads land.
4. The change is decode-neutral (PCM is untouched — declarations only),
   HDMA/Core-neutral (byte-identical), and hardware-safe in the sense that
   width 11 is the value every hardware-accepted mid-stream frame already
   uses.

## Verification record (this branch, Swift 6.0.3-RELEASE, Ubuntu 24.04, `swiftc -O -D DEBUG`)

All repository sources with the untracked one-line Linux `main.swift` shim
(the tracked `main.swift`/`HDMAXFramework.swift` are the macOS `@objc`
bridge). Baseline binaries built with identical flags from clean worktrees
of the integrated tip `30e6ec3` (PR #25 grammar) and of `main` @ `08b4478`
(PR #24-era grammar; that binary predates the `pop-window-motion` control
vector, so its baseline data point below uses `channel-walk`).

### HDMA + Core — byte-identical and green (no-regression proof)

```text
verify-hdma  generated 5.1, 48 AUs   PASS (isBitExact true)  tip/fix output SHA-256 IDENTICAL
verify-hdma  generated 7.1, 48 AUs   PASS (isBitExact true)  tip/fix output SHA-256 IDENTICAL
verify-core-syntax  fix channel-walk encode   PASS (exit 0, full syntax report)
```

### DTS:X delivery difference profile — exactly the intended class, nothing else

`encode-dtsx-control` (8 source AUs each), `30e6ec3` tip vs fix binaries,
whole-file SHA-256:

```text
silence        IDENTICAL   (all silence forms untouched, priming untouched)
all-sine       IDENTICAL   (no bed-audible zero-height frame in the stream)
sine:Lfh       IDENTICAL   (bed-silent: height-silent AUs are *fully* silent
impulse:Lfh    IDENTICAL    AUs → code-16 silence class, not this class)
channel-walk   DIFFERS     (the only vector containing bed-audible
                            zero-height AUs)
```

The differing channel-walk stream: `verify-dtsx` structurally valid,
grammar differential is `privateNavigationBitWidth` 12→11 on exactly the
five bed-audible zero-height frames and no other field, and
`compare-public-xll-decoded` reports 0 mismatched samples — declarations
moved, audio did not. Against the `main` @ `08b4478` baseline the same
vector differs on the whole zero-height class (byte counts, entropy
declarations, NAVI segments — that is the integrated PR #25 zero
declaration, 316 B → 52 B) with decoded PCM again identical, confirming
this branch = PR #25 grammar + width repair only.

### test_X closed loops — 11/11 bit-exact on the fix binary

`encode-dtsx-native-source` from `cloud-fixtures/test_X/pcm-sources/<SET>`
then `verify-dtsx-714-native` and `verify-dtsx-private-heights-native`:

```text
ALL_MUTE ALL_SINE CHANNEL_WALK_COMPACT FRAME_EDGE_Lsr FULLSCALE_C
IMPULSE_L IMPULSE_LFH LFH_ONLY LFH_RFH LFH_RFH_OPPOSED SILENCE
→ all 11 isBitExactSevenOneFour=true totalMismatchCount=0,
  all 11 heights isBitExact=true differentHeightSampleCount=0
```

### Native gates — all PASS on the fix build

```text
verify-dtsx-native-encoder    PASS  isVerified=true, deterministic=true, and
                                    every terminal check green including
                                    terminalStartupTransition,
                                    terminalHotStartStartupTransition,
                                    terminalBedOnlyProgrammeTimeline and the
                                    earlyProgramme block (the bed-audible
                                    zero-height pin updated 52 B width-12 →
                                    52 B width-11 with provenance kept)
verify-xllx-native-encoder    PASS  (12× isBitExact=true)
verify-dtsx-render-guard      PASS  (isVerified=true)
verify-dtsx-render-startup    PASS  (isVerified=true)
```

This gate also earned its keep during development: two intermediate
versions of the resolution (unscoped, then scoped only by segment count)
failed `terminalStartupTransition` because the code-16 silence side
information byte-collides with a width-11 NAVI word; the landed class gate
is the version all gates accept.

### TBH-length pop-window surrogate at the true mapped AUs

`encode-dtsx-control pop-window-motion:1992-2250:16031-16500` (16,560
content AUs → 16,562 stream AUs, 24 fps) encoded by both binaries with the
integrated closed-loop verification green on both (`isVerified=true`,
`decodedSampleMismatchCount=0`). Census via `analyze-dtsx-pop-windows …
00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00` (mapping confirms stream
AU 1994–2252 and 16033–16502), run twice against the fix stream: once with
the fix binary and once with the **pre-fix tip parser** (cross-version
decodability is part of the claim; both report identical numbers and 0
parse failures). Differential via `compare-dtsx-grammar-timelines`:

```text
                              tip (30e6ec3)         fix (this branch)
window A NAVI widths          11 ×226, 12 ×32       11 ×258 (constant)
window B NAVI widths          11 ×411, 12 ×58       11 ×469 (constant)
window A grammar transitions  395                   331  (−2 per repaired AU)
window B grammar transitions  710                   594  (−2 per repaired AU)
whole-programme widths        {8 ×1, 11 ×637,       {8 ×1, 11 ×727}
                               12 ×90}
silence-form census           IDENTICAL tip vs fix (16 code-16 silence AUs
                              per window untouched; startup/priming forms
                              byte-identical)
timeline differential         90 frames, single field
                              privateNavigationBitWidth, all inside the two
                              windows; 16,472 / 16,562 grammar-identical
parse failures                0 (both parsers, both streams)
decoded PCM differential      0 mismatched samples across all 16,562 AUs
                              (compare-public-xll-decoded,
                               isPublicXLLSemanticallyIdentical=true)
stream gates on fix stream    verify-dtsx isStructurallyValid=true;
                              verify-dtsx-recovery-window isRecoverySafe=true,
                              recoveryClipSampleCount=0,
                              scaleCodesMatchOfficialConstant=true
```

## One-command playbook once the uploads land

```bash
# Which width does official TBH use on compact navigated frames in the
# windows, and how does it declare zero planes beside dense ones (scheme 8)?
hdmax analyze-dtsx-pop-windows cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd \
  tbh-windows.json 00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00

# Field-level diff of this branch's re-encode against the reference
hdmax compare-dtsx-grammar-timelines REFERENCE.dtshd CANDIDATE.dtshd

# Presence + SHA-256 gate (stays red until then)
hdmax verify-reference-streams
```

Material stamp status: **PARENT_UPLOAD_REQUIRED** (checked at run start
2026-08-27T09:12Z and re-checked after the fix landed 2026-08-27T10:45Z; no
`*_YYYYMMDDTHHMMZ.*` binaries and no `UPLOAD_MANIFEST_*.txt` exist on the
materials branch). English commits. ffmpeg was not used anywhere. Model:
`claude-fable-5-thinking-xhigh`.
