# intake CLI

Release-root resolver and sidecar tooling for the intake system. Specs:
`docs/intake/intake-01-resolver-spec.md` (resolver + sidecars) and
`docs/intake/intake-03-contract-spec.md` (CLI contract — command surface,
JSON envelope, exit codes, status lifecycle, audio_hash).

Self-contained Bun package; no fb2k SDK or Xcode dependency. External tools:
`flac` (resolve: decodes FLACs whose STREAMINFO MD5 is unset), `metaflac`
(execute: provenance tags), `unzip` and `bsdtar` (archives; both ship with
macOS), optionally `7zz` or `7z` (7z, non-ASCII zip names, rar without bsdtar)
and optionally `unar` (`brew install unar`; used only for solid RAR4 archives,
which bsdtar cannot extract and which are refused without it).

## Usage

```bash
bun install

# Rules dir (income.yaml, structure.yaml, genre-map.yaml, label-map.yaml,
# styles.yaml) — real maps live in the private music-rules repo; this repo
# ships only schema docs and fixtures. A rules file with a YAML syntax error
# fails the command that loads it with E_BAD_RULES:
export INTAKE_RULES_DIR=/path/to/music-rules   # or ~/.config/intake/config.toml

bun run src/cli.ts scan --all          # discover, unpack archives, resolve
bun run src/cli.ts resolve <dir>       # (re)detect roots, write sidecars
bun run src/cli.ts identify <root>     # establish what a release is
bun run src/cli.ts assign <root>       # rank genre-collection folders
bun run src/cli.ts assign <root> --collection "[X]" --by user   # override + feedback
bun run src/cli.ts propose <root>      # identify+assign+naming -> proposed
bun run src/cli.ts approve <root>      # or --batch <file> of ids/paths
bun run src/cli.ts reject <root> --reason "<text>"   # or --batch <file>; -> rejected
bun run src/cli.ts execute --approved  # copy, tag, verify, journal, place
bun run src/cli.ts execute --resume    # crash recovery for `placing` roots
bun run src/cli.ts gc --all [--age 30] [--relocate-dj]   # or gc <root...>; verified local cleanup
bun run src/cli.ts collections         # genre map folder list (picker)
bun run src/cli.ts income              # income folders from income.yaml
bun run src/cli.ts bootstrap --tree <path> --out <dir>          # build maps
bun run src/cli.ts status --json       # sidecar inventory
bun run src/cli.ts status --filter status=placed --filter id=itk_0a1b2c3d
bun run src/cli.ts version --json      # {cli, schema, engine, commands}
```

All commands accept `--json` (single envelope on stdout) and `--dry-run`.
Exit codes: 0 ok, 1 partial, 2 error. Roots are addressed by path or
sidecar id. A command on a root in a status it does not accept reports
`E_BAD_STATUS` for that root (doc 03 "Legal source statuses"); the
all-roots forms (`propose --all-resolved`, `execute --approved`,
`execute --resume`, `gc --all`) skip such roots silently. `status --filter`
keys: `id`, `status`, `needs_review`, `income_folder`, `source_type`, `tier`
(alias `tier_eligible`), `virtual`, `singles`, `albumartist`, `album`,
`root_path`; an unknown, malformed or repeated key is `E_BAD_ARGS`. A rules
file the command loads that it cannot use (a YAML syntax error in
income.yaml, structure.yaml, genre-map.yaml, label-map.yaml or styles.yaml,
a malformed genre-map.yaml or label-map.yaml entry, or a bad
`archive_code_pages`) fails that command with `E_BAD_RULES`, exit 2, `path`
the file, the message naming the file and, where known, the key.

genre-map.yaml and label-map.yaml are rewritten whole by assign (user
feedback, learned aliases), execute (placement counts) and bootstrap; hand
comments do not survive. So their entries are checked on load, and anything
the CLI cannot represent is refused rather than dropped: an artist or label
must map to `{collection: count}` with counts that are finite numbers of 0
or more, `aliases:` values and `exceptions:` items must be strings, and each
section must have its type (`null` is refused). Such a command changes
nothing. A rewrite keeps top-level keys the CLI does not know, in place, and
keeps zero counts and empty distributions, which carry no evidence.

Identify/assign run fully offline by default; network evidence is opt-in via
`DISCOGS_TOKEN` and `LASTFM_API_KEY` (similar-artist cache under
`INTAKE_CACHE_DIR`, default `~/.cache/intake`). The exception is the beets
hard path below: once the shim finds beets, it queries MusicBrainz. Without
beets, identification degrades to `unconfirmed` and flags review.

