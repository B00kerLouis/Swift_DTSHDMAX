# Segmented archive transport

The source media is stored as ordinary Git objects in 10 MiB-or-smaller
segmented gzip-tar archives. This is the transport form for the repository;
it preserves the raw payloads without relying on the unavailable Git LFS
service.

| Classification | Parts | Restore command |
| --- | --- | --- |
| Reference streams | `segmented-archives/TBH-reference-streams.tar.gz.part-000` through `...-056` | `cat segmented-archives/TBH-reference-streams.tar.gz.part-* \| tar -xzvf -` |
| Master materials | `segmented-archives/Dolby_NaturesFury_DAMF.tar.gz.part-000` through `...-045` | `cat segmented-archives/Dolby_NaturesFury_DAMF.tar.gz.part-* \| tar -xzvf -` |

Run the restore command from `docs/reference-streams/DTSX/` in an empty
destination directory. The first archive restores `QWER_TBH_IAB.mxf` and
`TBH_offical.dtshd`; the second restores the three DAMF package files.

Verify archive pieces with:

```sh
shasum -a 256 segmented-archives/*.part-*
```

Verify the restored payloads against the SHA-256 values in
[`MATERIALS.md`](MATERIALS.md).
