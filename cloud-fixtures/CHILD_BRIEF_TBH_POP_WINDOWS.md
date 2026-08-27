# Child brief — TBH pop windows (render-path) 2026-08-27

## HARDWARE / PRODUCT
- Start from **`origin/main` @ `08b4478`** (Sunyun_Louis). HDMA + Core OK — do not break.
- **Do NOT** re-land NAVI `[11,13,14]` ladder (PR #20 / #22 HW-failed, completely wrong render).
- Optional: cherry-pick **instrumentation only** from `cursor/dtsx-byteexact-pop-from-main-3541` (PR #23) if useful for AU/field diffs — zero delivery-byte tools are OK.
- No ffmpeg. Verifiers can be green while playback pops — find unsafe implementations.
- Atmos 母带 Object ≠ DTS:X/XLL-X objects.

## Defect focus (Louis) — simpler TBH master as example
Pop-prone **timecode windows** (probe render/encode changes here):

| Window | Timecode |
| --- | --- |
| A | `00:00:21:06` – `00:00:24:00` |
| B | `00:02:51:00` – `00:02:56:00` |

Assume programme frame rate from the IAB/MXF (often 24). Convert to access-unit / render-frame indices using the master's declared rate; document the mapping in the schemes doc.

**Goal:** find what **rendering** change in these ranges causes pops (object gain/pan, bed/height mapping, silence↔active private forms, prediction/Rice seams, etc.), then fix with a perfect-stream-aligned scheme.

## Materials — fetch first
```bash
git fetch origin main cursor/cloud-materials-3541 cursor/dtsx-byteexact-pop-from-main-3541
```

| Role | Mac / volume path | Repo path after upload |
| --- | --- | --- |
| Encode-debug TBH (updates with tips) | `/Users/sunyun_louis/Downloads/tbh.dtshd` | `cloud-fixtures/reference-streams/tbh.dtshd` |
| Encode-debug NF | `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd` | `cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd` |
| **TBH Atmos/IAB master** | `/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf` | `cloud-fixtures/reference-streams/QWER_TBH_IAB.mxf` (or AU-cut if full MXF too large — document) |
| Controllable PCM | — | `cloud-fixtures/test_X/` (present) |
| Grammar notes | — | `cloud-fixtures/perfect-stream-grammar/` (present) |

If binaries missing after fetch → **PARENT_UPLOAD_REQUIRED** prominently; escalate to parent; continue with `test_X` + grammar + any available timeline tools; **no silent pass / no invented streams**.

## Process
1. New branch: **`cursor/dtsx-tbh-pop-windows-3541`** off `main` (exact name).
2. ≥5 schemes in `docs/schemes-tbh-pop-windows.md` (include rejected NAVI ladder as failed history).
3. Prefer schemes that explain **why pops cluster in the two TC windows** (render automation / object motion / height onset density / private form transitions).
4. Implement **only** 择优; list reasons.
5. Native bitstream gates; honest results; push branch for parent PR.
6. Final report: branch, schemes+择优, files, tests, model `claude-fable-5-thinking-xhigh`, PARENT_UPLOAD status.

## Parent limitation
Cloud VM cannot mount `/Users` or `/Volumes`. Louis must push encodes (+ preferably MXF or a TC-window extract covering both pop ranges with margin).