### Archive entry names

`scan` unpacks zip, rar and 7z archives next to themselves. Zip entry names
that carry no UTF-8 flag and are not valid UTF-8, and plain (non-Unicode)
RAR4 names, are raw Windows code-page bytes, and neither format records the
code page. Intake decodes every such name with cp437 and cp852 (DOS/OEM),
cp1252 and cp1250 (Windows/ANSI), and scores each result
(`src/zipnames.ts`):

- A page that gives a control character or an undefined byte is out.
- Each non-ASCII char costs 1 unless it is a letter or punctuation; box
  drawing, symbols, superscripts, fractions and cp437's Greek letters cost 1.
- A letter or punctuation mark also costs 1 when it stands alone (no letter
  or digit beside it), and a letter when it breaks its word's case
  ("EspaĄa").
- The lowest total wins. Pages that decode every name the same count as one.

A tie between pages that give different names goes to the page whose
decoding of the top-level dir equals the archive's own file name, if exactly
one does, else to the first in the tie order: cp437, cp852, cp1252, cp1250.
A tie broken by that order is a guess, so every root resolved from the
archive gets `archive_name_code_page_guessed:<page>` in `quality.issues` and
`needs_review: true` (the resolver makes the choice again from the archive).
Names no page can decode fail the archive (`E_ARCHIVE`). Each archive row of
the scan output carries `code_page: {cp, by}`, `by` being `score`,
`name_match` or `order`; it is `null` when the names needed no code page.

One optional top-level key in income.yaml changes the tie order:

```yaml
archive_code_pages: [cp852, cp1250]   # these first, in this order, then the rest in the default order
income:
  - name: downloads
    path: /path/to/income/downloads
```

It only orders ties: all four pages are always scored. Allowed names are
`cp437`, `cp852`, `cp1252` and `cp1250`. An unknown name, a duplicate or a
value that is not a list fails every command that reads income.yaml, the way
a malformed income.yaml does (`E_BAD_RULES`, exit 2). There is no setting per
income folder.

### beets hard path

`identify` runs `shim/beets_identify.py` when the fast path has no single
Discogs confirmation, as `beets_identify.py <root_dir> <file>... --json`.
The files are the root's own audio, its sidecar `files[].path` without
quality shadows, so a multi-disc root's `cd1/`, `cd2/` tracks are included
and a virtual root's neighbours are not. The shim never lists the dir. It
refuses a file that is absolute, has a `..` component, resolves outside the
root dir or is not a regular file. Candidates' `track_mapping` is keyed by
that relative path. The shim must run on the Python interpreter beets is
installed in. By default it follows `beet`'s interpreter: the CLI finds `beet`
on PATH and reads its shebang (`head -1 "$(which beet)"`). An absolute
`#!/path/to/python3.10` runs the shim under that path; `#!/usr/bin/env
[-S] python3.10` runs it under that name, looked up on PATH. With no `beet`
on PATH, an unreadable or binary `beet`, or a non-Python shebang (such as a
shell wrapper), the default is `python3 shim/beets_identify.py`, and if that
`python3` has no beets the shim reports `beets_unavailable`.

`INTAKE_BEETS_SHIM` overrides the default with the full command:

```bash
# Homebrew python@3.10 with beets 1.6:
export INTAKE_BEETS_SHIM="/opt/homebrew/opt/python@3.10/bin/python3.10 /path/to/tools/intake/shim/beets_identify.py"
```

The value is split on spaces, so neither path may contain one.

Supported beets: 1.6 and 2.x. Checked against real 1.6.0, 2.13.1 and 2.14.1.
The shim detects the API shape itself:

- **beets 2.4+**: every metadata source, MusicBrainz included, is a plugin.
  The shim loads the plugins in the beets config's `plugins:` list before
  tagging. With no `plugins:` entry, beets' default (`[musicbrainz]`) applies.
  A list without `musicbrainz` gets no MusicBrainz candidates, as with
  `beet import`; the shim does not add it.
- **beets < 2.4**: MusicBrainz is built in. The shim loads no plugins and, as
  before, does not apply the config's `musicbrainz:` section (host,
  ratelimit).
- Only MusicBrainz (`mb`) and Discogs (`discogs`) candidates are reported;
  other metadata plugins' candidates are dropped. Discogs candidates via the
  beets `discogs` plugin need beets 2.4+ and a `user_token` (or saved token)
  in the beets config. The shim gives plugins no stdin, so the interactive
  Discogs login cannot run. chroma/AcoustID adds nothing: beets fingerprints
  during `beet import`, which the shim does not run.
