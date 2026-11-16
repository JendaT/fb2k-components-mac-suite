# Intake end-to-end scripts (B8/B9)

These scripts run the **real** intake CLI (`feature/intake-cli`, run through
`bun run`) against a **synthetic** corpus in scratch. They exist so B8
(Execute/Resume) and B9 (Swap / Delete local copy) can be checked against
real CLI behaviour, both from the shell and in foobar2000.

**Only the orchestrator runs them.** They are not a build gate: `build.sh`
and `run_tests.sh` never call them. Agents check them statically only
(`bash -n`, refusal paths).

| File | Role |
|---|---|
| `make_corpus.sh <dest>` | Builds the synthetic corpus inside `<dest>`. Never runs the CLI. |
| `run_flow.sh <dest> [steps]` | Runs scan, reject, assign, identify, propose, approve, execute, resume and gc through the wrapper, checking each status with `--json` and `jq`. |
| `run_flow.sh <dest> --cli-wrapper` | Writes `<dest>/bin/intake-e2e`, saves the component settings it replaces (read only) and prints the new ones and how to restore the old. |
| `e2e_lib.sh` | The shared guards and the wrapper generator. It is sourced by both scripts. |

## Safety rules

- **Synthetic data only.** The scripts generate 1 s sine tones with ffmpeg.
  All artists, albums and labels are invented ("Fixture Artist E2E" and so
  on). No real music, no real collection names, no NAS paths.
- **Where `<dest>` may be.** Both scripts refuse (exit 64, before doing
  anything) unless the realpath of `<dest>` is:
  - below `$TMPDIR`, or
  - below a Claude Code session scratchpad
    (`/private/tmp/claude-<uid>/<project>/<session>/scratchpad/`).
- **Other refusals.** Both scripts also refuse:
  - anything under or naming `/Volumes` or `/volume1` (case-insensitive);
  - a `..` component, a symlinked `<dest>`, or characters outside `[A-Za-z0-9._/-]`.
- **make_corpus.sh** also refuses a `<dest>` that already has files in it.
- **run_flow.sh and the wrapper** also refuse:
  - a corpus whose `.intake-e2e-corpus` marker names another location;
  - a rules dir that resolves outside `<dest>`;
  - any symlink: the corpus dirs themselves (`bin`, `home`, `tmp`, `cache`,
    `logs`, `rules`, `income`, `library`) and anything below `rules`,
    `income`, `library` and `bin`. The CLI follows a symlink at an income
    folder or a tier root, so a path that only reads as inside `<dest>` is
    not enough;
  - an `income.yaml` or `structure.yaml` that differs from the one
    make_corpus.sh wrote (both are pinned by SHA-256 in the marker; the CLI
    never writes them);
  - any `path`, `root` or `dj_zone` in those two files that is not an
    absolute path inside `<dest>` that resolves to itself (YAML flow
    mappings and anchors are refused too).
- **run_flow.sh never runs beside a live execute.** Before every step it
  refuses when a root is `placing`, a `.intake-tmp-*` dir exists in the
  library, or a component run file in `~/Library/Caches/foo_jl_intake/`
  (read only) names a live pid or has no pid yet. The CLI has no locking:
  a step that runs `execute` next to the in-app Execute would share its
  temp dir.
- **The wrapper is the only way in.** `<dest>/bin/intake-e2e` checks the
  corpus again on every call, then runs `env -i … bun run --no-install cli.ts`
  with only these variables:
  - `HOME=<dest>/home`, so `~/.config/intake/config.toml` cannot be found;
  - `INTAKE_RULES_DIR=<dest>/rules` and `INTAKE_CACHE_DIR=<dest>/cache`;
  - `INTAKE_BEETS_SHIM=<dest>/bin/beets-offline-stub`, which answers
    `beets_unavailable`, so identify never reaches MusicBrainz;
  - `BEETSDIR` inside `<dest>`, `TMPDIR=<dest>/tmp/`, `DO_NOT_TRACK=1`
    (no bun crash-report upload), and a fixed `PATH`.

  `DISCOGS_TOKEN` and `LASTFM_API_KEY` are unset and never passed on. bun's
  own caches land in `<dest>/home`. If the wrapper refuses, it prints why on
  stderr and exits 64 with no JSON envelope, which the component reads as
  `E_NO_CLI`.
