# DAMF input fix + TBH pop windows continued — scheme census, the landed fixes, and the verification record

Branch: `cursor/dtsx-damf-input-tbh-pop-3541`, created off `main` @ `08b4478`
with all six commits of the closed PR #26 tip
`cursor/dtsx-tbh-window-pop-continued-3541` @ `c3ccbdf` cherry-picked in
order (grammar timeline/differential/reference gate, timecode-window mapping
and pop-window census, the corpus zero-plane declaration, the render-unsafe
scheme record, the canonical NAVI width-11 repair, and the window-pop scheme
record). Hardware verdict driving this run: the pops inside
`00:00:21:06`–`00:00:24:00` (stream AU 1994–2252) and
`00:02:51:00`–`00:02:56:00` (stream AU 16033–16502) **survived PR #26**
(closed "HW insufficient"), and Louis **cannot encode Nature's Fury at all**
because the DAMF manifest references audio that no longer exists beside it.
HDMA and Core stay OK. No ffmpeg anywhere. No NAVI 11/13/14 ladder re-land.

Model: `claude-fable-5-thinking-xhigh`.

## This branch in one paragraph

Two fixes landed, neither of which touches a single delivery-encoder byte:
the **DAMF sibling-audio fallback** (scheme 1, the encode blocker — the
whole hardware feedback loop was down without it) and **stamped-name
resolution in the reference-stream gate** (scheme 9's actionable remainder —
the parent's upload protocol now stamps every file, and the gate would have
stayed red across a completed stamped upload). The full window census was
re-run on this branch's own TBH-length surrogate encode: **every locally
attestable declaration inside both windows already sits on its corpus form
and no width/form flapping remains** (widths constant 11, forms conformant,
zero parse failures, all variation content-driven). The remaining
candidates are all corpus-blocked binaries that the still-missing stamped
uploads decide in one census command each — recorded below with their exact
playbook, and escalated again as PARENT_UPLOAD_REQUIRED.

## Timestamped materials inventory — PARENT_UPLOAD_REQUIRED (mandatory, not skipped)

`git fetch origin cursor/cloud-materials-3541` at run start
(2026-08-28T01:36Z, branch tip `c587ccc`) carried **no** stamped or legacy
reference binaries anywhere on the branch: `cloud-fixtures/reference-streams/`
holds only `README.md`, `UPLOAD_BLOCKED.md` (itself rechecked by the parent
at 2026-08-28T01:24Z), and `WHERE_TO_PUT_ENCODES.md`. None of the required
stamped names exist (stamp convention `YYYYMMDDTHHMMZ`, parent example
`20260828T0124Z`):

```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd                 MISSING
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd   MISSING
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf          MISSING
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt       MISSING
```

`hdmax verify-reference-streams` exits 1 with the PARENT_UPLOAD_REQUIRED
message. This run therefore validates on the in-repo `test_X` PCM sources,
the recovered perfect-stream grammar, and the PR #24 window-mimicking
surrogate; **no byte-exact perfect-stream claim is made and no check passed
silently for lack of input**. Escalation to the parent remains open, and
this branch makes the eventual upload immediately effective: the gate now
resolves the stamped names the parent's protocol requires (newest stamp
wins, legacy names still accepted), reports the resolved file + stamp per
role, and verifies the canonical Nature's Fury SHA-256 the moment a file
lands.

## The encode blocker, fixed (scheme 1)

Louis's command fails before any encoding starts:

```text
hdmax -i ".../Dolby_NaturesFury_DAMF/Dolby_NaturesFury_.atmos" -o .../Dolby_NaturesFury.dtshd
error: cannot open .../Dolby_NaturesFury_ADM_BWF.atmos.audio: doesn't exist
```

The manifest's `audio:` field references a file that is not beside it —
Dolby tooling re-exported or renamed the PCM container without rewriting
the manifest. `AtmosMasterReader.read(manifestURL:)` now resolves the
audio reference in three steps:

1. **Referenced file exists** → used as before (and a manifest that
   directly references a RIFF/RF64 WAVE now also reads, through the new
   packed-24-bit WAVE descriptor).
2. **Referenced file missing** → the manifest's directory is scanned;
   every regular sibling whose magic bytes identify a CAF (`caff`) or a
   RIFF/RF64 WAVE is a candidate. **Exactly one candidate** → it is used,
   and the substitution is reported on stderr
   (`note: DAMF manifest … references missing audio …; using the
   unambiguous sibling CAF file …`) — the user's input path is never
   changed silently.
