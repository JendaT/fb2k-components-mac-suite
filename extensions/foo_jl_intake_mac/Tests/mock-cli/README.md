# intake-mock

A fake `intake` CLI for testing foo_jl_intake_mac without the real tool or
real music. It prints the doc 03 envelope (`{ok, data, errors}`, contract
v1.2) with the data shapes of CLI 0.3.0 (branch `feature/intake-cli`) for
`version`, `status`, `collections`, `income`, `propose`, `assign`,
`approve`, `reject`, `execute` (with `--dry-run` and `--resume`) and `gc`.
The `cli-0.2.1` scenario switches to what CLI 0.2.1 does, for testing the
consumer's fallbacks.

Plain bash 3.2 (`/bin/bash` on macOS) plus `find`, `cp`, `mkdir` and `rm`.
All fixtures are synthetic.

## Use

```bash
export INTAKE_MOCK_STATE=/abs/path/to/empty/dir   # required
Tests/mock-cli/intake-mock --mock-setup default    # build $STATE/root and $STATE/responses
Tests/mock-cli/intake-mock status --json
```

`INTAKE_MOCK_STATE` must be an absolute path to an existing directory, with no
quotes, backslashes or control characters in it. The mock refuses to run
otherwise (exit 64). Every file it writes is inside that directory, and every
path in its output is under `$INTAKE_MOCK_STATE/root`.

The first `--mock-setup` needs an empty directory and writes the marker
`.intake-mock-state` into it. Every later run, setup or command, refuses
(exit 64, nothing written) in a directory without that marker, so a
misconfigured wrapper cannot delete another directory's `root/` or
`responses/`.

foobar2000 does not pass this variable on. To point the component at the
mock, write a small wrapper in your scratch folder (never in the repo) that
exports `INTAKE_MOCK_STATE` and runs `exec .../intake-mock "$@"`.

`--mock-setup <scenario>` throws away `root/`, `responses/`, every `*.mode`,
`*.next` and `*.start` file and `hang.pid`, then copies the scenario in.
`calls.log` and the marker are kept.

## Scenarios (`scenarios/<name>/`)

| Scenario | CLI | What it is |
|---|---|---|
| `default` | 0.3.0 | 16 roots in `income/dump` and `income/shop`: every status (`new`, `resolved`, `proposed`, `approved`, `placing`, `placed`, `gc_done`, `rejected`); `needs_review` on a new (virtual) root, two resolved roots, an engine proposal and a user override; `ranked` on every engine proposal and `[]` on a user-only one; `assigned_by` `"user"` on the override (`itk_0000000f`: confidence 1, `needs_review` still set) and on the user-only proposal, `"engine"` elsewhere; `target_path` on every proposal but the single: the Various Artists root (`itk_00000015`) has a `<Collection>/[Compilations]/...` target (amendment 003), the single (`itk_00000019`, `singles: true`, resolved with `needs_review`) a null one, and propose refuses it with `E_NO_TARGET` "cannot propose: singles slot pending"; three virtual roots sharing one folder (two albums and the single); library copies of the placed and gc_done roots under `root/library/`; income folders `dump`, `shop` and `offline` (configured, missing) |
| `cli-0.2.1` | 0.2.1 | `default` as CLI 0.2.1 shows it, without the single (15 roots): `version` without `commands`, summaries without `assigned_by` and `target_path`, no `income` command, assign accepted from any status, `gc` without roots collects every placed root and skips a named root that is not placed without an error, the Various Artists root has no target (its sidecar and a user assign give `target_path: null`, propose refuses it with `E_NO_TARGET` "cannot propose: compilations slot pending"), and `--filter` is parsed leniently |
| `no-ranked` | 0.2.1 | `cli-0.2.1` with `proposal.ranked` absent from the `status` summaries (sidecars keep it, as with the real CLI) |
| `cli-0.1` | 0.1.0 | `cli-0.2.1` as CLI 0.1.0 would show it: `version` reports 0.1.0, `reject` is an unknown command, no rejected root, `ranked` absent from the `status` summaries (sidecars keep it) |
| `schema2` | 0.3.0 | `default` with `"schema": 2` in `version` |
| `schema-string` | 0.3.0 | `default` with `"schema": "1"` (a string) in `version` |
| `perf-200` | 0.3.0 | 200 generated roots in `income/perf`, statuses cycling through the lifecycle. Status and income only: it has no reply files, so a mutating command on a root in a status the CLI accepts exits 64 (see below) |
| `placed-unverified` | 0.3.0 | `default` with the placed root `itk_00000012` at `placed.verified: false` (summary and sidecar), for B9: Swap and Delete local copy must not qualify, and the library index leaves it out. Its gc replies are kept (the CLI would re-verify; the component never asks) |
| `uat` | 0.3.0 | The user acceptance checklist (PLAN.md): 15 whole-folder roots in `income/uat`, one per row below, standalone (no `base`). Each income folder holds its sidecar and two tracks (the shadow album three; the gc_done root none); the placed, verified roots and the gc_done root have their library copies under `root/library/music.hq/`. Reply files for every command and status the CLI accepts, so a stray click never exits 64; no state changes without a `.next` file (see "States in `uat`") |

