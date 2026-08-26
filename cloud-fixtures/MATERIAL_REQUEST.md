# Material request (parent ↔ cloud agents)

## Available on this materials branch (`cursor/cloud-materials-3541`)

| Path | Contents |
| --- | --- |
| `cloud-fixtures/test_X/pcm-sources/` | Controllable 7.1.4 PCM vectors (ALL_MUTE, ALL_SINE, CHANNEL_WALK, FRAME_EDGE, FULLSCALE, …) |
| `cloud-fixtures/perfect-stream-grammar/` | Nature’s Fury grammar notes + MANIFEST |
| `cloud-fixtures/PROJECT_MEMORY.md` | Project handoff memory |
| `docs/reference-streams/DTSX/` | Reference-stream staging docs (binaries not included) |

## Missing — parent must upload to GitHub (do not silent-pass)

Cloud VMs cannot mount Louis’s Mac. These official/perfect streams are required for byte-level regression and are **not** in the repo:

| Role | Local path (Louis Mac) | Stage under |
| --- | --- | --- |
| Nature’s Fury perfect / playable ref | `/Users/sunyun_louis/Downloads/Dolby_NaturesFury.dtshd` or Research BD copy | `cloud-fixtures/reference-streams/Dolby_NaturesFury.dtshd` |
| TBH encode under test | `/Users/sunyun_louis/Downloads/tbh.dtshd` | `cloud-fixtures/reference-streams/tbh.dtshd` |
| TBH official perfect stream | `/Volumes/HP_SSD_FX900_Pro /TBH/TBH_offical.dtshd` | `cloud-fixtures/reference-streams/TBH_offical.dtshd` |

If a feature agent cannot find these files after fetching this materials branch, it must **report back to the parent agent** with an explicit upload request rather than claiming byte-exact official regression without the binaries.
