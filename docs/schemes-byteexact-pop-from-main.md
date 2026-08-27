# Byte-exact pop reinvestigation from `main` — scheme selection

Branch: `cursor/dtsx-byteexact-pop-from-main-3541` (off `origin/main` @ `08b4478` only).
Task: the residual DTS:X 爆音 (Atmos-master object onsets in the first few
programme frames plus fast channel switches) that survives every landed fix,
after **hardware rejected both NAVI-ladder tip branches**. Louis's directive
for this run: prior locus wording may be wrong — prefer **byte-level
comparison against the perfect / encode-debug streams** and a full traversal
of unsafe encode paths over another narrative-locus grammar mutation.

## PARENT_UPLOAD_REQUIRED — reference encodes still missing (no silent pass)

`git fetch origin cursor/cloud-materials-3541` carries **no**
`cloud-fixtures/reference-streams/*.dtshd`. The Mac-side encodes Louis named
are still required before any byte-exact perfect-stream verification can be
claimed:

```text
/Users/sunyun_louis/Downloads/tbh.dtshd               → cloud-fixtures/reference-streams/tbh.dtshd
/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd → cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd
(optional) /Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd → cloud-fixtures/reference-streams/TBH_offical.dtshd
```

Mac-side push commands are in
`cloud-fixtures/reference-streams/WHERE_TO_PUT_ENCODES.md` on the materials
branch. The canonical perfect Nature's Fury delivery stream hashes to SHA-256
`aac7ab3d927174b1414e008d41bcfcdafbbf18428836058ce2b8cf2e0db0d1c6`
(published in `DTSXReferenceSetVerifier`); the new `verify-reference-streams`
gate on this branch checks that hash automatically the moment a binary lands.
This run validates with the in-repo controlled vectors
(`cloud-fixtures/test_X/`, `encode-dtsx-control`) and the recovered
perfect-stream grammar notes only. **No reference bitstream was invented and
no check silently passed for lack of input.** ffmpeg is never used as an
acceptance decoder.

## Hardware rejection record (must not be re-applied)

