# Child brief — TBH pop window fix continued (2026-08-28T09:55Z)

## Parent status
- **Abandoned forks cleaned.** Remote branches remaining: `main`, `cursor/cloud-materials-3541` (#21), `cursor/dtsx-tbh-pop-rollback-restore-3541` (#30).
- **Product base:** **`cursor/dtsx-tbh-pop-rollback-restore-3541` @ `50c2f37`** (PR #30). Input stage = `main` @ `08b4478`. All gates green on surrogate; **hardware pops NOT fixed**.
- **New branch (mandatory):** **`cursor/dtsx-tbh-pop-window-fix-3541`** off PR #30 tip. Do NOT commit on main.

## Louis task
1. Integrate proven fixes already on PR #30 (do not regress input or HDMA/Core).
2. **Continue** finding render/encode changes in TBH pop windows that cause hardware 爆音:
   - `00:00:21:06`–`00:00:24:00` (stream AU ~1994–2252)
   - `00:02:51:00`–`00:02:56:00` (stream AU ~16033–16502)
3. TBH IAB master is the working example (`QWER_TBH_IAB.mxf`).
4. **No ffmpeg.** Verifiers can pass while playback pops — find unsafe implementation.
5. **≥5 schemes** in doc + parent report; **择优 with explicit reasons (必须列出)**; implement ONLY 择优.
6. **PARENT_UPLOAD_REQUIRED** if materials missing — escalate to parent, never silent pass.
7. Model **`claude-fable-5-thinking-xhigh`**. Max 1 concurrent child.

## Already integrated on PR #30 (keep unless evidence to revert)
- Grammar timeline + differential + reference gate (#23)
- Timecode-window mapping + pop-window census + motion vector (#24)
- Corpus zero-plane declaration (#25)
- Compact navigated NAVI width 11 (#26)
- Stamped reference gate names
- Window render audit gate (repaired full-scale rail check from #29)

## Deferred from PR #30 schemes doc — prioritize investigation
| # | Scheme | Status |
| --- | --- | --- |
| 10 | Silence-form run-length hysteresis | One census vs official `tbh_<STAMP>.dtshd` decides |
| 11 | ABIT 0→19 onset jumps (637 in-window on surrogate) | Corpus-blocked until reference available |
| 3 | Render audit on real IAB master | Blocked on MXF upload |
| 2 | DAMF sidecar resolution | Blocked on archive parts 006–045 |

## Forbidden
- NAVI 11/13/14 ladder (#20/#22) — hardware-failed
- Onset ramps / dither (#15/#16) — hardware-worsened
- ffmpeg anywhere
- Re-land DAMF input mutations unless archive complete AND encode validated

## Materials (fetch `origin/cursor/cloud-materials-3541`)
Present: `Dolby_NaturesFury_DAMF.tar.gz.part-000`–`005`
Missing: parts `006`–`045`, entire `TBH-reference-streams.tar.gz.part-*` (57 parts), stamped encodes in `cloud-fixtures/reference-streams/`

Restore per `docs/reference-streams/DTSX/ARCHIVES.md`. SHA-256 in `MATERIALS.md`.

Mac sources:
- TBH IAB: `/Volumes/HP_SSD_FX900_Pro /TBH/QWER_TBH_IAB.mxf`
- Official TBH encode: `/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd`

## Investigation workflow
1. Branch off PR #30 @ `50c2f37`.
2. Assemble any new materials; run `verify-reference-streams`, `analyze-dtsx-pop-windows`, `compare-dtsx-grammar-timelines`, `verify-tbh-window-render` if inputs exist.
3. Inside pop windows, diff grammar + render motion vs safe regions and vs official reference when available.
4. Land **one** 择优 encoder/renderer fix with proof; document deferred items.

## Schemes starter menu (≥5 required; refine in doc)
| # | Scheme | Starter verdict |
| --- | --- | --- |
| 1 | Silence-form hysteresis at bed-audible seams | candidate |
| 2 | ABIT / entropy-mode discontinuity at height onsets | candidate |
| 3 | Per-channel linear-0 vs shared-parameter zero beside dense planes | candidate |
| 4 | Render-window rail / render-guard engagement on real master | candidate tool + fix |
| 5 | ObjectGainSmoother / pan at object motion boundaries | REJECT if clean |
| 6 | Private prediction/reflection order transitions | REJECT if order-0 everywhere |
| 7 | NAVI 11/13/14 ladder | REJECT forbidden |
| 8 | Onset ramps | REJECT forbidden |
| 9 | ExSS / public XLL residual | REJECT unless evidence |

## Deliverables
- Branch: **`cursor/dtsx-tbh-pop-window-fix-3541`**
- Doc: `docs/schemes-tbh-pop-window-fix.md` (scheme table + 择优 reasons + verification record)
- Draft PR with test plan + PARENT_UPLOAD status
- English commits; HDMA+Core bit-exact on controls
