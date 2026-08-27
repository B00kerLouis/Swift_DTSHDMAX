# TBH pop windows — unsafe render/encode change, scheme selection, and the landed fix

Branch: `cursor/dtsx-tbh-render-unsafe-3541` (off `origin/main` @ `08b4478` only).
Task: Louis's hardware flags playback pops inside two timecode windows of the
TBH master (`00:00:21:06`–`00:00:24:00` ≈ stream AU 1994–2252 and
`00:02:51:00`–`00:02:56:00` ≈ stream AU 16033–16502 at 24 fps, mapping
contract landed by PR #24 and cherry-picked here). Unlike PR #24
(analysis-only), this branch identifies the unsafe coded form that fires
exactly inside those windows and lands the fix. No ffmpeg anywhere; no
reference binary was invented; every claim below is backed by a command run
on this VM.

## Timestamped materials inventory — PARENT_UPLOAD_REQUIRED (mandatory, not skipped)

`git fetch origin cursor/cloud-materials-3541` at run start
(2026-08-27T07:23Z) and again at **2026-08-27T08:40Z** carried **no**
stamped or legacy reference binaries under
`cloud-fixtures/reference-streams/` — only `README.md`, `UPLOAD_BLOCKED.md`
and `WHERE_TO_PUT_ENCODES.md`. None of the requested stamped names exist
yet (expected stamp convention `YYYYMMDDTHHMMZ`, e.g. `20260827T0722Z` or
any newer UTC stamp):

```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd                 MISSING
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd   MISSING
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf          MISSING
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt       MISSING
```

`hdmax verify-reference-streams` (gate cherry-picked from PR #24) exits 1:

```text
error: Malformed stream: PARENT_UPLOAD_REQUIRED: reference encodes are
missing from cloud-fixtures/reference-streams (tbh.dtshd,
Dolby_NaturesFury.dtshd, QWER_TBH_IAB.mxf); byte-exact perfect-stream
verification is blocked until Louis pushes the Mac Downloads encodes to
the materials branch
```

This run therefore validates on the in-repo `test_X` PCM sources, the
recovered perfect-stream grammar, and PR #24's window-mimicking surrogate.
**No check passed silently for lack of input and no byte-exact
perfect-stream claim is made.** The gate stays red on this branch until the
uploads land — escalation to the parent remains open.

## The unsafe coded form (root cause thesis, provable on this VM)

Walking the whole render → encode pipeline on `main` @ `08b4478` and
re-auditing every stage that fires per access unit inside the windows:

| Stage | Audit result on `main` |
| --- | --- |
| `DTS714ObjectGainSmoother` | fixed 480-sample slew, continuous retargets, exact-target landing — the hardware-least-bad behaviour; no discontinuity |
| `DTS714Renderer` | events applied at sample resolution, gains advanced before each mixed sample, unsaturated mix handed to the guard once per programme |
| `DTS714RenderGuard` | anticipatory attack ≤ 1/480, 10 ms hold, 1/4800 release; transparent for in-headroom content (the surrogate stays in headroom) |
| Public XLL | hierarchy pinned to constant matrix code 473 (escape throws), mid-stream partition pinned 2×256, exhaustive Rice with the ≤ 22 unary bound |
| Private XLL-X prediction | delivery mode is branch-0 / fixed-order-zero everywhere — matches the recovered corpus profile |
| Private XLL-X silence timeline | frame-indexed forms landed at `08b4478`; census confirms conformant inside both windows |
| **Private XLL-X entropy for digital-zero planes** | **off-corpus: see below** |

The one delivery form that contradicts the recovered corpus is how
digital-zero planes inside **navigated** private frames are declared. The
delivery mode (`terminalRiceOfficial`) always Rice-codes: a zero plane gets
`bRiceCodeFlag = 1`, ABIT 0, and then **one unary terminator bit per
sample — 256 consecutive one-bits per plane per segment**. Byte dump of the
deterministic bed-audible zero-height frame on `main` (316 bytes) shows the
form directly — the body is runs of `ff`:

```text
main 316B: …7fffffffffffffffffffff…ff802a800003ffffff…ffffc00000000
```

Every zero-plane declaration the corpus actually exercises is the opposite
form. Decoding the recovered silence-form entropy bytes through the repo's
own segment parser (`DTSXPrivateFrameAST.decodeSegment`):

```text
0x80 0x00   segment 0: ncSegType=1 (one shared parameter set),
            bRiceCodeFlag=0 (signed-linear), ABIT0=0, ABIT=0  → 12 bits,
            byte-aligned, zero payload bits
0x40        segment>0: bUseSegStateCodeParm=0, ncSegType=1,
            bRiceCodeFlag=0, ABIT=0                            → 8 bits
```

These exact bytes appear in the no-NAVI 2×256 silence (`0x80 0x00 0x40`),
the no-NAVI 4×128 silence and — decisively — the **compact navigated 4×128
startup silence** (`0x80 0x00 0x40 0x40 0x40` inside a NAVI-carrying
frame), so the corpus attests the shared-parameter linear-0 declaration
*inside navigated frames*, and it never pairs a digital-zero plane with a
Rice run anywhere.

Why this fires exactly in the pop windows and nowhere else: TBH's height
planes are digital zero outside object flyovers, so steady bed-only spans
are uniform runs of one frame class (which the terminal demonstrably
plays). Inside the two windows the object automation flips the active-plane
mask per access unit — every navigated frame there carries 1–3 silent
planes beside dense ABIT-19/20 planes, and zero-height AUs interleave
between bursts. The census measures 82.2 height onsets/second in both
windows and all 637 programme onsets inside them. Every one of those frames
carried the corpus-alien 256-bit unary run form on `main`; a terminal
parser/DSP written against official encoders never sees that declaration,
let alone flapping against dense planes at 24 fps.

## Schemes considered (7 distinct mechanisms; ≥5 required)

### Scheme 1 — Declare digital-zero planes with the corpus zero declaration ← 择优 (landed)

- **Mechanism.** Two changes in `DTSXPrivateFrameEncoder`, delivery mode
  (`terminalRiceOfficial`) only:
  1. `selectEntropyMode`: an all-zero plane segment selects
     `.linear(width: 0)` (zero payload bits) instead of
     `.rice(parameter: 0)` (one unary terminator bit per sample).
  2. `encodeEntropySegment`: when **every** plane of a segment is zero,
     emit the corpus shared-parameter declaration — `ncSegType = 1`, one
     `bRiceCodeFlag = 0`, one ABIT0/ABIT pair — producing byte-exactly the
     recovered `0x80 0x00` / `0x40` segment bytes inside the ordinary
     navigated frame. Mixed segments keep per-channel declarations: dense
     planes stay on the official mean-magnitude bounded-unary Rice,
     zero planes take the per-channel signed-linear width-0 code.
- **Why it is the strongest justified fix.** It is the only locally
  provable off-corpus delivery form in the windows, the seam class fires
  exactly at the flagged AUs, and the replacement form is not invented:
  the shared-parameter zero declaration is byte-attested by every
  recovered silence form including a navigated one. Contrast with the
  burned NAVI-ladder class: that change invented a serialization with no
  corpus template; this change *removes* the only declaration with no
  corpus template.
- **Blast radius (measured, see verification record).** Exactly the frames
  carrying zero planes in navigated frames: on the TBH-length surrogate,
  727 of 16,562 frames differ — precisely the union of the two windows'
  bed-audible frames, first difference at stream AU 1994 (the window A
  start), all other 15,835 frames grammar-identical. HDMA, Core, silence
  forms, priming, all-dense DTS:X streams: byte-identical to `main`.
- **Risks, honestly stated.** (a) Whether official encoders use linear-0
  or Rice-0 for a zero plane *beside active planes* is not directly
  attested by the local corpus notes (no active-frame byte template is
  on this VM) — but Rice-0 unary runs are attested *nowhere*, and
  linear-0 is the only attested zero declaration, so this direction
  strictly reduces off-corpus exposure. Final arbitration is one census
  command on `tbh.dtshd` once uploaded. (b) The navigated zero-height
  frame shrinks 316 → 52 bytes and its NAVI width settles at 12 via the
  landed parse-back disambiguation (was 11 on `main`), so windows now
  show NAVI width 11↔12 flips at zero-height boundaries — both values
  are the hardware-proven mid-stream widths and width selection machinery
  is untouched (deliberately: schemes 2/6).

### Scheme 2 — Re-land the NAVI 11/13/14 width ladder — REJECTED (hardware-failed)

PR #20/#22 pinned private NAVI widths to an invented `[11, 13, 14]` ladder
with a four-data-byte 13-bit serialization; Louis's hardware rendered both
tips categorically worse than the residual pops. Forbidden by the brief;
recorded so it is never re-applied.

### Scheme 3 — Renderer-side onset conditioning (ramps from silence, softer or rate-exact slews, window-scoped smoothing) — REJECTED (hardware-worsened class)

`beginFromSilence` and the delivery-boundary height-onset conditioner both
measurably increased pops on hardware; the rate-exact slew steepened dense
fast-move retargets. Official renders deliver hot programme heads unfaded.
The parent's directive explicitly prefers perfect-stream-aligned grammar
safety over heuristic ramps. The render stage is left bit-identical: both
surrogate encodes decode to the same public PCM
(`compare-public-xll-decoded`: 0 mismatched samples over 16,562 AUs).

### Scheme 4 — ABIT estimator swap (zigzag-mapped mean vs raw-magnitude mean) — DEFERRED (needs corpus)

Would shift dense-segment ABIT by ~1 programme-wide; locally undecidable
(any consistent ABIT round-trips bit-exactly). One census command on
`tbh.dtshd` (per-segment ABIT beside byte counts) selects the estimator.
Blocked: PARENT_UPLOAD_REQUIRED.

### Scheme 5 — Entropy-state reuse (`bUseSegStateCodeParm = 1`) on stable window runs — DEFERRED (contradicts a landed gate)

The early-programme verifier classifies public state reuse as
research-only syntax recovered from priming-frame terminal failures; only
corpus evidence can arbitrate private mid-stream reuse. The landed fix
keeps `bUseSegStateCodeParm = 0` everywhere. Blocked.

### Scheme 6 — Pin the private NAVI width mid-stream (stop per-frame width refits) — REJECTED without corpus

The width policy is exactly the locally-undecidable mutation class that
produced the ladder failure. The census now reports the full width
distribution per window, so the pinned-vs-adaptive question becomes one
command on `tbh.dtshd`. Width machinery untouched on this branch.

### Scheme 7 — Render-guard engagement census over the real master's windows — DEFERRED (needs `QWER_TBH_IAB.mxf`)

The guard report (`overloadSampleCount`, `minimumGainQ30`,
`maximumGainStepQ30`) mapped through the TC→sample contract audits the
render stage at the flagged timecodes. Meaningless without the master's
actual object automation (the surrogate deliberately stays in headroom —
verified transparent). Blocked: PARENT_UPLOAD_REQUIRED.

## 择优 rationale (why scheme 1 and only scheme 1)

1. **It is a real fix in the unsafe coded path, not instrumentation**, and
   it is the only implementable scheme whose replacement form carries
   direct corpus byte attestation on this VM (decoded above from the
   recovered silence-form templates through the repo's own parser).
2. **Its trigger set is exactly the defect's trigger set.** Zero planes
   inside navigated frames exist on TBH-class masters precisely where
   object automation flips the height mask — the two flagged windows. The
   timeline differential proves the change touches those frames and not
   one frame more.
3. **It cannot regress HDMA/Core or the landed silence timeline** — proven
   byte-identical / gate-green below, including the `08b4478` bed-audible
   zero-height class (still an ordinary navigated frame, still decodes to
   four zero planes; only its entropy declaration moved onto the corpus
   form).
4. Schemes 2/3 are hardware-rejected classes; schemes 4/5/6/7 are
   corpus-blocked and each reduces to a one-command answer the moment
   Louis's uploads land — the strongest justified action today is the one
   corpus-aligned repair plus keeping those questions executable.
5. Every rejected/deferred scheme is recorded with its verdict so no
   future agent re-lands burned grammar.

## Verification record (this branch, Swift 6.0.3, Linux, `swiftc -O -D DEBUG`)

Toolchain: Swift 6.0.3-RELEASE on Ubuntu 24.04 over all repository sources
with the untracked one-line Linux `main.swift` shim (the tracked
`main.swift`/`HDMAXFramework.swift` are the macOS `@objc` bridge).
Baselines built from clean worktrees of `main` @ `08b4478` and of the
tooling-only cherry-pick `37f54cd` with identical flags.

### HDMA + Core — byte-identical and green (no-regression proof)

```text
verify-hdma  generated 5.1, 48 frames   PASS  main/fix SHA-256 IDENTICAL (12f92aba…)
verify-hdma  generated 7.1, 48 frames   PASS  main/fix SHA-256 IDENTICAL (b23eeb6f…)
verify-core-syntax  channel-walk fix encode   PASS (exit 0)
```

### DTS:X delivery difference profile — exactly the intended class

`encode-dtsx-control` (8 source AUs each), `main` vs fix binaries:

```text
silence        IDENTICAL   (silence forms untouched)
all-sine       IDENTICAL   (no zero plane in any navigated frame)
channel-walk   DIFFERS     (zero height planes in navigated frames)
sine:Lfh       DIFFERS     (three zero planes beside one dense plane)
impulse:Lfh    DIFFERS     (zero segments beside impulse segments)
```

All differing fix streams pass `verify-dtsx` structural verification.

### test_X closed loops — 11/11 bit-exact on the fix binary

`encode-dtsx-native-source` from `cloud-fixtures/test_X/pcm-sources/<SET>`
then `verify-dtsx-714-native` (Core + public XLL + XLL-X → 7.1.4) and
`verify-dtsx-private-heights-native` (routed heights vs explicit source):

```text
ALL_MUTE ALL_SINE CHANNEL_WALK_COMPACT FRAME_EDGE_Lsr FULLSCALE_C
IMPULSE_L IMPULSE_LFH LFH_ONLY LFH_RFH LFH_RFH_OPPOSED SILENCE
→ all 714-bit-exact PASS, all heights-bit-exact PASS
(main vs fix stream bytes: ALL_MUTE, ALL_SINE, SILENCE identical;
 all zero-plane-bearing sets differ, as intended)
```

### Native gates — all PASS on the fix build

```text
verify-dtsx-native-encoder    PASS  (isVerified true; bed-audible zero-height
                                     pin updated 316B/7c312a85… → 52B/b3200589…,
                                     provenance documented at the pin; priming
                                     48B and mid-stream silence 52B pins untouched
                                     and reproduced byte-exactly by the fix build)
verify-xllx-native-encoder    PASS
verify-dtsx-render-guard      PASS
verify-dtsx-render-startup    PASS
verify-dtsx-early-programme   PASS on both TBH-length surrogate encodes
```

### TBH-length pop-window surrogate at the true mapped AUs

`encode-dtsx-control pop-window-motion:1992-2250:16031-16500` (16,560
content AUs, 24 fps, integrated closed-loop verification green on both
builds; every emitted private frame is round-trip-verified at encode time):

```text
baseline (37f54cd = main grammar):  40,226,236 bytes  f7b65f7c49d2…
fix:                                40,080,172 bytes  14be8a5830a0…
```

`analyze-dtsx-pop-windows … 00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00`
— run with the **pre-fix parser** against both streams (cross-version
decodability of the new form is part of the claim):

```text
                            baseline            fix
window A frames             258 (226 active)    258 (226 active)
window B frames             469 (411 active)    469 (411 active)
height onsets/s             82.2 / 82.2         82.2 / 82.2 (identical)
silence-form timeline       conformant          conformant (identical counts)
public partition            2×256 pinned        2×256 pinned
private unary quotient max  2                   2      (bound 22)
public  unary quotient max  20 / 22             20 / 22 (at bound, not over)
private frame bytes         52 – 1592           52 – 1400
private NAVI widths         11 ×258             11 ×226, 12 ×32 (window A)
parse failures              0                   0
```

`compare-dtsx-grammar-timelines baseline fix` (16,562 frames):

```text
identicalGrammarFrameCount  15,835
differing frames               727  = window A 258 + window B 469, exactly
firstMismatchFrameIndex      1,994  = stream AU of 00:00:21:06, exactly
changed fields               privateEntropySegments, privateFrameByteCount,
                             privateNavigationSegmentByteCounts/Trailing,
                             privateNavigationBitWidth (90 frames = the
                             zero-height AUs inside the windows)
```

`compare-public-xll-decoded baseline fix`: 16,562/16,562 frames compared,
`decodedSampleMismatchCount: 0` — the rendered/delivered PCM is
bit-identical; this branch changes declarations, not audio.

### Honest observations (not hidden)

1. The navigated zero-height frame's NAVI width moves 11 → 12 (parse-back
   disambiguation over the new [2,1] segment byte counts), so windows gain
   NAVI-width transitions at zero-height boundaries. Both widths are the
   hardware-proven mid-stream values; the width policy itself was
   deliberately not touched (schemes 2/6). If `tbh.dtshd` shows official
   zero-plane-in-active-frame declarations differ, the census arbitrates
   in one command.
2. `grammarTransitionCount` inside the windows rises (331→395, 594→710)
   entirely from those width flips; the content-driven seam structure
   (mask flips, silence-form flips, onset density) is measured identical.
3. The two failing sub-gates of `verify-dtsx-native-encoder` before the
   pin update were the *intended* detection of the frame-class byte
   change; the pin's provenance (self-regression pin of our own
   deterministic output, not a corpus byte) is now documented at the
   constant with the old value preserved in the comment.

## One-command playbook once the uploads land

```bash
# Does official TBH declare zero planes linear-0 or Rice-0 in the windows?
hdmax analyze-dtsx-pop-windows cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd \
  tbh-windows.json 00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00

# Field-level diff of this branch's re-encode against the reference
hdmax compare-dtsx-grammar-timelines REFERENCE.dtshd CANDIDATE.dtshd

# Render-stage window audit (scheme 7) once QWER_TBH_IAB_<STAMP>.mxf lands
#   render(iab:guardReport:) over the mapped sample ranges

# Presence + SHA-256 gate (stays red until then)
hdmax verify-reference-streams
```

Model: `claude-fable-5-thinking-xhigh`. English commits. ffmpeg was not
used anywhere. Material stamp status: **PARENT_UPLOAD_REQUIRED** (last
checked 2026-08-27T08:40Z).