`cursor/dtsx-xllx-atmos-object-pop-3541` (PR #20) and
`cursor/dtsx-atmos-master-object-onset-3541` (PR #22) both carry commit
"Pin delivery XLL-X NAVI widths to the official 11/13/14-bit ladder"
(`3525484` / `6801216`): dense two-segment private frames were moved from the
12-bit three-data-byte NAVI word to a 13-bit **four-data-byte** word. Louis's
hardware rendered **both branches completely wrong** — a categorically worse
failure than the residual pops on `main`. Two conclusions are recorded as
evidence, not speculation:

1. The "official 11/13/14 ladder" recovery was wrong, or the four-data-byte
   13/14-bit serialization this codebase derives for it does not exist on
   real terminals. A bounded reader that consumes a fixed five-byte
   (three-data-byte + CRC16) two-segment NAVI — exactly the shape of this
   repo's own legacy two-segment parser, which accepts widths 8–12 only —
   would shift every downstream byte of every active frame by one and
   misparse the entire programme, which is precisely "renders completely
   wrong".
2. `main`'s 12-bit words are therefore not individually unreadable (steady
   dense content plays on `main`; only onsets/switches pop), so NAVI width
   selection is **not** the pop mechanism. The ladder hypothesis is dead in
   both directions.

## Traversal of unsafe encode paths on `main` @ `08b4478`

Complete walk of the delivery pipeline (`DTSXNativeHDMAEncoder` →
`DTSHDMAEncoder`/`XLLEncoder` public bed → `DTSXPrivateStreamEncodingSession`
→ `DTSXPrivateFrameEncoder` private XLL-X → `ExSSWriter` packaging), keyed on
what can still differ between an onset/fast-switch access unit and a steady
active access unit:

| Path | State on `main` | Onset-variant behaviour | Residual risk |
| --- | --- | --- | --- |
| Public XLL partition | `terminalOfficialRice` searches **only 2×256**; 4×128 reachable solely through the frame-indexed fully-silent-start override | none (pinned) | closed |
| Public XLL entropy | official Rice, unary ≤ 22 gate, research syntax gated | ABIT tracks content | corpus ABIT estimator unverified at onset boundaries |
| Private silence forms | frame-indexed compact/no-NAVI timeline, bed-audible zero-height AUs carry navigated frames (landed in `08b4478`) | silence form → navigated active transition at onset | grammar of the **first navigated active frame** after a silence form is unverified against the corpus |
| Private NAVI | width candidates canonical-11-then-minimum (8–12 emitted in practice, three data bytes); trailing 2–7 bytes first-fit for 32-bit closure | width 11↔12 follows segment sizes; trailing count re-fits per frame | width ruled out by hardware (above); trailing-count schedule unverified |
| Private entropy | branch-0, fixed-order-zero, straight Rice, mean-magnitude ABIT raised to unary ≤ 22; silent planes inside active frames Rice-coded at ABIT 0; `ncSegType`=0 and `bUseSegStateCodeParm`=0 always | ABIT jumps 0→~20 per plane at onset; zero planes carry 256 unary terminator bits per segment | zero-plane coding form, ABIT estimator variant, and state-reuse declarations unverified against corpus |
| Private prediction | fixed-order-zero everywhere (adaptive orders gated to zero at finalize) | none (constant) | closed for delivery profile |
| Private routing | constant `[1,0,3,2]` branch-0 ten-bit code on every frame | none (constant) | closed (matches "stable routing word" grammar note) |
| Atmos→7.1.4 render/gain | `DTS714Renderer` + `DTS714ObjectGainSmoother`; onset conditioning at the encoder boundary was hardware-tested and **increased** pops, then reverted | smoother slews at onsets | closed as a *fix direction* by prior hardware evidence; bed built from the same planes is clean, so rendered PCM is not the breaking layer |
| ExSS packaging | header 40 B, asset descriptor 23 B, `xllXByteOffset + xllXFrameByteCount == xllByteCount` enforced per frame on every verified encode | private frame grows ~50× in one AU | closed (audited per frame, including onset AUs) |

Every open cell above shares one property: it cannot be closed with local
round-trip evidence. Our own decoder accepts all of these forms bit-exactly;
only the perfect / encode-debug corpus can say which form terminals key on.
That is the definition of this task's blocking dependency, and why the chosen
scheme is the one that converts those binaries into field-level answers the
moment they land.

## Schemes considered (7 distinct mechanisms; ≥5 required)

### Scheme 1 — Whole-programme onset grammar timeline + grammar differential + reference-stream upload gate ← 择优

- **Mechanism.** Three native tools, zero delivery-byte changes:
  1. `export-dtsx-grammar-timeline INPUT.dtshd OUTPUT.json` — per-access-unit
     census over the **whole programme** (not just the ~10 s startup/end
     windows the early-programme gate audits) of every declaration a terminal
     actually reads: public partition and NAVI sizes, research-syntax flags,
     maximum Rice unary quotients, private silence-form class, private NAVI
     width/segment-bytes/trailing count, per-segment per-channel entropy mode
     + ABIT + `ncSegType`/`bUseSegStateCodeParm`, prediction orders,
     routing word, ExSS descriptor closure — plus **height-activity onset
     annotations** (per-plane activity mask, transition and onset access-unit
     lists), i.e. exactly Louis's "special semantics at XLL-X-active
     positions" probe. Parse failures are recorded per frame instead of
     aborting, so the tool can survey official streams whose grammar our
     strict paths reject — those very frames are the finding.
  2. `compare-dtsx-grammar-timelines BASELINE.dtshd CANDIDATE.dtshd` —
     field-level differential of two timelines at aligned access units, with
     mismatches at height-onset positions called out first. Complements the
     existing byte-level `diff-dtshd` by naming the declaration that
     diverges rather than the byte offset.
  3. `verify-reference-streams [DIR]` — gates
     `cloud-fixtures/reference-streams/`: per-file presence, byte count,
     SHA-256 (auto-recognizing the canonical perfect Nature's Fury hash),
     and a machine-readable `PARENT_UPLOAD_REQUIRED` status with a **nonzero
     exit** while required binaries are missing. Missing binaries become an
     explicit red gate instead of a silently skipped comparison.
- **Risk.** None to playback: no encoder byte changes, so HDMA + Core output
  is byte-identical by construction and cannot regress. The only risk is
  inspection-side (a wrong census), bounded by reusing the already-verified
  parsers (`XLLPBRStreamReader`, `XLLDecoder`, `DTSXPrivateFrameAST`,
  `DTSXPrivateFrameDecoder`) and by cross-checking the exported timeline of
  controlled encodes against the early-programme verifier's independent
  audit of the same streams.
- **Validation without ffmpeg.** (a) Byte-identity of `encode-dtsx-control`
  and HDMA outputs against `main` (SHA-256). (b) Existing native gates stay
  green: `verify-xllx-native-encoder`, `verify-dtsx-native-encoder`,
  `verify-hdma`, `verify-core-syntax`, `verify-dtsx-early-programme`.
  (c) New-tool self-consistency on controlled vectors: onset annotations of
  an `impulse:CHANNEL`/`channel-walk` encode must land on the constructed
  onset access units; silence-form/partition timelines must agree with the
  early-programme report on the same stream; a timeline compared against
  itself must report zero mismatches. (d) `verify-reference-streams` must
  fail red on this VM (binaries absent) — that failure is the honest,
  expected result and the escalation artifact.

### Scheme 2 — Pin delivery two-segment NAVI widths to the official 11/13/14 ladder — REJECTED (hardware-failed)

- **Mechanism.** As shipped on PR #20/#22: restrict two-segment delivery
  NAVI widths to `[11, 13, 14]`, moving the 2,049–4,096-byte segment range
  from 12-bit three-data-byte words to 13-bit four-data-byte words.
- **Result.** Louis's hardware rendered both tip branches **completely
  wrong**. Recorded above; the mechanism, its serialization model, and the
  underlying ladder recovery are all invalidated. Documented here only as a
  failed experiment per the parent's instruction; **must not be re-applied**.

### Scheme 3 — Renderer-side object-onset conditioning (gain ramps from silence, softer retarget slew) — REJECTED (prior hardware evidence)

- **Mechanism.** Reshape rendered height PCM at onsets: start
  `DTS714ObjectGainSmoother` from digital silence, lengthen slew for fast
  retargets, so onsets reach the private encoder pre-softened.
- **Risk / result.** The `beginFromSilence` and plane-level onset
  conditioning variants were hardware-tested earlier and **increased** pops
  (recorded in renderer/source-guard comments on `main`). Official renders
  deliver hot programme heads unfaded, so this reshapes programme audio away
  from reference behaviour; the clean public bed folded from the *same*
  planes already proves the rendered PCM is not the breaking layer. Rejected
  — heuristic ramps are explicitly excluded by the parent's directive.

### Scheme 4 — Encode all-zero planes inside navigated active frames as linear width-0 instead of ABIT-0 Rice — DEFERRED (needs corpus)

- **Mechanism.** At a channel-switch access unit, `main` Rice-codes each
  silent plane at ABIT 0 (256 unary terminator bits per segment). The
  recovered compact silence forms use the linear zero-width declaration
  (`0x80 0x00 0x40` shape, zero bits per sample) instead. If official
  *active* frames also declare silent planes linear-zero, our Rice-0 form is
  an off-corpus grammar sitting on exactly the fast-switch frames.
- **Risk.** High without evidence: this is the same class of unverifiable
  grammar mutation that produced the ladder failure. Both forms round-trip
  bit-exactly locally, so local gates cannot choose between them.
- **Validation.** One `export-dtsx-grammar-timeline` run over
  `tbh.dtshd`/`Dolby_NaturesFury.dtshd` (blocked, PARENT_UPLOAD_REQUIRED)
  answers this definitively: the per-channel entropy-mode census at active
  frames with silent planes either shows `riceCoding: false` + allocation 0
  (linear-zero) or ABIT-0 Rice. Deferred until the binaries land.

### Scheme 5 — ABIT estimator refinement (zigzag-mapped mean vs raw-magnitude mean; onset-boundary behaviour) — DEFERRED (needs corpus)

- **Mechanism.** `initialRiceParameter` estimates ABIT from the bit width of
  the mean **absolute magnitude**; the writer maps samples through zigzag
  (≈2× magnitude) before Rice coding. If the official estimator keys on the
  mapped mean, every dense segment's ABIT shifts by ~1, changing every
  active-frame payload — largest effect exactly at onsets where ABIT jumps
  from 0.
- **Risk.** Medium-high: perturbs every active frame; unverifiable locally
  (any consistent ABIT decodes bit-exactly; only the unary-quotient bound
  discriminates, and both variants can satisfy it).
- **Validation.** The timeline export emits per-segment ABIT alongside
  segment byte counts; regressing the corpus ABITs against decoded residual
  statistics (via the existing official-inverse verifier) selects the
  estimator. Blocked on the same binaries. Deferred.

### Scheme 6 — Entropy-state reuse / common-parameter declarations on stable active runs — DEFERRED (needs corpus, currently contradicts a landed gate)

- **Mechanism.** `main` never emits `bUseSegStateCodeParm = 1` or
  `ncSegType = 1`; every segment re-declares per-channel parameters. If the
  official corpus reuses state on steady content, a terminal could treat
  perpetual re-declaration as a per-segment reconfiguration — plausible for
  switch-adjacent frames.
- **Risk.** High: the early-programme verifier's rule 4 currently classifies
  state reuse as research-only syntax (recovered from priming-frame
  failures). Emitting it on delivery frames contradicts a landed,
  hardware-motivated gate; only corpus evidence can arbitrate.
- **Validation.** The timeline census counts `reusesPreviousParameters` /
  `commonParameters` per official stream directly. Blocked on binaries.
  Deferred.

### Scheme 7 — Fabricate a bridge/transition private frame at the silence→active seam — REJECTED (fabricates grammar)

- **Mechanism.** Emit a state-establishing transitional form (forced-minimal
  ABIT, re-declaration frame, or content split) on the first active access
  unit after a silence-form run.
- **Risk.** The recovered corpus shows ordinary navigated active frames
  immediately following silence forms; no bridge form exists to copy.
  Inventing one is exactly the defect class already burned twice (misplaced
  silence forms; NAVI ladder). Rejected.

## 择优 rationale

Scheme 1 is chosen because:

1. It is the only scheme whose correctness is **decidable on this VM
   today**: every other candidate (4, 5, 6) mutates delivery grammar in a
   way local round-trips cannot arbitrate — the exact epistemic trap that
   produced two hardware-rejected branches. The parent's directive for this
   run ("prefer byte-level comparison vs perfect / encode-debug streams")
   names scheme 1's deliverable, not another mutation.
2. It cannot regress the OK HDMA + Core encodes: no delivery byte changes;
   byte-identity against `main` is part of its own validation.
3. It converts the PARENT_UPLOAD_REQUIRED blocker from a prose escalation
   into a red native gate (`verify-reference-streams`), and converts schemes
   4–6 from speculation into single-command, field-level corpus queries the
   moment Louis's binaries land — including the official answer at exactly
   the XLL-X onset positions the hardware flags.
4. The rejected schemes (2, 3, 7) are recorded with their hardware verdicts
   so no future agent re-lands them.

## Verification record (this branch, Swift 6.0.3, Linux Debug CLI)

Toolchain: `swiftc -O -D DEBUG` over all repository sources on Ubuntu 24.04
(Swift 6.0.3-RELEASE). The `@objc` framework bridge (`HDMAXFramework.swift` /
`main.swift`) is macOS-only; the Linux build substitutes an untracked
one-line `main.swift` shim that calls `DTSHDMACommandLine.run` directly. No
tracked source differs from what a macOS Xcode build compiles.

### Byte-identity against `main` @ `08b4478` (no-regression proof)

`main` was built from a clean worktree at `08b4478` with the identical
toolchain and flags. Every delivery encode compared SHA-256-identical:

```text
encode-dtsx-control channel-walk  96 AU  06b53fc853806ad2bae32d10700986171dfdd3ae9298e4d51820c0a850e8ff04  IDENTICAL
encode-dtsx-control impulse:Lfh   96 AU  cb35af91b0956bccc8d02dd7ab483fa291d4d0d7fa856f56ec443de33bdda96c  IDENTICAL
encode-dtsx-control silence       96 AU  96b5a1a858f2de9a973563789481a7fe7bef167f70122bc6be8d6cf66adecc23  IDENTICAL
encode-dtsx-control all-sine      96 AU  986d53209bb1dd4e2e6b27fe4cafc45d43eaa596ac2dd746cf24e811401f9484  IDENTICAL
encode-hdma 5.1 (generated, 96)          666a9b6152601e08a4e1b95c2e6a722c9c430d0723881810dd99b1b7c37d94e4  IDENTICAL
```

HDMA + Core delivery is untouched by construction and now by measurement.

### Existing native gates (must stay green) — all PASS

```text
verify-xllx-native-encoder                          PASS (all cases isBitExact, CRCs valid)
verify-dtsx-native-encoder                          PASS (isVerified true; all terminal policies true;
                                                    deterministic repeat SHA 7d07502df0e1cf35...)
verify-core-syntax  (channel-walk encode)           PASS (98/98 sub-subframes synchronized)
verify-hdma         (generated 5.1, 96 frames)      PASS (isBitExact true, structure valid)
verify-dtsx-early-programme (channel-walk encode)   PASS (isEarlyProgrammeSafe true)
```

### New-tool self-consistency on controlled vectors — all PASS

1. **Onset annotations land on constructed onsets.** `channel-walk` places
   the four height feeds first, 8 access units per slot, after 2 priming AUs.
   `export-dtsx-grammar-timeline` reports `heightOnsetFrameIndices =
   [2, 10, 18, 26]` and `heightActivityTransitionFrameIndices =
   [2, 10, 18, 26, 34]` — exactly the constructed slot boundaries.
   `impulse:Lfh` (impulse in every PCM frame) reports a single onset at AU 2
   and no return-to-silence transition, matching its construction.
2. **Census agrees with the independent early-programme audit.** On the same
   channel-walk stream the timeline reports `core-priming-compact: 2` and
   `navigated-silence: 64`; `verify-dtsx-early-programme` independently
   reports `privateCorePrimingFormFrameIndices [0, 1]` and
   `privateBedAudibleZeroHeightFrameCount 64`, with identical
   `publicSegmentCounts [2]`, public unary quotient 22, private unary
   quotient 7, and identical `streamSHA256`. The silence-vector timeline
   census (`startup-no-navigation: 1`, `startup-navigated: 1`,
   `mid-stream-no-navigation: 94`) matches the frame-indexed silence
   timeline landed in `08b4478`. Zero parse failures on every export.
3. **Self-comparison is exactly zero.** `compare-dtsx-grammar-timelines
   walk walk` → `grammarIsIdentical: true`, 98/98 identical frames, no
   mismatches.
4. **Differential detects and localizes real divergence.** `walk` vs
   `impulse:Lfh` → first mismatch at AU 2 (`publicNaviSegmentByteCounts`,
   flagged `isHeightOnsetFrame: true`), onset-position mismatches called out
   at `[2, 10, 18, 26]`, 256 field mismatches recorded. The tool names the
   diverging declaration, not just a byte offset.

### Reference-stream gate — honest RED (expected)

```text
$ hdmax verify-reference-streams
error: PARENT_UPLOAD_REQUIRED: reference encodes are missing from
cloud-fixtures/reference-streams (tbh.dtshd, Dolby_NaturesFury.dtshd); ...
uploadStatus: PARENT_UPLOAD_REQUIRED   exit code 1
```

`git fetch origin cursor/cloud-materials-3541` at run time carried only
markdown briefs, grammar notes, and `test_X` PCM sources — **no `.dtshd`**.
No byte-exact perfect-stream verification is claimed. The gate exits nonzero
until `tbh.dtshd` + `Dolby_NaturesFury.dtshd` land, and auto-recognizes the
canonical perfect Nature's Fury SHA-256
`aac7ab3d927174b1414e008d41bcfcdafbbf18428836058ce2b8cf2e0db0d1c6` the moment
the binary appears. ffmpeg was not used anywhere.
