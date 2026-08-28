# TBH pop-window fix (continued) — seam census, scheme table, the landed 择优, and the verification record

Branch: `cursor/dtsx-tbh-pop-window-fix-3541`, created off
`cursor/dtsx-tbh-pop-rollback-restore-3541` @ `50c2f37` (PR #30 tip — the
proven product base: input stage = `main` @ `08b4478`, delivery encoder =
the good 16:00 encoder + PR #26, all native gates green, hardware pops
NOT fixed). Mission: continue finding the render/encode change behind the
TBH hardware 爆音 inside `00:00:21:06`–`00:00:24:00` (stream AU
1994–2252) and `00:02:51:00`–`00:02:56:00` (stream AU 16033–16502),
prioritizing PR #30's deferred schemes 10 (silence-form run-length
hysteresis) and 11 (ABIT 0→19 onset continuity) plus the render audit on
the real IAB master. TBH IAB master (`QWER_TBH_IAB.mxf`) is the working
example. No ffmpeg. No NAVI 11/13/14 ladder re-land. HDMA + Core stay
bit-exact on control encodes. English commits.
Model: `claude-fable-5-thinking-xhigh`.

## Materials status — PARENT_UPLOAD_REQUIRED (unchanged)

`verify-reference-streams` on this branch reports, loudly:

```json
{
  "missing" : [ "tbh.dtshd", "Dolby_NaturesFury.dtshd", "QWER_TBH_IAB.mxf" ],
  "uploadStatus" : "PARENT_UPLOAD_REQUIRED"
}
```

* **TBH reference archive: missing entirely.** No official `tbh_<STAMP>.dtshd`,
  no `QWER_TBH_IAB.mxf`. The grammar diff vs the official stream (scheme 7
  below) and the render audit on the real master (scheme 6;
  `verify-tbh-window-render` errors immediately with
  `requires INPUT_IAB.mxf`) are both blocked.
