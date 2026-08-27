# Child brief — roll back to main; byte-exact pop reinvestigation (2026-08-27)

## HARDWARE REJECTION (do not ignore)
Louis tested the NAVI-ladder tips. **Both tip branches render completely wrong**
(`cursor/dtsx-xllx-atmos-object-pop-3541` / PR #20 and
`cursor/dtsx-atmos-master-object-onset-3541` / PR #22).

**Mandatory:**
1. Start from **`origin/main` @ `08b4478` ONLY**.
2. Do **NOT** cherry-pick, reuse, or re-land the NAVI `[11,13,14]` ladder change as the default fix.
3. Treat the NAVI ladder as a **failed hardware experiment** (may remain as a documented rejected scheme).

## Product constraints
- HDMA + Core encode: **OK — do not break**
- Controllable vectors: `cloud-fixtures/test_X/` on materials branch
- No ffmpeg acceptance decoder
- Project verifiers can be green while playback is wrong — find unsafe implementations
- Atmos 母带 Object ≠ DTS:X / XLL-X objects — never conflate
- Prior pop-locus wording may have been misleading; **prefer byte-level perfect-stream diffs** over narrative loci

## Materials (fetch first)
```bash
git fetch origin main cursor/cloud-materials-3541
```

| Asset | Path | Status |
| --- | --- | --- |
| Controllable PCM | `cloud-fixtures/test_X/` | Present |
| Perfect-stream grammar notes | `cloud-fixtures/perfect-stream-grammar/` | Present (no binary) |
| Encode-debug TBH | `cloud-fixtures/reference-streams/tbh.dtshd` | **PARENT_UPLOAD_REQUIRED** ← Mac `/Users/sunyun_louis/Downloads/tbh.dtshd` |
| Encode-debug NF | `cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd` | **PARENT_UPLOAD_REQUIRED** ← Downloads |
| Official NF perfect (SHA-256 in grammar README) | Research / Volumes paths in MANIFEST | Usually absent on cloud |

If `*.dtshd` still missing after fetch: **escalate to parent immediately** in schemes doc + final report. Continue with grammar notes + `test_X` bitstream probes, but **do not claim byte-exact perfect-stream verification** without binaries. **No silent pass.**

## Required process
1. New branch off main: **`cursor/dtsx-byteexact-pop-from-main-3541`** (exact name).
2. Traverse private XLL-X / public XLL / Atmos→7.1.4 / delivery encoder paths for unsafe pop sources.
3. Write ≥5 distinct schemes with risk + how to validate without ffmpeg.
4. Prefer schemes that enable or prepare **byte-level comparison** vs perfect / encode-debug streams.
5. Implement **only** 择优; list 择优 reasons.
6. Run native bitstream / in-repo gates; document honestly.
7. Commit + `git push -u origin cursor/dtsx-byteexact-pop-from-main-3541`.
8. Final report: branch, schemes+择优, files, tests, model slug `claude-fable-5-thinking-xhigh`, PARENT_UPLOAD status.

## Parent note
Parent cloud VM cannot read `/Users` or `/Volumes`. Louis must push Downloads encodes to materials before true byte-exact official diffs are possible.