- **No network.** With no tokens and the stub shim, identify runs offline:
  `unconfirmed`, `needs_review`. Nothing in the flow needs the network.
- **Output stays in scratch.** Corpus, sidecars, library copies, journal and
  logs (`<dest>/logs/run-*`) all live in `<dest>` and are never committed.
- **No script runs against real data.** Any run against the intake test
  share needs the user's explicit go-ahead first.

## How to run

```bash
E2E=extensions/foo_jl_intake_mac/Tests/e2e
DEST=$TMPDIR/intake-e2e-$(date +%s)        # or a dir under the session scratchpad

$E2E/make_corpus.sh "$DEST"
$E2E/run_flow.sh "$DEST"                   # all steps; exit 0 only if every check passes
```

For the in-app checks, stop the flow early, then point the component at the
wrapper:

```bash
$E2E/run_flow.sh "$DEST" to-approved   # B8: run Execute from foobar2000
$E2E/run_flow.sh "$DEST" to-placed     # B9: Swap to library paths / Delete local copy
$E2E/run_flow.sh "$DEST" --cli-wrapper # saves the current settings, prints the new ones
$E2E/run_flow.sh "$DEST" gc            # after to-placed, if the CLI should do the gc
```

The in-app settings replace the user's own:
1. `--cli-wrapper` reads the current `cli_path`, `bun_path`, `rules_dir`,
   `watch_folders` and `swap_prefix_*` values from `config.sqlite` (read
   only) into `<dest>/logs/prefs-before.txt`, and writes
   `<dest>/logs/prefs-restore.sql`, which puts them back. It saves them
   only once per corpus, so a second run does not save the e2e values.
2. Ask the user before quitting foobar2000, and quit it only when it is
   idle and nothing is playing. Then write the printed settings.
3. Afterwards, with foobar2000 quit again and before `<dest>` is removed,
   restore: `sqlite3 ~/Library/foobar2000-v2/config.sqlite < <dest>/logs/prefs-restore.sql`.
   Otherwise the component keeps pointing at a wrapper that no longer
   exists and reports `E_NO_CLI` on every refresh.

Do not run run_flow.sh on a corpus while foobar2000 runs an Execute or
Resume on it. The script refuses when it sees signs of one (see Safety
rules).

Use a fresh corpus for every full run. Steps can be listed by name, e.g.
`preflight,scan`, but they assume the order above.

Requirements:
- `make_corpus.sh` needs ffmpeg with the flac and libmp3lame encoders.
- `run_flow.sh` needs jq, bun and the CLI worktree, plus metaflac for the
  provenance check; `--cli-wrapper` uses sqlite3 to save the settings.
- To use a different bun or CLI, set `INTAKE_E2E_BUN` or `INTAKE_E2E_CLI`.
  The default CLI is
  `~/Projects/Foobar2000-worktrees/intake-cli/tools/intake/src/cli.ts`.

## Corpus

| Key | Income folder | What it is | Path through the flow |
|---|---|---|---|
| A | `e2e-web` | 3 FLAC, cover/nfo/m3u, label in the folder name; the artist already has a folder in the library | engine (genre map) → `music.hq/[E2E Ambient]/Fixture Artist E2E/` |
| B | `e2e-web` | 2 FLAC plus MP3 copies of both tracks (quality shadows) | user assign → `music.hq/[E2E Downtempo]/[Releases]/`, shadows not placed |
| C | `e2e-web` | Various Artists, 4 track artists, label in the folder name | label map → `music.hq/[E2E Compilations]/[Compilations]/` |
| D1, D2 | `e2e-soulseek` | flat dump: 2 albums (FLAC; MP3 320) = 2 virtual roots | engine → `[Releases]/` in two collections |
| DS | `e2e-soulseek` | loose single in the same dump (singles root) | propose refused: `E_NO_TARGET` (singles slot pending) |
| E | `e2e-manual` | one-track release in its own folder | engine → `music.hq/[E2E Ambient]/[Releases]/` |
| F | `e2e-manual` | 24-bit/96 kHz FLAC | engine → `music.uhq/[E2E Ambient]/[Releases]/` |
| G | `e2e-manual` | normal album | rejected with a reason |
| H | `e2e-manual` | untagged files, unparseable folder name | stays `new` |

