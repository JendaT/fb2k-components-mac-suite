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
bun run src/cli.ts status --json       # sidecar inventory
```

All commands accept `--json` (single envelope on stdout) and `--dry-run`.
Exit codes: 0 ok, 1 partial, 2 error.

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
