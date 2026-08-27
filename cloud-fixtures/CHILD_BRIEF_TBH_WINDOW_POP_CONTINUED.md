# Child brief — continue TBH window pops after PR cleanup (2026-08-27T0908Z)

## PR cleanup (parent already did)
Closed abandoned: #20 #22 (NAVI HW-failed), #23 #24 (superseded tools), #25 (corpus-zero tip — **HW says pops remain**).

## Integrate then continue
1. Branch **`cursor/dtsx-tbh-window-pop-continued-3541`** off **`origin/main` @ `08b4478`**
2. **Integrate** useful prior tip work from `cursor/dtsx-tbh-render-unsafe-3541` @ `30e6ec3`:
   - Window tools + grammar timeline + reference gate (analysis)
   - Corpus zero-plane declaration fix (grammar-correct even if insufficient alone)
3. Then find **remaining** unsafe path that still causes pops in the TBH windows (last two tips did **not** fix hardware)

## Defect
Windows: `00:00:21:06`–`00:00:24:00`, `00:02:51:00`–`00:02:56:00`  
Hunt **render-time** changes in these ranges. No ffmpeg. No NAVI ladder re-land.

## Timestamped materials (mandatory — no silent skip)
```text
cloud-fixtures/reference-streams/tbh_<STAMP>.dtshd
cloud-fixtures/reference-streams/Dolby_NaturesFury_<STAMP>.dtshd
cloud-fixtures/reference-streams/QWER_TBH_IAB_<STAMP>.mxf
cloud-fixtures/reference-streams/UPLOAD_MANIFEST_<STAMP>.txt
```
Parent example stamp: `20260827T0908Z`. Record stamp in schemes doc. If missing → PARENT_UPLOAD_REQUIRED + escalate.

## Schemes — REQUIRED visibility
Write `docs/schemes-tbh-window-pop-continued.md` with **≥5 distinct schemes**, each with: mechanism, risk, validation without ffmpeg, accept/reject.

**Parent’s starter menu (you may refine/replace, but must list ≥5 and pick one):**
1. Integrate corpus-zero + attack **ObjectGainSmoother / pan sub-block discontinuity** at window AUs
2. Integrate + fix **RenderGuard / encoder-boundary plane handoff** on height mask flips
3. Integrate + fix **private prediction / reflection coeff** transitions when planes go zero↔active mid-window
4. Integrate + **public XLL residual / scale / hierarchy** interaction with height onsets in windows
5. Integrate + **ExSS / asset descriptor / presentation** seam only if evidence
6. (Reject) NAVI 11/13/14 ladder — HW-failed
7. (Reject) Heuristic onset ramps — HW-worsened

**择优 must be stated with reasons in the doc AND final report.** Parent will surface the list to Louis.

## Deliverables
Implement ONLY 择优; push branch; report files, tests, model `claude-fable-5-thinking-xhigh`, material stamp / PARENT_UPLOAD.