## What each step checks

Every CLI reply must be one JSON envelope (`ok`, `errors`, `data`). `ok`
must be true exactly when the exit code is 0, and `data` must be null on
exit 2.

- **preflight:** `version` (schema 1, command list), `income` (3 folders,
  all inside `<dest>`), `collections`, and that every root in `status` is
  inside `<dest>`.
- **scan:** `scan --all` writes 10 sidecars.
  - Statuses: A, B, C, E, F, G `resolved`; D1, D2, DS `resolved` with
    `needs_review`; H `new`.
  - C is credited to Various Artists, B's MP3s are shadows, D1, D2 and DS
    are virtual, D2 is lossy hq and F is uhq.
  - The filters `singles=true` and `tier=uhq` each find exactly one root.
  - A rescan writes nothing, `resolve` keeps H, and `resolve --force
    --dry-run` computes H as `new`.
- **reject:** G becomes `rejected`, with the reason in its history. A
  second reject gives `E_BAD_STATUS`.
- **assign:** `assign --collection "[E2E Downtempo]" --by user` on B.
  - B stays `resolved`, with `assigned_by: user` and `ranked: []`.
  - The override and the genre-map feedback are written.
  - Assigning G gives `E_BAD_STATUS`.
- **identify:** A comes back `unconfirmed`, with the issue
  `beets_unavailable` (proof that the stub was used) and no Discogs
  attempt. A gets `needs_review`. Identifying G gives `E_BAD_STATUS`.
- **propose:** the 7 placeable roots become `proposed`, all with
  `needs_review` (offline identify; B too, per amendment 003 C11).
  - Each target is in the expected tier, collection and slot.
  - A's structure slot is `artist` and C's is `compilations`.
  - DS gives `E_NO_TARGET`; H and G give `E_BAD_STATUS`.
- **approve:** the 7 roots become `approved` and `needs_review` is
  cleared. DS gives `E_BAD_STATUS`.
- **execute:**
  - `--dry-run` reports the file, artifact and shadow counts and writes
    nothing.
  - The real run makes 7 roots `placed`, verified, with
    `placed.target_path` equal to the proposal target.
  - Every primary file is at `target/<path>`, no shadow is copied, A's
    artifacts are copied and the virtual roots copy audio only.
  - The journal has 7 `placed` records and no `.intake-tmp-*` dir is left.
  - The originals are untouched. INTAKE_BATCH is present on the copies
    (FLAC via metaflac, MP3 via TXXX) and absent on the originals.
  - Executing A again gives `E_BAD_STATUS`.
- **resume:** always per root (`execute <ids> --resume`, as the component
  sends it; the bare all-roots form is never used).
  - On the 7 placed roots: `E_BAD_STATUS` for each.
  - A, hand-set to `placing` with its library copy intact: `resumed:
    "completed"`, `placed` and verified again, no new journal record.
  - E, hand-set to `placing` with its library copy moved aside: `resumed:
    "reverted_to_approved"`, status `approved`, no `.intake-tmp-*` left.
    The moved copy is then deleted and E executed again, so gc finds all 7
    placed.
- **gc:**
  - `gc` with no roots gives `E_BAD_ARGS`; gc on G gives `E_BAD_STATUS`.
  - `--dry-run` deletes nothing; it counts 4 local files for B, shadows
    included.
  - The real gc makes 7 roots `gc_done`. The library copies stay, local
    audio and artifacts go, the sidecars stay as tombstones, and DS, G and
    H keep their files.
  - The journal has 7 `gc_done` records.

The expectations come from reading the CLI source at 0.3.0
(`feature/intake-cli` d00daff8). If a check fails, read the logged reply in
`<dest>/logs/run-*/NNN-<label>.json` (with `.cmd` and `.err` beside it)
before changing either side.