* **DAMF archive: parts 000–005 of 46 only** (unchanged from PR #30);
  irrelevant to the TBH path (IMF IAB MXF never touches the DAMF reader).

Every conclusion below therefore rests on the deterministic TBH-length
surrogate (`encode-dtsx-control pop-window-motion:1992-2250:16031-16500`,
16,560 video frames @ 24 fps), whose pop-window grammar PR #30 showed to
reproduce the hardware-flagged seam classes.

## What the census shows inside the pop windows (surrogate, PR #30 baseline)

`analyze-dtsx-pop-windows` over AU 1994–2252 and 16033–16502 (both the
brief's exact AU ranges and the timecode-mapped ranges agree):

| Metric | Window 1 (AU 1994–2252) | Window 2 (AU 16033–16502) |
| --- | --- | --- |
| Height onsets (silent→active height planes) | 226 | 411 |
| Grammar transitions | 331 | 594 |
| `navigated-silence` frames (bed audible, height digital-zero) | 32 | 58 |
| `mid-stream-no-navigation` frames | 16 | 16 |
| Private NAVI bit width | 11 everywhere | 11 everywhere |
| Max private ABIT / max ABIT increase at onset | 19 / 19 | 19 / 19 |
| Private parse failures | 0 | 0 |

The hardware-suspect seam class, frame by frame: the windows alternate at
up to ~12 Hz between ~1,400-byte dense height-active frames and 52-byte
`navigated-silence` frames (bed audible, all four height planes
digital-zero, whole-frame shared-parameter zero declaration,
`ncSegType = 1`). At every re-onset the affected plane's declared ABIT
jumps 0→19 in one frame, and back at the next gap — the plane's entropy
declaration flaps 0↔19 across every one of the 90 in-window gap frames.
Both behaviors are byte-legal and verifier-clean; PR #30 measured them,
deferred them as corpus-blocked (schemes 10/11), and the hardware still
pops. The `activeHeightPlaneMask` is derived from decoded PCM, not
declared, so the *frame form* is the only grammar surface a terminal sees
at these seams.

## Schemes considered (seven; ≥5 required) — 择优 with explicit reasons

| # | Scheme | Verdict | Reason (one line; detail below) |
| --- | --- | --- | --- |
| 1 | Opt-in seam policy `bridged-zero-gaps` — scheme 10 realized as per-channel zero declarations on short gaps | **择优 — landed (opt-in, delivery default untouched)** | Attacks the measured whole-frame-form flapping with the exact per-plane zero grammar the official corpus already exercises inside active frames; PCM-identical; hardware becomes the arbiter the missing reference cannot be |
| 2 | Opt-in seam policy `sticky-rice-zero-gaps` — scheme 11 realized as gap-scoped ABIT continuity | **择优 — landed (opt-in, delivery default untouched)** | Attacks the measured 0↔19 ABIT flapping precisely where it happens (90 gap frames), nowhere else; PCM-identical; all-zero Rice residuals emit quotient 0, far under the bounded-reader max 22 |
| 3 | Pop-window census extension: zero-height seam-form classifier | **Landed (diagnostic only)** | One field (`zeroHeightSeamFormCounts`) proving which declaration form each A/B stream actually carries in-window; zero encode-path effect |
| 4 | Land scheme 1 or 2 as the delivery default | REJECT | An unattestable grammar mutation on the delivery path — byte-for-byte the forbidden pattern (NAVI ladder) PR #30 existed to roll back; nothing may change delivery bytes until the official TBH census or Louis's hardware verdict decides |
| 5 | Global ABIT slew-limiting / estimator swap at all 637 in-window height onsets | REJECT | Rewrites attested active-frame grammar everywhere (blast radius: every onset in every stream, not 90 gap frames); whether official streams limit onset ABIT is exactly the question the missing reference answers; strictly dominated by scheme 2 |
| 6 | Render audit on the real IAB master — rail hits, render-guard engagement (PR #30 schemes 3/4) | BLOCKED — PARENT_UPLOAD_REQUIRED | `verify-tbh-window-render` is integrated and errors loudly without `QWER_TBH_IAB.mxf`; the render-side hypothesis is untestable until the master is uploaded |
| 7 | Grammar diff vs official TBH stream | BLOCKED — PARENT_UPLOAD_REQUIRED | One `analyze-dtsx-pop-windows tbh_<STAMP>.dtshd` run arbitrates schemes 1/2/4/5 outright; the archive is missing entirely |

### Why the 择优 is the opt-in A/B pair (1 + 2 + 3), spelled out

1. **The two strongest remaining encode-side hypotheses are exactly PR
   #30's deferred schemes 10 and 11**, and both live on the same 90
   in-window gap frames. Everything else in the windows (ExSS headers,
   NAVI widths, segment counts, onset masks) was already audited clean on
   PR #30.
2. **Neither hypothesis is attestable from the corpus we hold.** The
   official TBH stream that would show whether the reference encoder
   bridges 1-frame zero gaps (scheme 10) or keeps onset ABIT continuous
   (scheme 11) is not uploaded (PARENT_UPLOAD_REQUIRED). Landing either
   on the delivery path would repeat the NAVI-ladder mistake — scheme 4's
   rejection.
3. **Opt-in modes convert the missing-reference deadlock into a hardware
   experiment.** Three surrogate streams that are PCM-identical and
   differ *only* in the 90 gap frames' declarations (proved below) give
   Louis a clean single-variable A/B/C on the actual popping terminal —
   the only arbiter currently available.
4. **Delivery risk is provably zero.** The default
   (`--private-seam-mode compact`) encodes byte-identically to the PR #30
   pin (`93e177d5…`, verified this run), all native gates pass, and the
   non-default policies cannot engage implicitly — they exist only behind
   the new CLI flag.

## What landed

### Seam policies (`DTSXPrivateSeamPolicy`, default `compact`)

`hdmax encode-dtsx-control … --private-seam-mode {compact|bridged-zero-gaps|sticky-rice-zero-gaps}`

A frame is a *bridgeable gap* exactly when it belongs to a maximal run of
≤ 3 consecutive bed-audible zero-height access units (≤ 125 ms; longer
height-silent stretches keep the compact delivery forms — the target is
the 12 Hz flapping, not ordinary quiet programme) whose immediate
neighbors on both sides are height-active source access units. Fully
silent AUs and priming AUs are never bridged. On the surrogate this
selects all 90 in-window `navigated-silence` frames (32 + 58).

* **`compact`** — delivery default. Byte-identical to the proven PR #30
  lineage: gap frames keep the 52-byte whole-frame shared-parameter zero
  declaration.
* **`bridged-zero-gaps`** — scheme 10 reading (ii): gap frames suppress
  the shared form and declare each plane with the per-channel
  signed-linear width-0 zero grammar (60-byte frame) — the same per-plane
  zero declaration the official corpus exercises for silent planes inside
  active frames — so the whole-frame form never flaps against dense
  frames mid-run.
* **`sticky-rice-zero-gaps`** — scheme 11, gap-scoped: bridged gap frames
  additionally declare straight Rice with the flanking active frames'
  official delivery ABIT per plane (max of the two flanks; 0 keeps the
  linear width-0 form) over all-zero residuals (2,620-byte frame at the
  audited seam). Every quotient is 0; the plane's Rice parameter no
  longer flaps 0↔19 across isolated gaps. Projected all-zero payload is
  budget-fitted below the canonical width-11 segment capacity by demoting
  the smallest positive parameter to 0, so a bridged frame can never
  nominate an off-corpus NAVI width.

Plumbing: `DTSXPrivateStreamEncodingSession(seamPolicy:)` →
`DTSXPrivateFrameEncoder(zeroGapBridging:)`;
`DTSXNativeHDMAEncoder(privateXLLXSeamPolicy:)`;
`DTSAutomaticEncoder.encode(privateXLLXSeamPolicy:)`; the policy and the
bridged-frame count are surfaced in every encode report
(`seamPolicy`, `bridgedZeroGapFrameCount`).

### Census extension (diagnostic)

`analyze-dtsx-pop-windows` now reports `zeroHeightSeamFormCounts` per
window, classifying every bed-audible zero-height navigated frame's
entropy declaration: `shared-zero` (compact), `per-channel-linear-zero`
(bridged), `sticky-rice`. This is also the field that arbitrates scheme 7
in one command once the official stream is uploaded.

## Verification record (final build, all on this branch's binary)

**Delivery default is byte-identical to the PR #30 pin.**

```text
surrogate-default.dtshd  SHA-256 93e177d5aa931e484df9c0234d560ddc8bb8174d9c72ab4f9f342f059daac7ba  (== PR #30 pin)
surrogate-bridged.dtshd  SHA-256 0041d6a5a20a774e956635eee408048a716ca75c88c41f5aade79483ab0674cf  (bridgedZeroGapFrameCount 90, isBitExact true, isVerified true)
surrogate-sticky.dtshd   SHA-256 20fadbce5990f0bd8050eaff5903ffbf8da3692dbc264f6ad037597de04f61cd  (bridgedZeroGapFrameCount 90, isBitExact true, isVerified true)
```

**Blast radius is exactly the 90 gap frames, in both non-default modes.**
`compare-dtsx-grammar-timelines` default↔bridged and default↔sticky:

```json
{
  "comparedFrameCount" : 16562,
  "identicalGrammarFrameCount" : 16472,
  "fieldMismatchCounts" : {
    "privateEntropySegments" : 90,
    "privateFrameByteCount" : 90,
    "privateNavigationSegmentByteCounts" : 90,
    "privateNavigationTrailingFrameByteCount" : 90
  },
  "heightOnsetMismatchFrameIndices" : []
}
```

No onset moves, no NAVI width change (width 11 everywhere in-window in
all three modes), no parse failures.

**The census proves each stream carries the intended seam form** —
window 1 / window 2 `zeroHeightSeamFormCounts`: default `shared-zero`
32/58, bridged `per-channel-linear-zero` 32/58, sticky `sticky-rice`
32/58. Every pre-existing census metric is unchanged vs the PR #30
baseline record in default mode.

**Seam spot-check (sticky, AU 1999–2003):** the gap frame at AU 2001 now
declares Rice k=19 on exactly the planes active on its flanks with max
unary quotient 0; flanking dense frames are byte-identical to default.

**Native gates (final build):** `verify-dtsx-native-encoder`,
`verify-xllx-native-encoder` (all 13 vectors, `isBitExact true`),
`verify-dtsx-render-guard` (`deliveryRawHotGuardEngaged true`,
`isVerified true`), `verify-dtsx-render-startup`
(`silentStartHeadWindowSilent true`) — all pass. All 11 `test_X` closed
loops pass. HDMA 5.1/7.1 and core-syntax control encodes remain
bit-exact. `verify-reference-streams` reports PARENT_UPLOAD_REQUIRED
(mandated loud fail). No ffmpeg anywhere.

## Louis Mac A/B instructions (the actual arbitration)

1. Build `hdmax` from this branch tip.
2. Encode the same 7.1.4 source three times (surrogate command shown;
   substitute the real TBH-derived PCM when using the master):

```bash
hdmax encode-dtsx-control pop-window-motion:1992-2250:16031-16500 tbh-compact.dtshd 16560 --frame-rate 24
hdmax encode-dtsx-control pop-window-motion:1992-2250:16031-16500 tbh-bridged.dtshd 16560 --frame-rate 24 --private-seam-mode bridged-zero-gaps
hdmax encode-dtsx-control pop-window-motion:1992-2250:16031-16500 tbh-sticky.dtshd  16560 --frame-rate 24 --private-seam-mode sticky-rice-zero-gaps
```

3. Play all three on the TBH terminal; listen inside
   `00:00:21:06`–`00:00:24:00` and `00:02:51:00`–`00:02:56:00`.
   * compact pops, bridged clean → scheme 10 confirmed; promote
     `bridged-zero-gaps` next run with the hardware verdict as evidence.
   * compact and bridged pop, sticky clean → the ABIT flap is the
     defect; promote `sticky-rice-zero-gaps`.
   * all three pop → the encode-side seam hypotheses are eliminated; the
     defect is render-side or upstream — upload `QWER_TBH_IAB.mxf` so
     scheme 6's audit can run.
4. Independently: uploading the official `tbh_<STAMP>.dtshd` lets
   `analyze-dtsx-pop-windows` arbitrate schemes 10/11 grammatically in
   one command (`zeroHeightSeamFormCounts` + ABIT columns).
