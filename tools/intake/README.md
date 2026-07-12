# intake CLI

Release-root resolver and sidecar tooling for the intake system. Specs:
`docs/intake/intake-01-resolver-spec.md` (resolver + sidecars) and
`docs/intake/intake-03-contract-spec.md` (CLI contract — command surface,
JSON envelope, exit codes, status lifecycle, audio_hash).

Self-contained Bun package; no fb2k SDK or Xcode dependency.

## Usage

```bash
bun install

# Rules dir (income.yaml, structure.yaml) — real maps live in the private
# music-rules repo; this repo ships only schema docs and fixtures:
export INTAKE_RULES_DIR=/path/to/music-rules   # or ~/.config/intake/config.toml

bun run src/cli.ts scan --all          # discover, unpack archives, resolve
bun run src/cli.ts resolve <dir>       # (re)detect roots, write sidecars
bun run src/cli.ts identify <root>     # establish what a release is
bun run src/cli.ts assign <root>       # rank genre-collection folders
bun run src/cli.ts assign <root> --collection "[X]" --by user   # override + feedback
bun run src/cli.ts propose <root>      # identify+assign+naming -> proposed
bun run src/cli.ts approve <root>      # or --batch <file> of ids/paths
bun run src/cli.ts execute --approved  # copy, tag, verify, journal, place
bun run src/cli.ts execute --resume    # crash recovery for `placing` roots
bun run src/cli.ts gc [--age 30] [--relocate-dj]   # verified local cleanup
bun run src/cli.ts collections         # genre map folder list (picker)
bun run src/cli.ts bootstrap --tree <path> --out <dir>          # build maps
bun run src/cli.ts status --json       # sidecar inventory
```

All commands accept `--json` (single envelope on stdout) and `--dry-run`.
Exit codes: 0 ok, 1 partial, 2 error. Roots are addressed by path or
sidecar id.

Identify/assign run fully offline by default; network evidence is opt-in via
`DISCOGS_TOKEN` and `LASTFM_API_KEY` (similar-artist cache under
`INTAKE_CACHE_DIR`, default `~/.cache/intake`). The beets hard path uses
`shim/beets_identify.py` (needs a python3 with beets installed; override the
command with `INTAKE_BEETS_SHIM`); without it, identification degrades to
`unconfirmed` and flags review.

Execute/gc need `journal.path` in structure.yaml (the Amunet location is
pending confirmation; nothing runs without it). Execute copies and verifies —
income originals are only ever removed by `gc`, which re-verifies both the
journal record and the placed files' audio hashes first, then leaves the
sidecar behind as a `gc_done` tombstone. `propose --all-resolved` never picks
up `needs_review` roots — offline (no Discogs confirmation) that is every
root, so unattended auto-proposing effectively requires network identify.

## Development

```bash
bun test                               # golden + property + unit suites
bun run scripts/gen-fixtures.ts        # regenerate fixture corpus (ffmpeg)
bun run scripts/bless-golden.ts        # re-bless golden expectations
```

The fixture corpus (`fixtures/income/`) is fully synthetic — sine-tone audio,
public artist/label names as test literals only, no personal data. Tests copy
it to a temp dir; the committed tree never receives sidecars. Junk files
(`.DS_Store`, `._*`, `Thumbs.db`) are injected by the test helper because the
repo `.gitignore` excludes those names. Archive fixtures cover zip only
(`unzip` ships with macOS); rar/7z go through `7z` when available, else the
scan reports `E_ARCHIVE_TOOL`.

Re-blessing goldens: run only after hand-verifying resolver output; the
golden file is the reviewed source of truth. Regenerating fixtures changes
audio bytes only if ffmpeg's encoders change; re-bless afterwards.

P1 acceptance gate (asserted in `test/golden.test.ts`): >=90% of fixture
roots correctly bounded; zero file mutations, verified by recursive tree hash
before/after every command (sidecars and `*.unpacked/` are the only legal
additions, and only for non-`--dry-run` scan).