The `default` ids are `itk_0000000a` to `itk_00000019`; `status --json` lists
them with their states.

The `uat` roots (folder `income/uat/UAT Artist - <album>`, album artist `UAT Artist`):

| Id | Album | Status | For |
|---|---|---|---|
| `itk_000a0001` | 01 New | `new` | Reject without confirmation (`uat-01-rejected`) |
| `itk_000a0002` | 02 New Flagged | `new`, `needs_review` | the "needs review" tooltip on a new root (not amber) |
| `itk_000a0003` | 03 Resolved | `resolved` | Reject… with a reason (`uat-03-rejected`) |
| `itk_000a0004` | 04 Resolved Review | `resolved`, `needs_review` | amber; the picker first in the menu |
| `itk_000a0005` | 05 Proposed | `proposed` → Test Collection A 0.91 | two "Assign to X" alternates |
| `itk_000a0006` | 06 Proposed Review | `proposed`, `needs_review` → Test Collection B 0.61 | amber badge with an alt; Assign to other collection… (`uat-06-assigned`) |
| `itk_000a0007` | 07 Approved | `approved` → Test Collection A | Execute placement… (`uat-07-placed`) |
| `itk_000a0008` | 08 Placing | `placing` | Resume placement enabled |
| `itk_000a0009` | 09 Placed | `placed`, verified | Delete local copy… (`uat-09-gc_done`) |
| `itk_000a000a` | 10 Placed Two Playlists | `placed`, verified | an album in two playlists: Swap, then delete (`uat-10-gc_done`) |
| `itk_000a000b` | 11 Placed Quick | `placed`, verified | Swap to library paths, then Delete without confirmation (`uat-11-gc_done`) |
| `itk_000a000c` | 12 Placed Shadow | `placed`, verified | a third file, `02 - Test Track Two (shadow).wav`, with `quality_shadow: true` and no library copy: Swap, then delete is not offered (`uat-12-gc_done`) |
| `itk_000a000d` | 13 Placed Unverified | `placed`, `verified: false` | no visual; Swap and Delete do not qualify |
| `itk_000a000e` | 14 Rejected | `rejected` | grey, struck through |
| `itk_000a000f` | 15 Collected | `gc_done` | no local audio (tombstone sidecar only); library copy under `Test Collection C` |

### CLI 0.3.0 and 0.2.1 differences

`responses/cli-rules` (one line, `0.3.0` when the file is missing) picks the
status, gc and `--filter` rules; `version.json`, `commands`, `income`, the
summaries in `status.d/` and the reply files carry the rest.