3. **Zero or several candidates** → the encode fails with a clear error
   listing the candidates and the full directory inventory, telling the
   user to fix the manifest's `audio:` field or pass the intended
   representation directly.

The DAMF manifest and `.atmos.metadata` remain authoritative for element
mapping, fps, offset/FFOA, and object automation in every fallback case;
the sibling file only supplies interleaved PCM. The existing channel-count
and sample-rate guards still fire (now naming the resolved file) if the
sibling does not match the manifest, and `AtmosSceneReader` /
`DTS714Renderer` are container-agnostic already (interleaved 24-bit reads
at `audioDataOffset`), so rendering and encoding work identically over a
CAF or WAVE fallback.

Verified on synthetic DAMF fixtures (12-channel 7.1.4-bed + 2-object
masters, packed 24-bit, 48 kHz):

```text
A referenced CAF exists            → reads exactly as before (regression)
B missing → one sibling CAF        → resolves, stderr note, correct summary
C missing → one sibling WAVE       → resolves, stderr note; full automatic
                                     encode produces a structurally valid
                                     DTS:X HDMA stream + dtspbr/log sidecars
                                     (verify-dtsx isStructurallyValid=true,
                                     96/96 private frames matched)
D missing → CAF and WAVE both      → error listing both candidates + inventory
E missing → no audio siblings      → error listing the directory inventory
```

## What the windows declare on this branch (census, measured on this VM)

`encode-dtsx-control pop-window-motion:1992-2250:16031-16500` (16,560
content AUs → 16,562 stream AUs, 24 fps) encoded by this branch's binary
with integrated closed-loop verification green (`isVerified=true`,
`privateXLLXPCMVerified=true`, `publicCompatibilityBedPCMVerified=true`),
stream SHA-256 `93e177d5aa93…`, 40,080,172 bytes. The encoder path is
**byte-identical to the PR #26 tip by construction**: `git diff c3ccbdf..HEAD`
touches only `AtmosMasterReader.swift` (input reading) and
`DTSXReferenceStreamGate.swift` (validation gate).

`analyze-dtsx-pop-windows … 00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00`
(mapping confirms stream AU 1994–2252 and 16033–16502) plus a whole-frame
field sweep over the exported grammar timeline:

```text
                              window A              window B
bed-audible frames            258                   469
NAVI widths                   11 ×258 (constant)    11 ×469 (constant)
silence forms                 conformant (16 code-16 margin AUs each,
                              32 / 58 navigated zero-height AUs)
parse failures                0                     0
grammar transitions           331                   594   (= PR #26 record)
whole-programme widths        {8 ×1 (startup), 11 ×727} — width 12 is gone
private unary quotient max    2 (bound 22)
public  unary quotient max    22 (at bound, not over)
```

Every field that varies inside the windows is **content-driven**, not a
declaration-form change:

```text
activeHeightPlaneMask         which planes are audible (decoded PCM fact)
privateNavigationSegmentByteCounts  [676,674]/[677,673]/[676,675] — sizes
entropy riceCoding/ABIT       the ABIT-19 Rice declaration tracks the one
                              dense plane; zero planes are linear-0
trailing frame bytes 4↔5      required by the multiple-of-4 frame closure
                              (52-byte and 1400-byte frames both close ×4)
public byte counts/quotients  content
```

Seam audit at all four window boundaries (frames 1990–1999, 2246–2257,
16029–16038, 16498–16507): code-16 mid-stream silence frames (52 B,
prediction boundary 9) abut ordinary navigated frames (code 17, boundary
10, width 11) with every field on its recovered corpus value; the
zero-height frames inside the windows carry `[2,1]`@11 with the shared
`0x80 0x00`/`0x40` zero declaration — the PR #25 + #26 grammar, intact.

**Conclusion: no locally provable off-corpus delivery form remains in the
windows.** What remains is a short list of corpus-blocked binaries, each
decidable in one command against `tbh_<STAMP>.dtshd` (playbook below).

## Schemes considered (nine, per the parent's starter menu; ≥5 required)

