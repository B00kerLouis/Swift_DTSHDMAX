# Child brief — TBH pop continued + macOS CI (2026-08-31T0138Z)

## Parent status
- **Abandoned forks cleaned.** Closed PR #30 (superseded). Open product tip: **PR #31** `cursor/dtsx-tbh-pop-window-fix-3541` @ `22ee754`. Materials: PR #21. Remote: `main`, materials, window-fix only.
- **Hardware pops NOT fixed** after PR #30/#31 (Louis: "经上两次PR未被修复").
- **New branch (mandatory):** **`cursor/dtsx-tbh-pop-macos-ci-3541`** off PR #31 tip. Do NOT commit on main.

## Louis task
1. Clean abandoned forks; integrate proven fixes from PR #31; **continue** TBH pop fix.
2. Pop windows (TBH IAB master):
   - `00:00:21:06`–`00:00:24:00` (stream AU ~1994–2252)
   - `00:02:51:00`–`00:02:56:00` (stream AU ~16033–16502)
3. Find **render/encode changes** in those windows causing hardware 爆音. Verifiers can pass while playback pops.
4. **No ffmpeg.** No NAVI 11/13/14 ladder. Keep HDMA+Core bit-exact on controls.
5. **≥5 schemes** in doc + report; **择优 with explicit reasons (必须列出)**; implement ONLY 择优.
6. **PARENT_UPLOAD_REQUIRED** if materials missing — escalate to parent, never silent pass.
7. **NEW MANDATORY:** After code changes, add/configure **GitHub Actions macOS build** that builds the Xcode project successfully. Confirm CI can build. Push workflow on the feature branch so Actions run on the PR.
8. Model **`claude-fable-5-thinking-xhigh`**. Max 1 concurrent child.

## Already on PR #31 (keep unless evidence)
- Rollback input = main@08b4478; corpus zero-plane; NAVI width 11; window tools; render audit gate
- Opt-in `--private-seam-mode compact|bridged-zero-gaps|sticky-rice-zero-gaps` (default byte-identical to #30)
- Census `zeroHeightSeamFormCounts`

## Investigation priorities (hardware still pops)
1. If materials arrived: grammar diff vs official `tbh_<STAMP>.dtshd` / `TBH_offical.dtshd`; decide promote bridged or sticky as default — OR reject both if official contradicts.
2. Render-side: `verify-tbh-window-render` on real IAB; ObjectGainSmoother / plane handoff / PCM discontinuities in windows.
3. Remaining encode-side unsafe paths NOT covered by opt-in seam policies (e.g. mid-gap transitions longer than 3 AU, public/private seam, ExSS, prediction — only with evidence).
4. Do NOT promote opt-in to default without hardware or official-census evidence (PR #31 scheme 4 REJECT still applies unless new evidence).

## macOS GitHub Action (required deliverable)
Repo has **no** `.github/workflows` yet. Project is Xcode:
```bash
xcodebuild \
  -project Swift_DTSHDMAX.xcodeproj \
  -scheme "Build ALL" \
  -configuration Release \
  -derivedDataPath Build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```
Targets: `cli` → `hdmax`, `Framework` → `libhdmax`. Shared schemes: `Build ALL`, `cli`, `Framework`.

Add `.github/workflows/macos-build.yml` (or similar) that:
- `runs-on: macos-latest` (or macos-14/15)
- triggers on push/PR to the feature branch (and ideally pull_request)
- builds Release with CODE_SIGNING_ALLOWED=NO
- fails the job if build fails
- Document in schemes doc that CI green is part of verification

After push, use `gh run list` / wait for Actions to confirm build succeeds (or report Actions unavailable with exact error — never silent skip).

## Materials (fetch `origin/cursor/cloud-materials-3541`)
Present: DAMF parts 000–005 only.
Missing: DAMF 006–045; entire TBH-reference-streams archive; stamped encodes.
Restore: `docs/reference-streams/DTSX/ARCHIVES.md`. Mac: `/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf`, `TBH_offical.dtshd`.

## Schemes starter (≥5; refine; 择优 reasons 必须列出)
| # | Scheme | Starter |
| --- | --- | --- |
| 1 | Promote bridged-zero-gaps to delivery default | only with HW/official evidence |
| 2 | Promote sticky-rice-zero-gaps to delivery default | only with HW/official evidence |
| 3 | Render-side discontinuity / ObjectGainSmoother in windows | candidate |
| 4 | Extend gap bridge max length / mid-stream form hysteresis | candidate if census shows |
| 5 | Public XLL / ExSS / prediction transitions | REJECT unless evidence |
| 6 | NAVI 11/13/14 ladder | REJECT forbidden |
| 7 | Onset ramps | REJECT forbidden |
| 8 | macOS GitHub Actions Release build gate | **required land** (infra, not pop hypothesis) |

## Deliverables
- Branch: **`cursor/dtsx-tbh-pop-macos-ci-3541`**
- Doc: `docs/schemes-tbh-pop-macos-ci.md` (scheme table + 择优 reasons + CI record)
- Working `.github/workflows/*` macOS build + evidence of green (or loud failure report)
- Draft PR; English commits; list files changed, tests, model slug
