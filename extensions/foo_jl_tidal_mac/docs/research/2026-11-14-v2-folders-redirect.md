# v2 playlist folders: lost token on redirect, and the live response shape

**Date:** 2026-11-14. **Host:** foobar2000 v2.26 preview, component 0.4.0 plus the fix.
**Method:** a temporary self-test inside the component (not committed) that sent the folder requests with the stored session and ran a pull preview. Results were written to `~/Library/Logs/foobar2000/jl_tidal_sync_selftest.log` (local only). A standalone NSURLSession program with a dummy token reproduced the redirect behaviour outside foobar2000.

## Why Pull failed on every run in 0.4.0

- `kTidalAPIv2BaseURL` was `https://listen.tidal.com/v2`. listen.tidal.com now answers every path with `301` to the same path on `tidal.com`.
- **NSURLSession follows the redirect but drops the `Authorization` header** when the host changes. The request reaches tidal.com without a token: `400 {"error":"invalid_request","description":"Token is missing","subStatus":11002}`.
  - Same request with a dummy token straight to `tidal.com` or `api.tidal.com`: `401 Token is invalid`, so the header arrives there.
- Since 0.4.0, a failed folder fetch aborts the pull preview (local names embed the folder path, so planning without folders could rename foldered playlists). So every Pull stopped at the folder request.
- **Fix:** the v2 base is now `https://api.tidal.com/v2` (what python-tidal uses), and the request sends `folderId=root&includeOnly=FOLDER&limit=50`.
- **Rule for this component:** never point a request carrying a bearer token at a host that redirects. URLSession drops the header without logging anything.

## Live folder response (for the M12 rewrite)

Same shape for all three requests: no params, `folderId=root`, and `folderId=root&includeOnly=FOLDER`.
- **Top level:** `cursor`, `items`, `lastModifiedAt`, `totalNumberOfItems`.
- **Item:** `addedAt`, `data`, `itemType` (`FOLDER`, ...), `lastModifiedAt`, `name`, `parent`, `trn`. **No `type` key.**
- **`item.data` for a folder:** `createdAt`, `id`, `itemType`, `lastModifiedAt`, `name`, `totalNumberOfItems`, `trn`.
- **Counts on this account:**
  - The root listing without `includeOnly` returned 33 items, folders and playlists mixed.
  - `includeOnly=FOLDER` returned 7 items.
- **Not captured:** a playlist item's `data` keys, a nested folder, a `parent` value, and paging past 50.

`JLTidalResponseParser foldersFromItems` matches on a top-level `type` and reads `parentFolderId` and nested `items`, so it parses 0 folders from this shape. Every playlist therefore keeps the flat `TIDAL » title` name, which is what all existing local playlists already use. Fixing the parser changes local names and needs the rename migration noted in the backlog.

## Pull after the fix

- **Preview:** 93 to create (playlists plus favourite albums), 0 updates, 0 deletions.
- **Applied:** 93 playlists, 885 tracks.
- **Four favourite-album playlists are empty:** `GET /v1/albums/<id>` answers `404 Album not found` for them (checked for CZ and US), while other favourites load. TIDAL has removed those albums from its catalogue, but they are still in the favourites list.
  - `fetchAndApplyFavoriteAlbums` ignores album-track fetch errors, so Pull reports success.
  - The planner then treats the existing empty playlist as Unchanged.

## Folder mirroring, live run (2026-11-15)

Same method: a temporary self-test (not committed), with Playlist Organizer built with its outside-rename fix.
- **Folder walk:** 8 requests (the root with `includeOnly=FOLDER`, then one per folder), 7 folders, 23 playlists in folders, no subfolders, no second page. Paging and nesting are covered by unit tests only.
- **Preview:** 0 create, 20 move, 0 update, 0 delete, 73 unchanged. Every move had identical tracks (+0 -0), so each was a pure rename.
- **Apply (moves only):** each old playlist first got the TIDAL lock, to exercise the lock path. 20/20 were renamed with their item counts intact, the lock was back on every one, and the GUIDs and playlist order were unchanged (132 before and after).
- **Playlist Organizer** followed all 20 renames live: 6 folders were created under TIDAL, and the nodes moved into them. Every one of the 93 TIDAL nodes resolves to a playlist; the rest of the tree is unchanged.
- **Three foldered playlists are not pulled at all:** the 3 in folder "externals" are not in `getUserPlaylists`, the list Pull works from (presumably other users' playlists added to a folder), so that folder gets no local playlists. This is unchanged behaviour.