| # | Scheme | Verdict | Reason (one line; detail below) |
| --- | --- | --- | --- |
| 1 | DAMF audio path fallback (CAF / ADM wav) | **择优 — landed** | The encode blocker: no fix ⇒ no Nature's Fury encode ⇒ no hardware test loop at all |
| 2 | ObjectGainSmoother / pan discontinuity | REJECT | Re-audited clean; render stage bit-identical; onset conditioning is a hardware-burned class |
| 3 | RenderGuard / plane handoff | REJECT | Re-audited clean; guard transparent in headroom, `verify-dtsx-render-guard` PASS on this branch |
| 4 | Private prediction / reflection transitions | REJECT | Delivery profile is direct samples, adaptive & fixed order 0, every plane of every frame — no state exists to transition |
| 5 | Public XLL residual vs height onsets | REJECT | Already pinned by throwing guards (matrix code 473, residual mask 0x00, 2×256, quotient ≤ 22); census confirms |
| 6 | ExSS seam | REJECT | No evidence; constant 40 B headers / 23 B asset descriptors; every descriptor closes its XLL frame |
| 7 | NAVI 11/13/14 ladder re-land | REJECT | Hardware-failed class, forbidden by the brief |
| 8 | Heuristic onset ramps | REJECT | Hardware-worsened class, forbidden by the brief |
| 9 | Further NAVI width / silence form issues | census run — **no defect shown**; gate remainder landed | Widths constant 11, forms conformant; the actionable remainder was the gate's stamped-name blindness, fixed |

### Scheme 1 — DAMF audio path fallback ← 择优 (landed, commit `67c5835`)

Mechanism, behaviour, and verification are in "The encode blocker, fixed"
above. Why it is 择优 (and marked "likely 择优 component" by the parent):

1. **It is the only scheme whose absence blocks every other scheme.** PR
   #26 was closed on a hardware verdict; the next verdicts (NF playback,
   TBH re-encode A/B) require Louis to encode locally, and that path was
   down. Every deferred grammar question below also ends in a hardware or
   byte census that needs encodes.
2. **It is fully decidable locally** — no corpus needed, deterministic
   fixtures prove all five behaviours, and the fallback engages only when
   unambiguous with the substitution surfaced on stderr (the brief's
   "do not silently change the user's input path" constraint).
3. **Zero delivery-grammar risk**: not one encoder byte changes; HDMA,
   Core, and every DTS:X stream this branch emits are byte-identical to
   the integrated PR #26 tip by construction.

### Scheme 2 — ObjectGainSmoother / pan sub-block discontinuity — REJECTED (re-audited clean)

Unchanged from the PR #25/#26 re-audits, re-confirmed on this branch's
sources: IAB `ObjectDefinition` sub-blocks are emitted as events at exact
sub-block sample positions, every update passes `retarget(_:over:)` with
the 250-sample sub-block period at 24 fps, the smoother advances before
each mixed sample and lands targets exactly, and the VBAP floor/height
surfaces are continuous trigonometric blends. The hardware record already
burned renderer-side onset conditioning (`beginFromSilence`, the
delivery-boundary conditioner, rate-exact slews all increased pops). The
render stage stays bit-identical on this branch;
`objectGainSmoothingPassed=true` inside `verify-dtsx-native-encoder`.

### Scheme 3 — RenderGuard / encoder-boundary plane handoff — REJECTED (re-audited clean)

One shared anticipatory attack/hold/release envelope bounded at 1/480 per
sample with post-guard constraint re-verification; bit-exact passthrough in
headroom (`verify-dtsx-render-guard` PASS on this branch, and the surrogate
stays in headroom by construction). The encoder-boundary conditioner is the
same code, so the handoff is idempotent. Nothing to change.

### Scheme 4 — Private prediction / reflection transitions — REJECTED (no state exists)