| | 0.3.0 (contract v1.2) | 0.2.1 |
|---|---|---|
| `version` data | `{cli, schema, engine, commands}` | `{cli, schema, engine}` |
| `status` summary `proposal` | adds `assigned_by`, `target_path` | without them |
| `income` | `[{name, path, exists}]` | unknown command (`E_BAD_ARGS`) |
| `assign` | `E_BAD_STATUS` on `rejected`, `placing`, `placed`, `gc_done` | any status |
| `gc` without roots | `E_BAD_ARGS` unless `--all`; `--all` collects every placed root | collects every placed root |
| `gc` on a named root that is not placed | `E_BAD_STATUS` | skipped without an error |
| Various Artists root | `[Compilations]` target; propose accepts it | `target_path: null`; propose: `E_NO_TARGET` "compilations slot pending" |
| `--filter` | keys `id`, `status`, `needs_review`, `root_path`, `albumartist`, `album` answered; a malformed (`k`, `=v`, missing) or repeated filter is `E_BAD_ARGS` exit 2 for any command; an unknown key is `E_BAD_ARGS` exit 2 | keys `status`, `needs_review`, `root_path`, `albumartist`, `album`; a filter without `=` is ignored; a repeat overwrites |

## Modes: `$INTAKE_MOCK_STATE/<command>.mode`

The file holds a mode name (`exit2` takes an error code, `slow` and
`slow-real` a number of seconds) and applies to every call of that command
until you delete it. Modes never apply `.start` or `.next` states, except
`slow` and `slow-real`, which end as a normal call.

| Mode | Output |
|---|---|
| `exit2 [CODE]` | exit 2, `data: null`, one error (`E_INTERNAL` unless CODE is given, e.g. `exit2 E_NO_RULES`) |
| `partial` | exit 1, `ok: false`, the normal data plus an `E_PARSE` error |
| `garbage` | text that is not JSON, exit 0 |
| `empty` | nothing on stdout, exit 0 |
| `bare-array` | the data array alone (`[]` for object data), exit 0 |
| `noise` | about 140 KB of warnings on stderr, then the normal envelope wrapped in blank lines |
| `hang` | starts `sleep` as a child (not exec) and waits for it. Writes `<shell pid> <child pid>` to `hang.pid`. Killing only the shell leaves the child holding stdout open, so the caller has to kill the process group. If the child returns, the call ends with empty stdout and exit 0 without running the command |
| `slow [SECONDS]` | applies `.start` (not for `--dry-run`), sleeps in a child (2 s unless SECONDS or `INTAKE_MOCK_SLOW_SECONDS` is given), then runs the command normally: applies `.next` and prints the usual envelope and exit code. For a call that outlives the caller's budget and still completes |
| `slow-real [SECONDS]` | `slow` for a call without `--dry-run` (a real `execute`, `execute --resume`); a `--dry-run` call answers at once, as with no mode file. For a detached execute that runs long while its dry run answers in time (B8) |
| `big` | about 1 MB of valid status-shaped rows, written row by row, exit 0 |
| `unknown-code` | exit 2 with the error code `E_MOCK_UNKNOWN_CODE` |
| `fds` | `{"ok":true,"data":{"fds":[0,1,2]},"errors":[]}`: the descriptors open in the spawned process, read from `/dev/fd` after an exec, so bash's own script descriptor is not listed |

An unknown mode word makes the mock exit 64.

## State changes at the start: `$INTAKE_MOCK_STATE/<command>.start`

The same format as `.next` (one state name per line, the first is
consumed), for `propose`, `assign`, `approve`, `reject`, `execute` and `gc`
without `--dry-run`: the state is applied at the START of the call, before a
`slow`/`slow-real` sleep and before the reply is computed, whatever the
call's outcome. The real `execute` writes `placing` to each sidecar before it
copies anything (commands-p3.ts), so `execute.start` lets a file watcher see
the root go `placing` while the call runs. Because the reply is read after
it, a `.start` state can also change the reply of its own call
(`placing-reverted`). Other modes ignore it.

