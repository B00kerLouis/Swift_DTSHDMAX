# PARENT_UPLOAD_REQUEST — official `.dtshd` reference binaries

**Status: BLOCKING byte-level official-stream regression.** Everything below
was searched for in this repository, in `origin/cursor/cloud-materials-3541`,
and in the cloud VM filesystem on 2026-08-26; none of it is present. The Mac
paths cannot be mounted from the cloud VM.

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
