# Intake 03 — CLI ⇄ Component Contract

**Repo destination:** `docs/intake/intake-03-contract-spec.md`
**Owner:** SHARED — tools worker and extension worker both comply.
Changes require repo-overseer sign-off; this document is the interface.
**Status:** draft v1 — 2026-07-11

## Boundary principle

The component **reads** state (sidecars + CLI `--json` output) and **mutates
only through CLI commands**. It never writes sidecars, tags, or the journal
itself. The CLI never renders UI and never depends on foobar2000.

## Status lifecycle (normative)

```
new → resolved → proposed → approved → placing → placed → gc_done
        │            │          │
        └────────────┴──────────┴──▶ rejected        (terminal)
resolved/proposed may carry needs_review: true (orthogonal flag)
```

Legal transitions only via CLI commands; `placing` is transient (crash
recovery: `intake execute --resume` re-verifies and completes or reverts to
`approved`). Every transition appends to sidecar `history[]`.

## CLI command surface (v1, semver)

All commands: `--json` (machine output, single JSON doc on stdout),
`--dry-run` where mutating, exit 0 ok / 1 partial / 2 error.

```
intake scan     [<income>|--all]
intake resolve  <path> [--force]
intake identify <root...>
intake assign   <root...> [--collection "<name>"] [--by user|engine]
intake propose  <root...>|--all-resolved      # identify+assign+naming
intake approve  <root...>|--batch <file>
intake execute  <root...>|--approved [--resume]
intake gc       [<root...>] [--age <days>] [--relocate-dj]
intake status   [--filter k=v...]             # sidecar inventory
intake collections                            # genre map folder list (picker)
intake version                                # {cli, schema, engine} versions
```

## JSON conventions

- Envelope: `{ "ok": bool, "data": …, "errors": [{code, msg, path}] }`.
- Roots are addressed by sidecar `id` OR absolute path (CLI accepts both).
- `status --json` returns an array of sidecar summaries:
  `{id, root_path, status, needs_review, cluster:{albumartist,album},
  proposal:{target_collection, confidence}, placed:{verified, target_path}}`.

## audio_hash (normative algorithm)

- FLAC: `"flacmd5:" + embedded STREAMINFO MD5` (via metaflac; recompute+fix
  if unset, flagged in quality.issues).
- MP3: `"mp3sha1:" + SHA1(file bytes minus ID3v2 block(s) at head, minus
  ID3v1/APEv2 tail)`.
- WAV/AIFF: `"pcmsha1:" + SHA1(data/SSND chunk bytes)`.
- DSD (dsf): `"pcmsha1:" + SHA1(data chunk)`; dff and others (m4a/ogg):
  `"fsha1:" + SHA1(whole file)` v1 fallback (tag edits change it;
  acceptable, revisit).

Tag edits MUST NOT change audio_hash for flac/mp3/wav/aiff. This key links
sidecars ↔ journal ↔ future sync-base snapshots.

## Execute protocol (tools worker implements; component displays)

1. Freeze proposal → compute final tag set (identify result + provenance:
   `INTAKE_DATE`, `INTAKE_SOURCE`, `INTAKE_BATCH`; TXXX / VorbisComment).
2. Copy release to a temp dir on Amunet target volume → write final tags to
   the **copies** → fsync.
3. Verify: audio_hash of every copy == sidecar hash; file count match.
4. Atomic rename temp dir → `target_path`.
5. Append journal record; update genre-map counts; flip sidecar → `placed`
   with `placed:{target_path, verified: true, journal_seq}`.
6. Local originals untouched until `gc` (which re-verifies against journal
   before delete, or relocates into SSD dj/ zone with `--relocate-dj`).

## Journal (Amunet)

`/volume1/music/music.meta/intake-journal.ndjson` *(location pending
confirmation)* — deliberately a sibling of ALL `music.*` tiers: one journal
for the whole share; the tier is encoded in each record's `target_path`.
Append-only, one JSON object per line:
`{seq, ts, event, sidecar_id, audio_hashes[], target_path, cli_version}`.
Journal is the authority for "is it in the library"; sidecars are working
copies; tags are projection.

## Component read patterns

- Component matches playlist row paths against sidecar roots obtained from
  `intake status --json`.
- Refresh: FSEvents watch on income roots for `.intake.json` changes +
  post-command refresh. No polling loops.
- Version gate: component calls `intake version` at init; refuses decoration
  (logs, stays inert) if `schema` major ≠ supported.

## Error surfaces

CLI unavailable / rules repo missing / journal unreachable → distinct error
codes (`E_NO_CLI`, `E_NO_RULES`, `E_NO_JOURNAL`); component renders inert
state with tooltip, never blocks playback UI.