## State changes: `$INTAKE_MOCK_STATE/<command>.next`

Each line names a state under `scenarios/<scenario>/states/`. After a
successful `propose`, `assign`, `approve`, `reject`, `execute` or `gc`
(exit 0 or 1, not `--dry-run`) the mock removes the first line and applies
that state before it prints its reply, the same order the real CLI writes
sidecars in. Applying a state rewrites the affected sidecars in `root/`, so
file watchers see the change.

States in `default` (`cli-0.2.1`, `no-ranked` and `cli-0.1` keep their own
copies in their shapes; a state is taken whole from the last scenario in the
`base` chain that has it):

| State | Change |
|---|---|
| `b-proposed`, `b-approved`, `b-placed`, `b-gc_done` | walk `itk_0000000b` through the lifecycle; `b-placed` adds the library copy (and, under the 0.3.0 rules, drops b's assign replies) and `b-gc_done` deletes the local audio |
| `e-rejected` | rejects `itk_0000000e` (0.3.0: drops its assign replies) |
| `e-assigned` | user-assigns `itk_0000000e` to the `--collection` of the call that applied it: `assigned_by` `"user"`, confidence 1, the engine's `ranked` kept, `needs_review` still set, as with the real CLI |
| `approved-placing` | `itk_00000010` (approved) goes `placing`, as execute writes it first (for `execute.start`); its execute reply stays (the running call answers from it), its dry-run, assign and reject replies go (0.3.0 refuses them), and a `resumed: "completed"` resume reply is added |
| `approved-placed` | `itk_00000010` goes `placed` (`verified`, `journal_seq` 42) with its library copy under `root/library/music.hq/Test Collection A/`; its execute, dry-run, resume, assign and reject replies go, gc replies are added |
| `placing-placed` | `itk_00000011` (placing) goes `placed` (`journal_seq` 45) with its library copy under `Test Collection B/`, as a completed resume leaves it; its resume reply goes, gc replies are added |
| `placing-reverted` | `itk_00000011` goes back to `approved` (history `execute_reverted`) and its resume reply becomes `{"id", "root_path", "resumed": "reverted_to_approved"}`; execute and dry-run replies are added. Use it through `execute.start`: the resume call that applies it answers with the reverted row. The reverted reply stays until the next `--mock-setup` (assign and reject on the reverted root are not modelled) |
| `placed-gc_done` | B9, for `gc.next`: the placed root `itk_00000012` goes `gc_done` as the real gc leaves it: its local audio (`income/dump/Fixture Artist - Placed Album/01 - Test Track One.wav`, `02 - Test Track Two.wav`) is deleted, the sidecar stays as a `gc_done` tombstone (history `gc_done`), the library copy under `library/music.hq/Test Collection A/` stays, and its gc and gc dry-run replies go (a second gc gets `E_BAD_STATUS`) |
| `gc-e_verify` | B9, for `gc.start`: `gc itk_00000012` answers `E_VERIFY` "target re-verification failed: missing: 01 - Test Track One.wav" with `path` = its `placed.target_path` (exit 2 for that root alone, so `gc.next` is not applied); nothing is deleted. Stays until the next `--mock-setup` |
| `gc-e_no_journal` | B9, for `gc.start`: the same with `E_NO_JOURNAL` "journal record missing or mismatched", `path` = the root folder, as the CLI reports a journal mismatch |

For example, for the whole flow on one root:

```bash
cd "$INTAKE_MOCK_STATE"
echo b-proposed > propose.next; echo b-approved > approve.next
echo b-placed > execute.next;   echo b-gc_done > gc.next
```

A detached execute that a watcher sees go `placing`, then `placed` (B8):

```bash
cd "$INTAKE_MOCK_STATE"
echo approved-placing > execute.start   # at the start of `execute itk_00000010 --json`
echo 'slow-real 8' > execute.mode       # the real call runs 8 s; its dry run answers at once
echo approved-placed > execute.next     # at its end, before the reply is printed
```

Delete local copy (B9), done and failing:

```bash
echo placed-gc_done > gc.next           # gc itk_00000012: done, then gc_done, local audio gone
echo gc-e_verify > gc.start             # gc itk_00000012: E_VERIFY, still placed
echo gc-e_no_journal > gc.start         # gc itk_00000012: E_NO_JOURNAL, still placed
```

Resume, completed and reverted:

```bash
echo placing-placed > execute.next      # resume itk_00000011: completed, then placed
echo placing-reverted > execute.start   # resume itk_00000011: answers reverted_to_approved
```

### States in `uat`

One state per root it changes, so each checklist step writes its own line
just before the click that needs it (a `.next` file is a queue: a line
written early is taken by the next successful call of that command,
whichever root it names):

| State | For | Change |
|---|---|---|
| `uat-03-rejected` | `reject.next` | `itk_000a0003` goes `rejected` (history `rejected` with a fixed fixture reason, not the one typed); its reject, assign and propose replies go |
| `uat-01-rejected` | `reject.next` | the same for `itk_000a0001` |
| `uat-06-assigned` | `assign.next` | `itk_000a0006` user-assigned to the call's `--collection` (`assigned_by` `"user"`, confidence 1, the engine's `ranked` kept, `needs_review` still set) |
| `uat-07-placed` | `execute.next` | `itk_000a0007` goes `placed` (verified, `journal_seq` 42) with its library copy under `Test Collection A/`; its execute, dry-run, assign and reject replies go, gc replies are added |
| `uat-09-gc_done`, `uat-10-gc_done`, `uat-11-gc_done` | `gc.next` | that root goes `gc_done` as gc leaves it: its two local tracks are deleted, the sidecar stays as a tombstone, the library copy stays, its gc replies go |
| `uat-12-gc_done` | `gc.next` | the same for `itk_000a000c`, its shadow file included (gc deletes every local copy) |

