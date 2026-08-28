# Baseline restore + TBH pop windows — rollback decision, scheme census, the landed fix, and the verification record

Branch: `cursor/dtsx-tbh-pop-baseline-restore-3fca`, created from
`cursor/dtsx-damf-input-tbh-pop-3541` @ `c7021d6` (PR #27 draft tip).
Hardware verdicts driving this run: the pops inside
`00:00:21:06`–`00:00:24:00` (stream AU 1994–2252) and
`00:02:51:00`–`00:02:56:00` (stream AU 16033–16502) survive every
integrated tip, and Louis reports the **current version cannot read the
input files** while "the version around 2026-08-27 16:00 fixed first-frame
playback and could encode files normally". No ffmpeg anywhere. No NAVI
11/13/14 ladder re-land. Model: `claude-fable-5-thinking-xhigh`.

## Rollback / baseline decision (mission step 1)

The timeline around the user's "good ~16:00 27/08" version, all times
+0800 (Louis's clock):

| Tip | Local time | Content |
| --- | --- | --- |
| `main` @ `08b4478` | 27/08 08:47 | silence-timeline + startup grammar stabilization |
| `cursor/dtsx-tbh-pop-windows-3541` @ `946f72b` (PR #24) | 27/08 15:02 | window tools, census, control vector |
| `cursor/dtsx-tbh-render-unsafe-3541` @ `30e6ec3` (PR #25) | **27/08 16:43** | + corpus zero-plane declaration |
| `cursor/dtsx-tbh-window-pop-continued-3541` @ `c3ccbdf` (PR #26) | 27/08 18:40 | + canonical NAVI width-11 repair |
| `cursor/dtsx-damf-input-tbh-pop-3541` @ `c7021d6` (PR #27) | 28/08 10:17 | + DAMF audio fallback + stamped gate |

The "~16:00" good version is the PR #25 tip (16:43 local). Everything
after it divides cleanly:

* **PR #26 (NAVI width-11 repair)** touches only the private NAVI
  serialization/parse; it did not fix the hardware pops but nothing
  attributes a regression to it, its repair removes a width form the
  corpus never attests (the 11↔12 flap), and the parent's 28/08 brief
  explicitly instructs integrating it. **Kept.**
* **PR #27 (DAMF audio fallback + stamped reference gate)** touches only
  input reading and a validation gate — but its audio-only fallback is
  **provably incomplete on the real master package** (defect analysis
  below), which is exactly the reported "file input problems". **Kept and
  completed** (this branch's fix), rather than discarded: dropping it
  would re-break the Nature's Fury encode one step earlier.

So this branch **rolls forward from the consolidated PR #27 tip** instead
of rolling back to `30e6ec3`: every byte of the delivery encoder is
byte-identical to the good 16:00 version plus the two later, deliberately
kept repairs (proof: the TBH-length surrogate stream this branch encodes
is byte-identical, SHA-256
`93e177d5aa931e484df9c0234d560ddc8bb8174d9c72ab4f9f342f059daac7ba`, to
the PR #26/#27 recorded encode), and the only behavioural change is that
file input works again. Abandoned-PR cleanup: PR #24/#25/#26 content all
lives inside this branch's history (cherry-picked chain), PR #27 is
superseded by this branch, and the burned NAVI-ladder / onset-ramp tips
(#17/#20/#22 lineage) stay discarded.

## The reproduced file-input defect (found with the real master files)

The parent's segmented upload
(`cursor/cloud-materials-3541`, `docs/reference-streams/DTSX/segmented-archives/`)
is incomplete (6 of 46 Nature's Fury parts at run start), but a partial
`tar -xzf` of the concatenated parts restores the **complete real
manifest** `Dolby_NaturesFury_.atmos` (2,879 bytes) and the first ~24 s
of the real 128-channel CAF. The real manifest reads:

```yaml
metadata: Dolby_NaturesFury_ADM_BWF.atmos.metadata
audio: Dolby_NaturesFury_ADM_BWF.atmos.audio
fps: 24, offset: 0, ffoa: 0
bed: L R C LFE Lss Rss Lrs Rrs Lts Rts   (10 channels)
objects: ID 10…127                        (118 objects)
```

Both sidecar references carry a **re-export stem that does not exist**
beside the manifest; the actual package files carry the manifest's own
stem (`Dolby_NaturesFury_.atmos.audio` / `.atmos.metadata`, per the
parent's MATERIALS.md hashes). PR #27 resolved only the `audio:`
reference, so the encode on the current tip still fails one step later,
reproduced on this VM with the real files:

```text
note: … references missing audio Dolby_NaturesFury_ADM_BWF.atmos.audio; using the unambiguous sibling CAF file Dolby_NaturesFury_.atmos.audio
error: I/O error: cannot read …/Dolby_NaturesFury_ADM_BWF.atmos.metadata: The file doesn't exist.
```

The real CAF descriptor (parsed from the restored payload):
48 kHz `lpcm`, **formatFlags 2 (little-endian integer)**, 384
bytes/packet, 1 frame/packet, **128 channels**, 24-bit — so the
manifest's 10 + 118 element map matches the PCM, and the readers' fixed
little-endian 24-bit decode is correct **for this file**; the flags were
never checked, so a big-endian or float CAF would be silently byte-swapped
into near-full-scale wideband noise (a manufactured 爆音 across the whole
programme) and delivered faithfully by the lossless layers.

## Schemes considered (nine, per the parent's starter menu; ≥5 required)

| # | Scheme | Verdict | Reason (one line; detail below) |
| --- | --- | --- | --- |
| 1 | Complete DAMF sidecar resolution (metadata + manifest-stem preference) | **择优 — landed** | The actual reported defect; reproduced and then proven fixed with the real master files; blocks every hardware verdict while broken |
| 2 | CAF byte-order/format-flag pin | **择优 — landed** (same commit) | The readers assume little-endian; an unchecked big-endian/float CAF is a whole-programme noise generator; zero cost to compliant files |
| 3 | ObjectGainSmoother / pan sub-block discontinuity | REJECT | Re-audited clean; render stage byte-identical on this branch; onset conditioning is a hardware-burned class |
| 4 | RenderGuard / encoder-boundary plane handoff | REJECT as pop cause | `verify-dtsx-render-guard` PASS; transparent in headroom; engagement over the real TBH windows is decidable only against `QWER_TBH_IAB_<STAMP>.mxf`, and the guard report is already surfaced in every encode log |
| 5 | Private prediction / reflection transitions | REJECT | Delivery profile is order-0 direct samples on every plane of every frame; no predictor state exists to transition |
| 6 | Public XLL residual/scale/hierarchy vs height onsets | REJECT | Pinned by throwing guards (matrix 473, residual mask 0x00, 2×256, quotient ≤ 22); re-verified by this branch's own census |
| 7 | NAVI 11/13/14 width ladder re-land | REJECT | Hardware-failed class, forbidden by the brief |
| 8 | Heuristic onset ramps / LSB keep-alive dither in zero height planes | REJECT | Onset shaping is hardware-worsened and forbidden; keep-alive dither additionally breaks lossless faithfulness to the render |
| 9 | Further NAVI width / silence-form changes (mid-stream code-16 hysteresis; Rice-0 zero-plane runs) | DEFER (corpus-blocked) | This branch's own census shows no locally attestable defect left in the windows; each binary is decided by one command the moment `tbh_<STAMP>.dtshd` lands |

### Scheme 1 — complete DAMF sidecar resolution ← 择优 (landed, with scheme 2)

Mechanism. `AtmosMasterReader.read` now resolves **both** sidecar
references with one never-silent policy, in deterministic order:

1. The referenced file exists → used exactly as before (case A below).
2. The **manifest-stem sibling** (`<manifest>.atmos.audio` /
   `<manifest>.atmos.metadata` — the DAMF package convention, and
   exactly the real package's layout) → used, substitution reported on
   stderr. The stem preference also keeps resolution deterministic when
   a package later grows a second audio representation (an ADM BWF
   re-export beside the CAF), where the previous single-candidate rule
   turned into a hard "ambiguous" failure.
3. Exactly one sniffed sibling (audio: CAF/RF64-WAVE magic; metadata:
   `*.metadata` name) → used, substitution reported on stderr.
4. Zero or several candidates → the encode fails with the candidate list
   and the full directory inventory; the user's input path is never
   changed silently.

Why it is 择优: it is the only defect this run could locally prove, it is
the reported regression ("file input problems"), and the whole hardware
feedback loop — every deferred pop-window verdict — is blocked while
encodes fail. It changes zero delivery-encoder bytes (surrogate SHA
identity above).

### Scheme 2 — CAF byte-order/format pin ← landed with scheme 1

`readCAFDescriptor` now requires LPCM format flags to declare
little-endian integer samples (bit 0 float clear, bit 1 little-endian
set; the real Dolby export is flags == 2). The interleaved readers
(`AtmosSceneReader`, `DTS714Renderer.packed24`) decode packed 24-bit
little-endian and never consulted the flags, so a big-endian CAF would
have been silently byte-swapped sample-by-sample. Rejecting with a clear
error is strictly better than encoding garble; no compliant file is
affected.

### Scheme 3 — ObjectGainSmoother / pan discontinuity — REJECTED

Unchanged from the PR #25/#26/#27 re-audits, and the render stage on
this branch is byte-identical by construction. Metadata updates pass
`retarget(_:over:)` with the sub-block period, the smoother advances
before every mixed sample, and `objectGainSmoothingPassed=true` inside
`verify-dtsx-native-encoder` on this build. The hardware record already
burned renderer-side onset conditioning (it increased pops).

### Scheme 4 — RenderGuard / plane handoff — REJECTED as pop cause

One shared anticipatory attack/hold/release envelope bounded at 1/480
per sample; bit-exact passthrough in headroom;
`verify-dtsx-render-guard` PASS on this build (hot vectors bounded, no
residual clipping, quiet vector transparent). Whether the guard engages
inside the real TBH windows is exactly one `render(iab:guardReport:)`
run over `QWER_TBH_IAB_<STAMP>.mxf` once it exists; every `hdmax`
encode already prints the guard report (`sourceRenderGuard`) so Louis's
next local encode answers this without new code.

### Scheme 5 — private prediction/reflection transitions — REJECTED

`terminalRiceOfficial` delivery emits `adaptiveOrders=[0,0,0,0]`,
`fixedOrders=[0,0,0,0]`, empty reflection sets, branch-zero routing, for
every plane of every frame — there is no predictor state to transition.
Confirmed again by this branch's whole-programme timeline export.

### Scheme 6 — public XLL residual/scale vs height onsets — REJECTED

Delivery public XLL cannot escape the official constants (deviations
throw). This branch's surrogate census re-confirms: mid-stream partition
constant 2×256, maximum public unary quotient at the bound and never
over, `scaleCodesMatchOfficialConstant=true`,
`recoveryClipSampleCount=0`, `isRecoverySafe=true` across all 16,562
stream AUs.

### Scheme 7 — NAVI 11/13/14 ladder — REJECTED (forbidden)

Hardware rendered both ladder tips categorically worse; recorded so no
future agent re-lands it. This branch keeps PR #26's opposite repair
(canonical width 11; the census shows widths constant 11 across every
navigated window frame).

### Scheme 8 — onset ramps / keep-alive dither — REJECTED (forbidden)

Every renderer-side onset-shaping attempt measurably increased hardware
pops, and official renders deliver hot programme heads unfaded. Adding
inaudible LSB dither to digital-zero height planes (to avoid the
all-planes-zero navigated frame class entirely) additionally makes the
delivered stream no longer a lossless carriage of the render — rejected
without corpus evidence that official height planes are never digital
zero.

### Scheme 9 — remaining window grammar binaries — DEFERRED (corpus-blocked)

This branch re-ran the full census on its own byte-identical surrogate
encode (16,562 stream AUs):

```text
                       window A (1994–2252)   window B (16033–16502)
frames inside          258                    469
NAVI widths            11 × 258 (constant)    11 × 469 (constant)
forms                  226 active             411 active
                       32 navigated-silence   58 navigated-silence
                       16 code-16 margins     16 code-16 margins
grammar transitions    331                    594
parse failures         0                      0
```

identical to the PR #26/#27 record: **no locally provable off-corpus
delivery form remains inside the windows**. The window-unique frame
class is the bed-audible zero-height AU (navigated `[2,1]`@11 with the
shared `0x80 0x00`/`0x40` zero declaration). Whether the official
encoder (a) uses this exact form, (b) Rice-codes zero runs instead,
(c) never lets rendered height planes reach digital zero, or (d) gates
mid-stream code-16 on a minimum silent-run length, are four readings of
one binary that `analyze-dtsx-pop-windows tbh_<STAMP>.dtshd …` decides
in one command each. Landing any of them today means shipping a locally
unattestable grammar mutation — the exact ladder pattern the briefs
forbid after two hardware-burned attempts. Deferred, with the playbook
below.

## Timestamped materials inventory — PARENT_UPLOAD_REQUIRED (mandatory, not skipped)

`git fetch origin cursor/cloud-materials-3541` at run start
(2026-08-28T07:53Z, tip `953721f`) and re-checked during the run
(2026-08-28T08:20Z, unchanged):

```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd                 MISSING
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd   MISSING
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf          MISSING
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt       MISSING
docs/…/segmented-archives/TBH-reference-streams.tar.gz.part-*      0 of 57 parts
docs/…/segmented-archives/Dolby_NaturesFury_DAMF.tar.gz.part-*     6 of 46 parts
```

The segmented Nature's Fury upload (ARCHIVES.md expects parts 000–045)
stalled after part-005 (13:46 +0800). The recovered prefix was still
enough to extract the real manifest and the first ~24 s of the real
128-channel CAF, which this run used for the defect reproduction and the
end-to-end fix verification below — but **no byte-exact perfect-stream
claim is possible** and every scheme-9 binary stays corpus-blocked until:

1. the remaining `Dolby_NaturesFury_DAMF.tar.gz.part-006…045` land,
2. the `TBH-reference-streams.tar.gz.part-000…056` archive lands
   (restores `QWER_TBH_IAB.mxf` + `TBH_offical.dtshd`), and
3. the stamped encode uploads (`tbh_<STAMP>.dtshd`,
   `Dolby_NaturesFury_<STAMP>.dtshd`, `UPLOAD_MANIFEST_<STAMP>.txt`)
   land under `cloud-fixtures/reference-streams/`.

## Verification record (this branch, Swift 6.0.3-RELEASE, Ubuntu 24.04, `swiftc -O -D DEBUG`)

All repository sources with the untracked one-line Linux `main.swift`
shim (the tracked `main.swift`/`HDMAXFramework.swift` are the macOS
`@objc` bridge). ffmpeg was not used anywhere.

### Encoder-path identity (no-regression proof by construction and by byte)

`git diff c7021d6..HEAD -- Swift_DTSHDMAX` touches exactly one file:
`DTSObjects/AtmosMasterReader.swift` (input resolution; runs before any
rendering). The TBH-length pop-window surrogate
(`encode-dtsx-control pop-window-motion:1992-2250:16031-16500`, 16,560
content AUs, 24 fps) encodes to the **byte-identical** 40,080,172-byte
stream, SHA-256
`93e177d5aa931e484df9c0234d560ddc8bb8174d9c72ab4f9f342f059daac7ba` —
the same hash the PR #26/#27 records pin.

### File-input restoration on the real master files

```text
real manifest + real CAF, dangling metadata (the field layout)
  → BEFORE: error: cannot read …ADM_BWF.atmos.metadata (reproduced)
  → AFTER:  resolves via manifest-stem; stderr notes for both sidecars
hdmax -i Dolby_NaturesFury_.atmos -o Dolby_NaturesFury.dtshd
  (real 128-channel CAF prefix, 10 s, 24 fps)
  → exit 0; 13,460,920-byte DTS:X HDMA stream + .dtspbr + _log.txt
verify-dtsx Dolby_NaturesFury.dtshd
  → isStructurallyValid=true, 940/940 private frames matched,
    zero resynchronization bytes
case matrix:
  A referenced files exist          → reads with no notes (regression)
  B manifest-stem siblings (real)   → resolves, two stderr notes
  C unambiguous other-stem siblings → resolves, two stderr notes
  D two audio candidates, no stem   → error listing candidates + inventory
  E no candidates                   → error listing inventory
```

### Native gates on this build

```text
verify-dtsx-native-encoder     PASS  isVerified=true, deterministic=true,
                                     every terminal check green (startup
                                     transitions, hot start, bed-only
                                     timeline, early programme, render
                                     guard, gain smoothing, recovery)
verify-xllx-native-encoder     PASS  allVectorsBitExact=true
verify-dtsx-render-guard       PASS  isVerified=true, quiet transparent
verify-dtsx-render-startup     PASS  hot start bit-exact from sample zero
verify-hdma 5.1 / 7.1          PASS  isBitExact=true both
verify-core-syntax             PASS  (channel-walk control encode)
test_X closed loops            11/11 verify-dtsx-714-native
                                     isBitExactSevenOneFour=true,
                                     totalMismatchCount=0
                               11/11 verify-dtsx-private-heights-native PASS
recovery window (surrogate)    isRecoverySafe=true,
                               recoveryClipSampleCount=0,
                               scaleCodesMatchOfficialConstant=true
pop-window census (surrogate)  widths 11×258 / 11×469 constant,
                               forms 226+32+16 / 411+58+16,
                               transitions 331 / 594, 0 parse failures
timecode mapping               AU 1994–2252 / 16033–16502 (= record)
```

## One-command playbook once the uploads land

```bash
# Presence + SHA-256 gate — resolves the stamped names automatically
hdmax verify-reference-streams

# Decides every scheme-9 binary: what the official TBH stream declares
# inside the windows (zero-plane form, code-16 run structure, ABIT)
hdmax analyze-dtsx-pop-windows cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd \
  tbh-windows.json 00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00

# Field-level diff of this branch's re-encode against the reference
hdmax compare-dtsx-grammar-timelines REFERENCE.dtshd CANDIDATE.dtshd

# Render-guard engagement over the real master's windows
#   hdmax -i QWER_TBH_IAB_<STAMP>.mxf -o tbh-reencode.dtshd
#   (sourceRenderGuard is printed in the encode report)

# The Nature's Fury encode itself is restored by this branch:
hdmax -i ".../Dolby_NaturesFury_DAMF/Dolby_NaturesFury_.atmos" -o Dolby_NaturesFury.dtshd
```

Material stamp status: **PARENT_UPLOAD_REQUIRED** (as inventoried above).
English commits. Model: `claude-fable-5-thinking-xhigh`.
