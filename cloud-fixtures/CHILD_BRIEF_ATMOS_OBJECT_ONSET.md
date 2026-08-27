# Child brief — Atmos master Object onset / channel-walk pops (2026-08-27)

## Parent / main status
- `main` @ `08b4478` (Sunyun_Louis only) already contains bed-active silence gaps + delivery startup grammar.
- Former tip `cursor/dtsx-bed-active-silence-gaps-3541` was squash-landed; do not reopen it.
- Open tip `cursor/dtsx-xllx-atmos-object-pop-3541` (PR #20, `3525484`) pins private NAVI to **11/13/14** (never 12). Treat as **Scheme candidate**, not proven HW fix.

## Hardware truth (Louis)
1. Both streams **first frames OK**
2. DTS:X **爆音 volume unchanged** vs previous tip
3. Locus: **Atmos 母带 Object** in first few programme frames + fast channel switches
4. NOT DTS:X/XLL-X objects — never conflate
5. 7.1 HDMA/XLL bed OK on same downmix; defect is DTS:X private/height path
6. No ffmpeg; do not trust green verify alone

## Materials
```
git fetch origin cursor/cloud-materials-3541
# checkout or worktree that branch for fixtures only
cloud-fixtures/test_X/                      # present (~134 files)
cloud-fixtures/perfect-stream-grammar/      # present (manifest + notes, no binary)
cloud-fixtures/reference-streams/*.dtshd    # PARENT_UPLOAD_REQUIRED — missing
```
If `.dtshd` still missing after fetch: document PARENT_UPLOAD_REQUIRED and continue with test_X + grammar. Ask parent to get Louis to push Downloads encodes — **no silent pass**.

## Required process
1. Write **≥5 distinct schemes** (markdown in branch) with risk/scope.
2. Pick 择优 with explicit reasons (prefer perfect-stream-aligned grammar over heuristic ramps).
3. Implement **only** 择优 on new branch `cursor/dtsx-atmos-master-object-onset-3541` off `main` (or off tip if 择优 is “land NAVI + X”).
4. Commit + push; leave PR creation to parent ManagePullRequest if needed.
5. Report files changed, native test results, model slug used.

## Probe ask
When playback reaches regions that would contain **XLL-X height-active** content after Atmos→7.1.4 map, does the perfect-stream private grammar use special NAVI / silence / segment / Rice / prediction semantics that our encoder still violates? Prior NAVI-12 hole is one hypothesis; also audit Atmos ObjectGainSmoother / RenderGuard / private frame form transitions at first height-active AU after bed-hot silence gaps.