```bash
cd "$INTAKE_MOCK_STATE"
echo uat-03-rejected > reject.next   # Reject… on itk_000a0003
echo uat-06-assigned > assign.next   # Assign to other collection… on itk_000a0006
echo uat-07-placed > execute.next    # Execute placement… on itk_000a0007 (the dry run leaves it)
echo uat-09-gc_done > gc.next        # Delete local copy… on itk_000a0009
```

## calls.log

`$INTAKE_MOCK_STATE/calls.log` gets one line per invocation, `--mock-setup`
included, with the arguments joined by tabs. A backslash, tab or newline
inside an argument is written as `\\`, `\t` or `\n`.

## Other environment variables

| Variable | Default | Effect |
|---|---|---|
| `INTAKE_MOCK_HANG_SECONDS` | 300 | how long the `hang` child sleeps |
| `INTAKE_MOCK_SLOW_SECONDS` | 2 | how long `slow` sleeps when its mode file gives no seconds |
| `INTAKE_MOCK_BIG_BYTES` | 1048576 | output size for `big` |
| `INTAKE_MOCK_FD_MAX` | 1024 | highest descriptor number `fds` checks, exclusive |

## How replies are built

`$INTAKE_MOCK_STATE/responses/`, copied from the scenario at setup:

- `commands`: the commands this CLI knows; anything else is
  `E_BAD_ARGS "unknown command: <name>"`, exit 2. A listed command the mock
  does not model (`scan`, `resolve`, `identify`, `bootstrap`) needs a
  `<name>.json` or `<name>.envelope` reply; without one the mock exits 64.
- `version.json`, `collections.json`: the `data` member. `default` lists the
  real CLI's command names in `version.json` `commands`; keep it in step
  with `commands`.
- `income`: one line per income folder, `<name><TAB><path under root/>`, in
  `income.yaml` order. `exists` is checked at call time, so creating or
  deleting the folder under `root/` changes it. A file with no entry gives
  `E_NO_RULES`, as the CLI does with no income folder configured.