- A MusicBrainz network failure is logged to stderr and yields zero
  candidates (exit 0), not an error.

The shim reads the beets config from `$BEETSDIR` (default `~/.config/beets`),
never opens the library database and never writes to the release dir.

Execute/gc need `journal.path` in structure.yaml (the NAS location is
pending confirmation; nothing runs without it). Execute copies and verifies —
income originals are only ever removed by `gc`, which re-verifies both the
journal record and the placed files' audio hashes first, then leaves the
sidecar behind as a `gc_done` tombstone. gc deletes a root's local files (or
with `--relocate-dj` moves its audio to the dj zone) all or none: it first
renames every file into `.intake-gc-<id>/` inside the root's dir (or to its
dj destination) and deletes the staged files only once every rename worked.
If one fails (an append-only flag, an existing dj file, ...) the renames are
reversed, the root stays `placed` with no journal line, and a per-root
`E_VERIFY` (`E_TARGET_EXISTS` for an existing dj file) names the file. A
read-only dir inside the root's dir gets u+w while gc works and its mode
back afterwards; nothing outside the root's dir is chmodded. The
user-immutable flag `uchg` (how macOS shows the DOS read-only attribute on
an SMB share, where chmod has no effect) is cleared first on the files gc
renames and on the dirs inside the root's dir it goes through (the root's
dir, the files' dirs, a whole-dir root's disc dirs), with
`/usr/bin/chflags` on those paths only: one `stat` spawn per root reads the
flags, one `chflags` spawn clears them. The row's `issues` reports the files
(`cleared_readonly_flag: <n> file(s)`). A failed gc sets uchg back on all of
them; a successful one on the dirs that remain. Other files in the root's
dir (a virtual root's neighbours), anything outside it, and the flags
`uappnd`, `schg` and `sappnd` are never touched; a relocated file arrives in
the dj zone without the flag. Before it disposes anything, gc makes sure it
can write the bookkeeping that follows: the sidecar (uchg cleared and u+w
added if needed, both put back after the tombstone write) must open
read-write and the journal must open for append (never chmodded or
unflagged). If either fails nothing is disposed, the root stays `placed`
with no journal line, and the root gets `E_VERIFY` (sidecar) or
`E_NO_JOURNAL` (journal). A stage dir left by a gc that died is never
walked or resolved; a gc rerun deletes it. For an
archive-sourced root gc removes the root's files inside `<name>.unpacked/`;
the archive and the `.unpacked` dir stay. Each copy gets u+w (a 0444
original copies as 0444 and could not be tagged) and loses uchg
(`copyFileSync` clones a file over 128 KiB on APFS, flags included); the
original is never changed. Provenance tags are part of the placement: a failed tag write
(`metaflac_missing`, `metaflac_failed`, `provenance_write_failed`) fails the
root before the rename, so nothing is placed or journaled, the temp dir is
removed and the root goes back to `approved` with a per-root `E_VERIFY`. A
skipped write (`provenance_tags_skipped:*`: an `fsha1:`-keyed FLAC, a format
with no writer) stays an issue on the placed root.

`propose --all-resolved` never picks up `needs_review` roots — offline (no
Discogs confirmation) that is every root, so unattended auto-proposing
effectively requires network identify. `needs_review` is sticky: only
`approve` clears it.

Targets follow the library layout (doc 02, amendment 003), read from the
target collection dir when proposing: `<Collection>/<Artist>/` when the
artist already has a release in that collection (an artist dir, or a
release in `[Releases]` or loose), else `<Collection>/[Releases]/`; Various
Artists releases go to `<Collection>/[Compilations]/`. Existing slot dirs
are reused whatever their case; other bracketed dirs are never targets.
Existing library folders are never moved: when a new release opens an
artist folder, the artist's earlier releases outside it are listed as
`restructure_candidates` on the proposal and the propose row.

`reject` is a state change only (legal from `new`, `resolved`, `proposed`,
`approved`; `E_BAD_STATUS` otherwise): it flips the sidecar to `rejected` and
appends a history entry carrying the optional `--reason`. No tags, audio,
journal or deletion; rejected roots stay in `status`, are never picked up by
propose/approve/execute/gc, and their local files are disposed of by hand.
`rejected` is terminal; `resolve --force` rebuilds the sidecar from scratch.

## Development

```bash
bun test                               # golden + property + unit suites
bun run scripts/gen-fixtures.ts        # regenerate fixture corpus (ffmpeg)
bun run scripts/gen-fixtures.ts --only=todo/Foo   # add/refresh one fixture in place
bun run scripts/bless-golden.ts        # re-bless golden expectations
```

`--only=<relpath prefix>` skips the wipe and generates just the matching
fixtures, so previously committed audio bytes — and the goldens keyed to their
hashes — stay byte-identical. A partial run does not advance the tone-frequency
counter, so fixtures added this way must pass an explicit `freq` (enforced) to
stay reproducible in a later full run.

The fixture corpus (`fixtures/income/`) is fully synthetic — sine-tone audio,
public artist/label names as test literals only, no personal data. Tests copy
it to a temp dir; the committed tree never receives sidecars. Junk files
(`.DS_Store`, `._*`, `Thumbs.db`) are injected by the test helper because the
repo `.gitignore` excludes those names. Archive fixtures cover zip only
(`unzip` ships with macOS); the tests build zips and RAR4/RAR5 archives at
test time (`test/zipbuild.ts`, `test/rarbuild.ts`). 7z, and zips with any
non-ASCII name (macOS's `unzip` mangles those from Windows tools), go through
`7zz`, else `7z`. A solid RAR4 (main header solid flag, or an entry that
continues a solid stream) goes to `unar` (The Unarchiver's CLI, `brew install
unar`) when it is on PATH: libarchive 3.7.4 writes its first member and then
fails. With no `unar` on PATH a solid RAR4 is refused before anything is
written ("solid RAR4 is not supported without unar on PATH"). Every other rar,
solid RAR5 included, goes to `bsdtar` (libarchive, `/usr/bin/bsdtar` on
macOS), else `7zz`/`7z`, which extract stored rar members only. bsdtar can
exit 0 after writing a member with a wrong CRC32, or the ciphertext of an
encrypted one, so intake checks rar itself (`src/rarheaders.ts`), whichever
tool extracts it: before anything is written it reads the headers and
refuses multi-volume sets, header- or file-encrypted archives, entries with
no CRC32 (RAR5 BLAKE2-only), RAR5 hard link, file copy and junction entries,
unsafe or duplicate paths and damaged headers; after extraction it checks
each data entry's size and CRC32 and fails the archive on a mismatch, a
missing entry or a file the headers do not list. Plain OEM RAR4 names are
decoded with the code page chosen as for zips ("Archive entry names" above),
passed to bsdtar as `rar:hdrcharset` (libarchive 3.7.4 on macOS takes CP437,
CP852, CP1252 and CP1250, each checked against iconv for every defined byte)
and to unar as `-e` (`cp437`, `cp852`, `windows-1252`, `windows-1250`; unar
1.10.7 matches the same tables for every defined byte). unar runs with
`-D -nr -k skip -nq -s -q` (see `unarArgv` in `src/archive.ts`); the real-unar
tests (`test/archive-unar.test.ts`) skip without it. With no
tool on PATH a rar/7z reports `E_ARCHIVE_TOOL` and such a zip `E_ARCHIVE`.
The `E_ARCHIVE_TOOL` surface is covered in `test/archive.test.ts` by
re-running the CLI with `PATH` stripped, since `Bun.which()` reads the
environment at process start. An unpack tool run is
killed after 30 minutes (`UNPACK_TIMEOUT_MS` in `src/archive.ts`) and the
archive reported `failed`; SIGTERM, SIGINT or SIGHUP during a run kill the
tool and remove the partial dir before intake exits. The tools restore an
archive's read-only modes (a 0555 dir blocks removing the files in it, a
0444 file cannot be tagged), so after every tool run, and before a partial
dir is removed, the extracted tree loses uchg (one `chflags -R` spawn, no
symlink followed) and gets u+rwx on dirs and u+rw on files
(`test/archive-readonly.test.ts`).

One fixture (`todo/Bluetech [2011] Cosmic Dubwise`) carries a zeroed FLAC
STREAMINFO MD5 on two of three files, so the decoded-audio key (`flacmd5:`
computed with `flac`, CR-003) and the `flac_md5_unset` quality issue are
covered end-to-end alongside the embedded `flacmd5:` path. The `fsha1:`
fallback without a usable decoder is covered in
`test/flac-unset-md5.test.ts`, which runs the CLI with a `PATH` that lacks
`flac`.

Re-blessing goldens: run only after hand-verifying resolver output; the
golden file is the reviewed source of truth. Regenerating fixtures changes
audio bytes only if ffmpeg's encoders change; re-bless afterwards.

P1 acceptance gate (asserted in `test/golden.test.ts`): >=90% of fixture
roots correctly bounded; zero file mutations, verified by recursive tree hash
before/after every command (sidecars and `*.unpacked/` are the only legal
additions, and only for non-`--dry-run` scan).
