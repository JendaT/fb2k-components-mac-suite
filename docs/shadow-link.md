# Shadow link for a network music share

## Why

foobar2000 macOS stores files on a mounted volume as `mac-volume://<UUID>/<path>`. For SMB shares macOS hands out the UUID at mount time, so the same share can collect many UUIDs, a second mount (`/Volumes/music-1`) and a second copy of its cached metadata. See [VOLUME_UUID_ISSUE.md](VOLUME_UUID_ISSUE.md).

The shadow link removes the volume from foobar2000's view. foobar2000 stores one fixed local path, `file:///Users/<user>/Music/NAS/music/<path>`, and `~/Music/NAS/music` is a symlink that a mount agent keeps pointing at wherever the share is mounted right now. A partial local mirror with the same relative paths can later be a second target, for places without the NAS.

## What foobar2000 does with a link path (tested 2026-10/11)

- Playlists, metadb rows, both metadb index tables and the Media Library root keep the `file://` link form across restarts. Nothing is rewritten back to `mac-volume://`. Handles are created from the link string.
- Re-pointing the link (atomic swap, see below) during playback is safe.
- Tags are re-read only for files whose mtime changed, so a mirror must keep mtimes (`rsync -a`).
- The Media Library ignores a live re-point and rescans at startup. Tracks missing from a partial mirror drop out of the library and come back when the share returns, without touching their metadb rows.
- If the link target does not exist at startup (share not mounted), the library drops every track under the link. The next start with the target present re-adds them (tested 2026-11-17: 10 tracks, then 0, then 10; metadb rows kept throughout). No link target avoids this, since an empty local folder empties the library just the same. So the agent points the link at the usual mount point while unmounted, and the share has to be mounted before foobar2000 starts to keep the library filled.

## Mount agent rule

Kept outside this repo, because it carries home-network addresses.

- Decide from the mount table only. Never stat or resolve a path inside an smbfs mount: a hung share would freeze the agent.
- Share mounted: point the link at the mount point (the preferred one when duplicates exist).
- Not mounted: point it at the usual mount point (`/Volumes/<share>`), so it works again the moment the share returns.
- Swap with `ln -sh` to a temporary name in the same folder, then `rename(2)`. Not `mv -h`: BSD `mv` stats the destination through the link first, which reaches into the share.
- Never replace something at the link path that is not a symlink.

## Migration: `Scripts/shadow_link_migrate.py`

A one-time rewrite of an existing profile. Run it with foobar2000 quit.

```
shadow_link_migrate.py --dry-run --link ~/Music/NAS/music --from mac-volume://<UUID>/ [--from file:///other/prefix/]
shadow_link_migrate.py --apply   (same arguments)
shadow_link_migrate.py --check   --link ~/Music/NAS/music --from mac-volume://<UUID>/ --share-name music
shadow_link_migrate.py --rollback <profile>/shadow-link-backup-<ts>/ [--restore-config | --keep-config]
```

What it rewrites:
- **Playlists** (`playlists-v2.0/*.fplite`): the prefix at line start. The BOM and line endings are kept.
- **metadb**: `metadb.name` (`<subsong>+<location>`) and `filename` in every `metadb_index_*` table.
- **BPM beat grids** (index `4C2B7E91-…`): the key is md5(`<location>|<subsong>`) folded to 64 bits, so every rewritten row gets a new key, and its `_data` row moves with it. A grid never overwrites another one.
- **Play statistics** (index `C653739F-…`): keyed by track metadata, not path. Only `filename` changes.
- **Archives**: `unpack://<type>|<len>|<archive>|<inner>`. `<len>` counts UTF-8 bytes, verified on real rows with non-ASCII archive paths. It is recomputed at every nesting level.
- **Media Library root** (`library-v2.0/folders`): binary, u32 count, then u32 length + URL per root, then 4 trailing bytes. It is replaced by one root at the link.
- **Not touched**: config.sqlite (the volume registry; prune it separately with `volume_registry_prune.sh`), waveform caches, plorg's own state.

Safety:
- It refuses while foobar2000 runs on the live profile, while plorg's quit-time migrator is pending, or with a non-empty WAL or journal.
- Order: backup, stage everything, verify, re-check the guards and file fingerprints, then swap. A failed swap restores every item from the backup.
- Conflicts: when the link-form row already exists, it wins and the old row is deleted. Every conflict is reported.

Undo:
- `--rollback` restores metadb, the Media Library root and the playlists the migration rewrote. Other playlists are left alone.
- It warns about anything changed since the migration (play counts, playlist edits) and moves the current files aside.
- It refuses while config.sqlite differs from the backup (for example after the registry prune) until you choose `--restore-config` or `--keep-config`.

## Drift

New `mac-volume://` paths appear whenever files are added straight from `/Volumes/<share>`: Finder drops, file dialogs, downloads written there. `--check` reports them, and an `--apply --from mac-volume://<new UUID>/` at the next quit folds them in under the same conflict rule.