- `cli-rules`: `0.3.0` or `0.2.1`, see above.
- `status.d/<id>.json`: one summary row per root, listed in id order. The
  real CLI sorts by sidecar path with `localeCompare`, so the order is
  unspecified and consumers must not rely on it. `--filter` follows the
  table above; a key the CLI knows but the summaries cannot answer
  (`income_folder`, `source_type`, `tier`, `virtual`, `singles`; and `id`
  under the 0.2.1 rules) makes the mock exit 64.
- `<key>.d/<id>.json` or `<key>.d/<id>.error`: the reply row, or the error
  object, for one root. The key is the command name, with a variant for
  `assign.user` (with `--collection`), `execute.dry-run`, `execute.resume`
  and `gc.dry-run`. Other `--dry-run` calls use the plain key, and `reject`
  rows then get `"dry_run": true`, as in the CLI.
- `<key>.envelope` (optional, plus `<key>.exit`): a complete stdout printed
  as is, for odd cases a test sets up itself. It skips the `.next` handling.

Roots are named by id or by directory. A directory is resolved lexically
like the CLI's `path.resolve` (`//`, `.` and `..`, relative to the current
directory) and selects every root whose `root_path` is spelled exactly like
the result. `--batch` is read by `approve` and `reject` only, as in the CLI.

A root with no reply file gets the CLI's
`E_BAD_STATUS "cannot <command> from status <s>"` when the CLI refuses that
status for the command, as doc 03 v1.2 "Legal source statuses" has it:

| Command | Legal source status |
|---|---|
| `assign` | `new`, `resolved`, `proposed`, `approved` (0.2.1 rules: any) |
| `propose` | `resolved` |
| `approve` | `proposed` |
| `reject` | `new`, `resolved`, `proposed`, `approved` |
| `execute` | `approved` |
| `execute --resume` | `placing` |
| `gc` | `placed` (0.2.1 rules: others skipped without an error) |

`identify` is not modelled. The all-roots forms (`propose --all-resolved`,
`execute --approved`, `execute --resume` without roots, `gc --all`) select
roots in a legal status and skip the rest without an error. A root in an
accepted status with no reply file is a gap in the scenario: the mock exits
64 instead of inventing a refusal. Unknown ids and other refs get the CLI's
`E_NOT_FOUND` messages. Exit codes and `data` follow the CLI's `finish()`:
0 with rows, 1 with rows and errors, 2 with `data: null`.

A root named twice is answered once per occurrence, except by `reject`,
which skips the repeat like the CLI. The real CLI answers a repeat from the
status the first occurrence left behind (`approve` and `propose` refuse it
with `E_BAD_STATUS`, for example). Consumers should pass each id once.

A fixture directory (a scenario or a state) may hold `responses/`, `tree/`
(copied into `root/`), `delete` (paths under the state directory to remove,
starting with `responses/` or `root/`), `base` (the scenario it extends) and
`generate` (`roots <n>`). In text fixtures `@ROOT@` becomes
`$INTAKE_MOCK_STATE/root`; in state files, and in `assign.user.d` replies,
`@COLLECTION@` becomes the call's `--collection` and `@COLLECTION_DIR@`
(used in `target_path`) the same name as the CLI's `sanitizeComponent` makes
it a folder name (`/`, `\` and `:` become `-`, control characters are
dropped, leading and trailing spaces and dots trimmed). Every `*.wav` is written as
a 0.1 s silent WAV (PCM, mono, 8 kHz, 8 bit), so foobar2000 can list the
tracks. A RIFF `LIST`/`INFO` chunk after the audio tags it with `IPRD`
(album) = its parent folder's name and `INAM` (title) = its file name without
the extension, so SimPlaylist's default header pattern puts each folder in
its own group (the five loose tracks share one). The mock refuses to
apply a state when it finds a symlink under `root/` or `responses/`.
