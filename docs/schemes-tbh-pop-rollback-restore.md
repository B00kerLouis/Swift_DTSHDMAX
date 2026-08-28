# TBH pop rollback + restore — baseline decision, scheme census, the landed 择优, and the verification record

Branch: `cursor/dtsx-tbh-pop-rollback-restore-3541`, created fresh off
`main` @ `08b4478` (2026-08-27 bed-active silence timeline + delivery
startup grammar — the closest git anchor to Louis's "~2026-08-27 16:00
good version"). Hardware verdicts driving this run: the pops inside
`00:00:21:06`–`00:00:24:00` (stream AU 1994–2252) and
`00:02:51:00`–`00:02:56:00` (stream AU 16033–16502) survive every closed
tip (PR #20–#28), and Louis reports the **current tips (#27, #29 lineage)
cannot read the input files** while the ~16:00 baseline "fixed first-frame
playback and encodes normally". TBH master is the working example. No
ffmpeg anywhere. No NAVI 11/13/14 ladder re-land. English commits.
Model: `claude-fable-5-thinking-xhigh`.

## Rollback / baseline decision (mission step 1)

The timeline around Louis's good "~16:00 27/08" version (+0800 local):

| Tip | Local time | Content | This branch |
| --- | --- | --- | --- |
| `main` @ `08b4478` | 27/08 08:47 | silence timeline + startup grammar | **base** |
| PR #23/#24 tip `84806e3` | 27/08 15:02 | grammar timeline, window census, control vector (tools only) | cherry-picked |
| PR #25 tip `142db96` | **27/08 16:43** | + corpus zero-plane declaration | cherry-picked |
| PR #26 tip `05a6cf2` | 27/08 18:40 | + canonical NAVI width-11 repair | cherry-picked |
| PR #27 tip `c7021d6` | 28/08 10:17 | + **DAMF audio fallback** + stamped gate | gate kept, **DAMF dropped** |
| PR #29 tip `c4959b2` | 28/08 | + **DAMF metadata/CAF pin** + repaired render audit | audit kept, **DAMF dropped** |

The "~16:00 good version" is the PR #25 tip. This branch restores exactly
that delivery encoder plus the one later, deliberately kept grammar repair
(PR #26), and **rolls the input stage all the way back to `main`**:

* **Input path = `main` @ `08b4478` byte-for-byte.**
  `git diff 08b4478..HEAD -- Swift_DTSHDMAX/DTSObjects` is empty. The two
  `AtmosMasterReader` mutations from the closed #27 (`67c5835`, audio
  sidecar fallback) and open #29 (`460e14b`, metadata fallback + CAF
  byte-order pin) are **not** on this branch: Louis attributes the file
  input breakage to the tips carrying them, and with the DAMF archive
  still incomplete (6 of 46 parts) neither can be validated end-to-end on
  the real package. The TBH investigation is unaffected — the TBH master
  is IMF IAB MXF and never touches the DAMF reader.
* **Delivery encoder = the good 16:00 encoder + PR #26.** Proof below:
  the TBH-length surrogate re-encode is byte-identical
  (SHA-256 `93e177d5aa931e484df9c0234d560ddc8bb8174d9c72ab4f9f342f059daac7ba`)
  to the PR #26/#27/#29 recorded encode, and the grammar differential
  against a true-baseline binary confines every difference to the two
  proven fixes' frame classes.
* **Abandoned-PR cleanup.** PR #23–#26 content lives in this branch's
  history as clean cherry-picks; #27/#28 are closed and superseded; #29's
  only input-safe, decided content (the repaired window render audit
  gate) is integrated here, and its DAMF/CAF changes are explicitly
  deferred (scheme 2) rather than silently dropped.

## Reproduced input behavior on the real (partially restored) package

`cat Dolby_NaturesFury_DAMF.tar.gz.part-000..005 | tar -xzf -` restores
the complete real manifest `Dolby_NaturesFury_.atmos` (2,879 bytes) and
the first ~24 s of the real 128-channel CAF (443,572,736 bytes); the
`.atmos.metadata` sidecar sits beyond part-005 and is not restorable yet.
The real manifest references sidecars on a re-export stem that does not
exist in the package (`Dolby_NaturesFury_ADM_BWF.atmos.audio` /
`.atmos.metadata`, vs the actual `Dolby_NaturesFury_.atmos.*` files —
MATERIALS.md hashes agree). On this branch the baseline reader fails
**loudly and immediately**:

```text
error: I/O error: cannot open .../Dolby_NaturesFury_ADM_BWF.atmos.audio:
The file doesn't exist.
```

No silent pass, no path substitution. Whether the official-package layout
on Louis's Mac resolves these references (his baseline encodes normally)
or needs the #27/#29-style resolution is decidable only against the full
archive — exactly scheme 2's deferral condition.

## Schemes considered (eleven; ≥5 required, one implemented)

| # | Scheme | Verdict | Reason (one line; detail below) |
| --- | --- | --- | --- |
| 1 | Rollback to `main`@`08b4478` + selective re-integration | **择优 — landed** | The only locally provable defect this run can fix is the reported input breakage; restores the Louis-confirmed-working input by construction while keeping every proven pop repair byte-exactly |
| 2 | DAMF sidecar resolution + CAF byte-order pin (#27/#29 re-land) | DEFER (corpus-blocked) | Cannot be validated: archive stalled at 6/46 parts and the `.metadata` payload is unrestorable; Louis attributes the input regression to the tips carrying it; TBH path never touches it |
| 3 | Window render audit / signed-24 rail census over the real master | INTEGRATED as tool; RUN DEFERRED | The repaired `verify-tbh-window-render` gate is on this branch and compiles; it needs `QWER_TBH_IAB_<STAMP>.mxf`, which is not uploaded |
| 4 | ObjectGainSmoother / pan discontinuity at height onsets | REJECT | Re-audited clean on this exact build (`objectGainSmoothingPassed=true`, max step 2,232,594 Q30 ≈ 1/481 full scale); renderer-side onset conditioning is a hardware-burned class |
| 5 | Private prediction / reflection transitions in windows | REJECT | Delivery is branch-0, fixed-order-zero direct samples on every plane of every frame; census records zero prediction/reflection transitions inside the windows |
| 6 | Per-channel linear-0 zero planes beside dense planes (#25, render-unsafe scheme 1 lineage) | KEPT (already landed) | The census shows the corpus `0x80 0x00`/`0x40` zero declaration active on every window zero-plane; the off-corpus 256-bit unary Rice runs stay dead; hardware verdict still pending |
| 7 | NAVI 11/13/14 width ladder re-land | REJECT | Hardware-failed class, forbidden by the brief |
| 8 | Heuristic onset ramps / keep-alive dither | REJECT | Hardware-worsened class, forbidden; dither additionally breaks lossless faithfulness |
| 9 | ExSS seam / public XLL residual vs height onsets | REJECT | Pinned by throwing guards (constant matrix 473, residual mask 0x00, mid-stream 2×256, unary ≤ 22); this run's census re-attests all of them inside the windows |
| 10 | Silence-form run-length hysteresis (encode isolated zero-height AUs as ordinary dense-NAVI active frames) | DEFER (corpus-blocked) | PCM-identical by construction, but whether the official encoder bridges 1-frame zero gaps or emits the compact navigated form is one census command on `tbh_<STAMP>.dtshd`; landing it today is an unattestable grammar mutation — the forbidden ladder pattern |
| 11 | ABIT continuity at onsets (estimator swap / jump limiting) | DEFER (corpus-blocked) | Census measures 0→19 ABIT jumps at every one of the 637 in-window onsets; whether official streams show the same jumps is unattestable without the reference stream |

### Scheme 1 — rollback + selective re-integration ← 择优 (landed)

Mechanism. Base `main` @ `08b4478`; cherry-picks in order:

1. `30fcc7d` → grammar timeline export + differential + reference gate (#23, tools)
2. `84806e3` → timecode-window mapping + pop-window census + window-mimicking control vector (#24, tools)
3. `142db96` → corpus zero declaration for digital-zero XLL-X planes (#25, delivery encoder)
4. `05a6cf2` → canonical mid-stream NAVI width on compact navigated frames (#26, delivery encoder)
5. `ecf4f3f` → stamped reference-upload names in the gate (tools)
6. `6455ef9` + `064f95c` squashed, docs dropped → `verify-tbh-window-render`
   with the repaired full-scale check (counts exact signed-24 rail hits
   `== 8_388_607 || == -8_388_608` instead of the dead `Int32.max`
   comparison)

Not integrated: `67c5835`, `460e14b` (both DAMF `AtmosMasterReader`
mutations — scheme 2), every burned tip (#15/#16 ramps, #17/#20/#22 NAVI
ladder), and the abandoned PRs' scheme documents.

Why it is 择优: it is the only scheme that fixes a defect this run can
prove and Louis has confirmed (input works at the baseline; broken on the
current tips); it unblocks the entire hardware feedback loop, which every
deferred pop binary needs; and it does so with a measured, window-confined
encoder difference profile and a byte-identity proof against the proven
lineage (verification record below).

### Scheme 2 — DAMF sidecar resolution / CAF pin — DEFERRED, not discarded

The #29 analysis of the dangling-reference defect is plausible and its
resolution order is careful (existing reference wins; manifest-stem
sibling next; unambiguous sniffed sibling next; never silent). But this
run cannot reproduce a working end-to-end DAMF encode with or without it
(the `.metadata` payload is beyond the stalled upload), Louis reports the
input regression on exactly the tips carrying it, and re-landing an
unvalidatable input mutation would repeat the pattern this rollback
exists to end. Decision procedure once parts 006–045 land: restore the
package, run `hdmax -i Dolby_NaturesFury_.atmos -o NF.dtshd` on this
branch — if the package layout resolves (as on Louis's Mac), the baseline
reader is proven sufficient and #29's change stays out; if it fails on
the dangling stems, re-land #29's resolution as one commit and re-verify
`verify-dtsx` + bit-rate parity on the real encode.

### Scheme 3 — window render audit over the real master — tool landed, run blocked

`verify-tbh-window-render INPUT_IAB.mxf` renders the real master through
the production `DTS714Renderer` and reports, inside the two mapped
windows: PCM adjacent-sample continuity, exact signed-24 rail hits
(8,388,607 / −8,388,608 — the render guard's clip rails), and render-guard
engagement (`gainReducedSampleCount`, `minimumGainQ30`). This is the
render-time decision procedure for "does the delivered PCM itself carry
the pop" — the one question the surrogate cannot answer, because the
surrogate is synthetic and stays in headroom by construction. Blocked
solely on `QWER_TBH_IAB_<STAMP>.mxf`.

### Schemes 4/5/9 — render and public-layer classes — REJECTED on evidence

Re-audited on this exact build: the gain smoother passes its verifier with
maximum per-sample step 2,232,594 Q30 (≈ 1/481 full scale, inside the
1/480 reference bound); the render guard is transparent on in-headroom
content (`verify-dtsx-render-guard` isVerified, quiet vector bit-exact);
delivery prediction is order-0 everywhere (no state to transition);
public XLL declarations are pinned by throwing guards and the census
re-attests 2×256 partitions, unary quotients ≤ 22 (public) / ≤ 2
(private), and zero parse failures inside both windows.

### Schemes 10/11 — the remaining in-window binaries — DEFERRED with playbook

This branch's census over the byte-identical surrogate (16,562 stream
AUs) reproduces the prior record exactly:

```text
                      window A (1994–2252)    window B (16033–16502)
frames inside         258                     469
NAVI widths           11 × 258 (constant)     11 × 469 (constant)
forms                 226 active              411 active
                      32 navigated-silence    58 navigated-silence
                      16 code-16 margins      16 code-16 margins
grammar transitions   331                     594
height onsets/second  82.2                    82.2
max ABIT / increase   19 / 19                 19 / 19
parse failures        0                       0
```

No locally provable off-corpus delivery form remains inside the windows.
The window-unique classes are (a) the isolated bed-audible zero-height AU
(ordinary navigated frame, corpus zero declaration, 52 bytes) flapping
against 1,400-byte dense frames at up to 12 Hz, and (b) the 0→19 ABIT
jumps at all 637 in-window onsets. Whether the official encoder (i)
emits the same compact form, (ii) bridges short zero gaps inside active
runs as dense active frames (scheme 10 — PCM-identical either way), or
(iii) conditions ABIT growth (scheme 11), are three readings of one
binary that `analyze-dtsx-pop-windows tbh_<STAMP>.dtshd …` decides in one
command each. Landing any of them today ships a locally unattestable
grammar mutation — the exact ladder pattern that already burned twice on
hardware.

## Timestamped materials inventory — PARENT_UPLOAD_REQUIRED (mandatory, not skipped)

`git fetch origin cursor/cloud-materials-3541` at run start
(2026-08-28T08:58Z, tip `ed228e9`) and re-checked at 2026-08-28T09:23Z
(unchanged):

```text
docs/…/segmented-archives/Dolby_NaturesFury_DAMF.tar.gz.part-000..005   PRESENT (6 of 46)
docs/…/segmented-archives/Dolby_NaturesFury_DAMF.tar.gz.part-006..045   MISSING (40 parts)
docs/…/segmented-archives/TBH-reference-streams.tar.gz.part-000..056    MISSING (all 57 parts)
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd                      MISSING
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd        MISSING
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf               MISSING
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt            MISSING
```

`hdmax verify-reference-streams` on this branch reports
`uploadStatus = "PARENT_UPLOAD_REQUIRED"` with required missing names
`tbh.dtshd`, `Dolby_NaturesFury.dtshd`, `QWER_TBH_IAB.mxf` (stamped
variants accepted). Restored-payload SHA-256 checklist (MATERIALS.md):

```text
reference-streams/QWER_TBH_IAB.mxf    eae8225c7f795c31c98f5633fdfa2c1051a449f0b92d07dedca878731a3be5ea
reference-streams/TBH_offical.dtshd   54459dc5fa3acb30a241d3546062a9bd68e345d330f4212cd452ea3a4528adac
…DAMF/Dolby_NaturesFury_.atmos           0d7c509f3eb811343c8147618ba7a57720983d14628450cf088194e846e2107b
…DAMF/Dolby_NaturesFury_.atmos.audio     15cb9ca3553bfa779d6bf0af0117ecb4e8a242018dd4443aefcde9dca5af9f2b
…DAMF/Dolby_NaturesFury_.atmos.metadata  e3aaa082efff84b7d53cb644b9dde4cdba34b7de4cd24ab231840ce516e3c586
```

This run therefore validates on the in-repo `test_X` PCM sources, the
recovered perfect-stream grammar, and the window-mimicking surrogate.
**No byte-exact perfect-stream claim is made and nothing passed silently
for lack of input.** Escalation to the parent remains open until all 97
missing archive parts and the stamped encodes land.

## Verification record (this branch, Swift 6.0.3-RELEASE, Ubuntu 24.04, `swiftc -O -D DEBUG`)

All repository sources with the untracked one-line Linux `main.swift`
shim (the tracked `main.swift`/`HDMAXFramework.swift` are the macOS
`@objc` bridge). ffmpeg was not used anywhere.

### Encoder-path identity vs the proven lineage (byte proof)

The TBH-length pop-window surrogate
(`encode-dtsx-control pop-window-motion:1992-2250:16031-16500`, 16,560
content AUs, 24 fps) encodes to the **byte-identical** 40,080,172-byte
stream, SHA-256
`93e177d5aa931e484df9c0234d560ddc8bb8174d9c72ab4f9f342f059daac7ba` —
the same hash the PR #26/#27/#29 records pin.

### Encoder-path difference vs the true baseline (measured blast radius)

A second binary built from the tools-only tree (`757447e` = `main` +
#23/#24 census tools, **encoder untouched**) encodes the same surrogate
to 40,226,236 bytes (SHA-256 `f7b65f7c…7297b1`).
`compare-dtsx-grammar-timelines` baseline vs this branch:

```text
comparedFrameCount        16,562
identicalGrammarFrameCount 15,835
mismatchedFrameCount          727   (= the two windows' bed-audible classes)
firstMismatchFrameIndex     1,994   (= window A start AU)
fields differing          privateEntropySegments (727),
                          privateFrameByteCount (727),
                          privateNavigationSegmentByteCounts (727),
                          privateNavigationTrailingFrameByteCount (637)
fields identical          silence forms, NAVI widths, routing, prediction,
                          public XLL partitions/scales — everywhere
```

Exactly the #25 zero-declaration + #26 NAVI-width repair classes, nothing
else — the delivery encoder is `main`'s everywhere outside the proven
fixes.

### Native gates on this build

```text
verify-dtsx-native-encoder    PASS  isVerified=true, deterministic=true,
                                    objectGainSmoothingPassed=true (max step
                                    2,232,594 Q30), renderGuardPassed=true,
                                    early programme + bed-only timeline safe
verify-xllx-native-encoder    PASS  allVectorsBitExact=true
verify-dtsx-render-guard      PASS  isVerified=true, quiet vector transparent
verify-dtsx-render-startup    PASS  hot start bit-exact from sample zero
verify-hdma 5.1 / 7.1         PASS  isBitExact=true both (control encodes)
verify-core-syntax            PASS  allFramesParsed=true (channel-walk encode)
test_X closed loops           11/11 verify-dtsx-714-native
                                    isBitExactSevenOneFour=true,
                                    totalMismatchCount=0
                              11/11 verify-dtsx-private-heights-native
                                    isBitExact=true, 0 different samples,
                                    0 out-of-24-bit samples
recovery window (surrogate)   isRecoverySafe=true, recoveryClipSampleCount=0,
                              scaleCodesMatchOfficialConstant=true
verify-dtsx (surrogate)       isStructurallyValid=true, 16,562 private
                              frames, resynchronizationByteCount=0
pop-window census (surrogate) table above; field-identical to the prior
                              record
timecode mapping              AU 1994–2252 / 16033–16502 (= record;
                              sampleBoundariesAreExact=true)
verify-reference-streams      PARENT_UPLOAD_REQUIRED (expected — inventory)
DAMF probe (real files)       loud, immediate error on the dangling
                              manifest reference; no silent pass
verify-tbh-window-render      compiles and registers; no local IAB input
```

HDMA and Core are bit-exact on their control encodes and the DTS:X
surrogate byte-matches the proven lineage: **no regression anywhere on
the delivery path.**

## One-command playbook once the uploads land

```bash
# Presence + SHA-256 gate — resolves the stamped names automatically
hdmax verify-reference-streams

# Scheme 10/11 arbitration: what official TBH declares inside the windows
hdmax analyze-dtsx-pop-windows cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd \
  tbh-windows.json 00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00

# Field-level diff of this branch's re-encode against the reference
hdmax compare-dtsx-grammar-timelines REFERENCE.dtshd CANDIDATE.dtshd

# Scheme 3: render-guard engagement + PCM continuity + rail hits inside
# the real master's windows
hdmax verify-tbh-window-render QWER_TBH_IAB_<STAMP>.mxf

# Scheme 2 arbitration on the restored package (baseline reader first):
hdmax -i .../Dolby_NaturesFury_DAMF/Dolby_NaturesFury_.atmos -o NF.dtshd

# Louis's Mac test on this branch: encode TBH from the IAB master and
# play the two windows on the TBH hardware chain
hdmax -i "/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf" -o tbh-rollback.dtshd
```

Material stamp status: **PARENT_UPLOAD_REQUIRED** (as inventoried above).
English commits. Model: `claude-fable-5-thinking-xhigh`.
