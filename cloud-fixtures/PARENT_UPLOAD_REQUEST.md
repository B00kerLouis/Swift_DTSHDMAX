# PARENT_UPLOAD_REQUEST — official `.dtshd` reference binaries

**Status: BLOCKING byte-level official-stream regression.** Everything below
was searched for in this repository, in `origin/cursor/cloud-materials-3541`,
and in the cloud VM filesystem on 2026-08-26; none of it is present. The Mac
paths cannot be mounted from the cloud VM.

**Re-verified 2026-08-26 (object-onset-pop run, branch
`cursor/dtsx-object-onset-pop-3541`):** the tip of
`origin/cursor/cloud-materials-3541` (`f8a4543`) still carries only
`cloud-fixtures/reference-streams/README.md` — `tbh.dtshd`,
`Dolby_NaturesFury.dtshd`, and `TBH_offical.dtshd` remain un-uploaded, so the
**requested bitstream inspection of Louis's new software encodes**
(declarations, early ~10 s access units, private/public activity at
object-like height onsets) is impossible and official-stream regression is
still **PARENT_UPLOAD_REQUIRED**. The onset analysis that specifically needs
them now:

1. Whether official hot-start encodes shape the height/object layer at the
   programme head (an onset envelope in the first ~0.5–1 s) — this run ships
   a controllable-vector-proven head ramp + onset slew
   (`docs/dtsx-object-onset-pop-schemes.md`, `verify-dtsx-onset-guard`), but
   the official constant cannot be confirmed without the binaries.
2. Whether the official private grammar pre-arms (active-form zero AU before
   a height onset) or switches silence→active on the onset AU itself —
   decides scheme O4.
3. The official calibration of the new recovery-handoff divergence metrics
   (`verify-dtsx-recovery-window`: `maximumHandoffBoundaryResidual`,
   `firstSourceAccessUnitMaximumResidual`) on tbh and Nature's Fury — decides
   whether scheme O5 (Core margin) is worth its risk.

**Re-verified 2026-08-26 (Atmos-object onset run, branch
`cursor/dtsx-atmos-object-onset-3541`):** `cloud-fixtures/reference-streams/`
on `origin/cursor/cloud-materials-3541` (`c33adac`) still carries only
`README.md` — the binaries remain un-uploaded and official-stream regression
is still **PARENT_UPLOAD_REQUIRED**. Note for the O1/O2 questions below:
hardware answered question 1 empirically - the delivery-boundary head
ramp/onset slews made the pops **worse** and have been removed
(`docs/dtsx-atmos-object-onset-schemes.md`); the binaries are still needed to
(a) confirm whether the official renderer's programme-start gain state slews
from silence (scheme A2, now shipped render-side), (b) decide the deferred
startup-grammar scheme A6, and (c) calibrate the recovery-handoff divergence
metrics that remain report-only.

**Re-verified 2026-08-26 (five-scheme object-safety run):**
`cloud-fixtures/reference-streams/` on `origin/cursor/cloud-materials-3541`
still contains only `README.md` — `tbh.dtshd`, `Dolby_NaturesFury.dtshd`, and
`TBH_offical.dtshd` remain un-uploaded, so official-stream regression is still
reported as **PARENT_UPLOAD_REQUIRED**. Everything provable without them is
now green on this VM with controllable vectors: the encoder-boundary source
guard keeps raw hot 7.1.4 planes inside every corpus invariant
(`verify-dtsx-render-guard`: zero fold hard clips, zero deviating hierarchy
frames, negative-control bypass still exhibits the defect), and the
early-programme declaration audit passes on silent-start, 10-second hot-sine,
full-scale, channel-walk, and staged `test_X` stem encodes
(`verify-dtsx-early-programme`: `isEarlyProgrammeSafe` true on every stream,
unary quotients at most 10 against the corpus ceiling of 22). See
`docs/dtsx-active-start-safety-schemes.md` for the scheme selection this
verifies.

## Files needed

Please upload these exact files to GitHub under
`cloud-fixtures/reference-streams/` (Git LFS or plain blobs both work; if the
full programmes are too large, the **first 15 seconds** of each stream cut at
an access-unit boundary is enough for the startup-window regression):

| # | Source path on Louis's Mac | Purpose |
|---|---|---|
| 1 | `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd` | Silent-start official reference. Byte/declaration regression of the 2x256 -> 4x128 -> 2x256 startup transition and the mid-stream Rice grammar our encoder is modeled on. |
| 2 | `/Users/sunyun_louis/Downloads/tbh.dtshd` | Active/object-start official reference. The only ground truth for the "first ~10 seconds" window: needed to byte/declaration-diff the first ~960 access units against our encode and to read the official Rice parameter choices on hot content. |
| 3 | `/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd` | Second TBH master (official authoring). Cross-check of #2 and of the official encoder's segmentation and unary-quotient ceiling on active starts. |

If a PCM master (`.wav`/`.caf` 7.1.4) of the same TBH content exists, upload it
too — it enables a true product-vs-perfect byte regression (encode the same
master, diff the streams) instead of grammar-level comparison only.

## Why they are needed

This branch fixes the early-programme failures using recovered grammar rules
and controllable vectors:

- Public XLL and private XLL-X Rice unary quotients are now bounded at the
  official-corpus maximum (22); the previous tip emitted quotients up to 488
  on controlled transients, and on a 10-second transient vector violated the
  bound on **940 of 942 access units** — matching the "first ~10 seconds do
  not play + pops at every transient" hardware report.
- The silent-start 4x128 partition is no longer forced onto active-bed starts.

What cannot be verified without the official binaries:

1. That the official-corpus unary-quotient maximum really is 22 on *these two
   titles* (the constant was recovered from the previously captured corpus
   windows, not from full programmes).
2. Byte-exact / declaration-exact regression of our encode against the
   official TBH stream over the first ~10 seconds.
3. Whether official TBH uses startup syntax we have not yet modeled (e.g. a
   different priming form for active starts).

Until then, official-stream regression is reported as **PARENT_UPLOAD_REQUIRED**,
not as passed.

## How they will be used once uploaded

```
hdmax verify-dtsx-early-programme cloud-fixtures/reference-streams/tbh.dtshd
hdmax verify-dtsx-early-programme cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd
```

plus AU-window declaration diffs against our controlled encodes. The
early-programme verifier already reports the exact maximum unary quotient and
partition sequence of any stream, so validating the recovered constants
against the official titles is a single command each.