The parent listed this as a candidate; the re-audit is conclusive.
`DTSXPrivateFrameEncoder.selectPrediction` in the delivery mode
(`terminalRiceOfficial`) returns the coded planes directly with
`adaptiveOrders = [0,0,0,0]`, `fixedOrders = [0,0,0,0]`, and empty
reflection-coefficient sets — for **every plane of every frame**, active or
zero. There is no adaptive/fixed order change, no reflection coefficient,
and no predictor memory anywhere in delivery output; the whole-programme
timeline confirms constant order-0 declarations and constant branch 0, and
the window census shows the constant 10-byte prediction boundary on every
navigated frame (the single 9→10 "transition" at window entry is the
code-16 silence template's own fixed boundary, corpus-attested). A
transition fix has no object to act on.

### Scheme 5 — Public XLL residual/scale/hierarchy vs height onsets — REJECTED (pinned by throwing guards)

Delivery public XLL cannot escape the official constants: hierarchy
coefficient deviations from constant matrix code 473 throw, primary
residual-mask deviations from the corpus-constant 0x00 throw, the
mid-stream partition search is restricted to 2×256, and zero public planes
already take the compact linear-0 form (`terminalRiceMode` preserves it).
This branch's census: public partition constant 2×256 mid-stream, maximum
public unary quotient 22 at the official bound and never over,
`scaleCodesMatchOfficialConstant=true`, `recoveryClipSampleCount=0`,
`isRecoverySafe=true` over all 16,562 AUs.

### Scheme 6 — ExSS / asset-descriptor / presentation seam — REJECTED (no evidence)

Constant 40-byte ExSS headers and 23-byte asset descriptors across the
whole surrogate programme; `exssAssetDescriptorClosesXLLFrame=true` on
every frame and `allDTSXAssetDescriptorsMatchPrivateFrames` enforced in
integrated verification. The brief admits this scheme only with evidence;
there is none.

### Scheme 7 — NAVI 11/13/14 width ladder re-land — REJECTED (hardware-failed, forbidden)

PR #20/#22 invented a four-data-byte 13-bit serialization and pinned an
`[11, 13, 14]` ladder; hardware rendered both tips categorically worse.
Forbidden by the brief; recorded so no future agent re-lands it. This
branch keeps PR #26's opposite move (removing the invented width 12) and
the census proves the windows now hold constant width 11.

### Scheme 8 — Heuristic onset ramps — REJECTED (hardware-worsened, forbidden)

Every renderer-side onset-shaping attempt measurably increased pops, and
official renders deliver hot programme heads unfaded. Forbidden by the
brief. (The prior run's *entropy* scheme 8 — whether official encoders
Rice-code a zero plane beside dense planes instead of the current
per-channel linear-0 — remains a **corpus-blocked binary**, listed in the
deferred table below with its one-command decision.)

### Scheme 9 — Further NAVI width / silence form issues — census shows none; the actionable remainder landed (commit `ecf4f3f`)

The brief marks this "candidate if census shows". The census (above) shows
**no** remaining width or form defect: widths constant 11 across every
navigated window frame, both window-margin silence classes on their
recovered templates, zero parse failures under both this branch's parser
and the integrated tip's parser semantics, and every varying field
content-driven. What the census hunt *did* expose is operational: the
reference-stream gate — the tool that must arbitrate every deferred scheme
the moment materials land — only matched the **legacy** file names, while
the parent's protocol now requires **stamped** names. A completed stamped
upload would have left `verify-reference-streams` red and the census
playbooks pointing at nonexistent paths. Landed: each gate role resolves
the newest stamped variant (`tbh_<STAMP>.dtshd`, stamp `YYYYMMDDTHHMMZ`)
with the legacy name as fallback, reports `resolvedFileName` + `stamp` per
role, reports the `UPLOAD_MANIFEST_<STAMP>.txt` without letting it block
completion, and keeps the canonical Nature's Fury SHA-256 identity check.
Verified against synthetic directories: stamped-complete → `COMPLETE`
(newest stamp wins over an older duplicate), legacy-complete → `COMPLETE`,
partial-stamped → `PARENT_UPLOAD_REQUIRED` naming exactly the missing
roles, empty → red as before.

## 择优 rationale (why scheme 1, with scheme 9's gate remainder, and nothing else)

1. **Scheme 1 is the only implementable real fix whose absence blocks the
   defect loop itself.** Hardware closed PR #26; the next hardware verdict
   needs encodes; encodes were impossible. It is locally provable end to
   end and carries zero grammar risk.
2. **The window grammar has no locally decidable repair left.** This run
   re-proved it with a field-complete sweep rather than asserting it:
   after PR #25 + #26, every declaration inside the windows is on its
   observed corpus form and constant per class. Landing any further
   grammar mutation today would mean shipping a locally unattestable form
   — exactly the ladder pattern the brief forbids (schemes 7/8), or
   flipping a corpus-blocked binary against the evidence direction
   (deferred table below).
3. **The gate remainder is the highest-value safe action for the blocked
   schemes**: it converts the (mandatory, still-open) PARENT_UPLOAD
   escalation from "red forever until someone edits the gate" into
   "verifiable the moment files land, under the names the parent already
   mandated".
4. Schemes 2–6 are re-audited clean or pinned on this branch's own build
   and census; 7–8 are hardware-burned and forbidden. All verdicts are
   recorded so no future agent re-lands burned grammar.

## Deferred corpus-blocked binaries (unchanged, each one command once uploads land)

| Question | Current delivery form | Decides it |
| --- | --- | --- |
| Zero plane beside dense planes: per-channel linear-0 or Rice-0 runs? | linear-0 (corpus-attested zero declaration; Rice runs attested nowhere) | `analyze-dtsx-pop-windows tbh_<STAMP>.dtshd …` per-plane declarations |
| Dense-segment ABIT estimator: zigzag-mapped mean vs raw-magnitude mean | official mean-magnitude + bounded-unary raise | per-segment ABIT census beside byte counts on `tbh_<STAMP>.dtshd` |
| Mid-stream entropy state reuse (`bUseSegStateCodeParm=1`) on stable runs | 0 everywhere (early-programme verifier classifies reuse research-only) | same census |
| Render-guard engagement over the real master's windows | guard transparent on surrogate (in headroom) | `render(iab:guardReport:)` over `QWER_TBH_IAB_<STAMP>.mxf` mapped ranges |

## Verification record (this branch, Swift 6.0.3-RELEASE, Ubuntu 24.04, `swiftc -O -D DEBUG`)

All repository sources with the untracked one-line Linux `main.swift` shim
(the tracked `main.swift`/`HDMAXFramework.swift` are the macOS `@objc`
bridge).

### Encoder-path identity (no-regression proof by construction)

`git diff c3ccbdf..HEAD -- Swift_DTSHDMAX` touches exactly two files:
`DTSObjects/AtmosMasterReader.swift` (input resolution; runs before any
rendering) and `DTSValidation/DTSXReferenceStreamGate.swift` (validation
gate; never in an encode path). Every encoded HDMA/Core/DTS:X byte is
therefore identical to the integrated PR #26 tip for identical inputs; the
TBH-length surrogate encode reproduces the expected 40,080,172-byte stream
with integrated closed-loop verification green.

### Native gates — 29/29 PASS on this build

```text
verify-dtsx-native-encoder    PASS  isVerified=true, deterministic=true, and
                                    every terminal check green (startup
                                    transitions, hot start, bed-only
                                    programme timeline, early programme,
                                    render guard, gain smoothing, recovery)
verify-xllx-native-encoder    PASS
verify-dtsx-render-guard      PASS
verify-dtsx-render-startup    PASS
verify-hdma 5.1 / 7.1         PASS  (isBitExact=true both)
verify-core-syntax            PASS  (channel-walk control encode)
test_X closed loops           11/11 verify-dtsx-714-native
                                    isBitExactSevenOneFour=true,
                                    totalMismatchCount=0
                              11/11 verify-dtsx-private-heights-native PASS
```

### TBH-length pop-window surrogate

```text
encode      16,562 stream AUs, isVerified=true, SHA-256 93e177d5aa93…
census      widths 11×258 / 11×469 (constant), 0 parse failures,
            silence forms conformant, transitions 331/594
recovery    verify-dtsx-recovery-window isRecoverySafe=true,
            recoveryClipSampleCount=0, scaleCodesMatchOfficialConstant=true
timeline    field-complete sweep: all in-window variation content-driven
            (mask, segment sizes, ABIT position, ×4-closure trailing bytes)
```

### DAMF fallback fixtures

Cases A–E as tabulated above, including a full `hdmax -i Test_.atmos -o
out.dtshd` automatic encode over the WAVE fallback
(`verify-dtsx isStructurallyValid=true`, 96/96 private frames matched) and
the stderr substitution note in every fallback case.

### Reference gate

Synthetic stamped/legacy/partial/empty directories as tabulated in scheme
9; the in-repo (empty) directory still exits 1 with PARENT_UPLOAD_REQUIRED.

## One-command playbook once the uploads land

```bash
# Presence + SHA-256 gate — now resolves the stamped names automatically
hdmax verify-reference-streams

# Which forms does official TBH use inside the windows (decides all three
# deferred entropy binaries)?
hdmax analyze-dtsx-pop-windows cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd \
  tbh-windows.json 00:00:21:06-00:00:24:00 00:02:51:00-00:02:56:00

# Field-level diff of this branch's re-encode against the reference
hdmax compare-dtsx-grammar-timelines REFERENCE.dtshd CANDIDATE.dtshd

# Render-stage window audit once QWER_TBH_IAB_<STAMP>.mxf lands
#   render(iab:guardReport:) over the mapped sample ranges

# Nature's Fury encode itself is unblocked by this branch:
hdmax -i ".../Dolby_NaturesFury_DAMF/Dolby_NaturesFury_.atmos" -o Dolby_NaturesFury.dtshd
```

Material stamp status: **PARENT_UPLOAD_REQUIRED** (checked at run start
2026-08-28T01:36Z against materials tip `c587ccc`; re-checked before this
document landed, 2026-08-28T02:13Z: still only `README.md`,
`UPLOAD_BLOCKED.md`, `WHERE_TO_PUT_ENCODES.md` — zero `*.dtshd`/`*.mxf`
and no `UPLOAD_MANIFEST_*.txt`). English commits. ffmpeg was not used
anywhere. Model: `claude-fable-5-thinking-xhigh`.
