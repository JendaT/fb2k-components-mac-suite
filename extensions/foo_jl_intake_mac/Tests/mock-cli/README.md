# intake-mock

A fake `intake` CLI for testing foo_jl_intake_mac without the real tool or
real music. It prints the doc 03 envelope (`{ok, data, errors}`, contract
v1.1) with the data shapes of CLI 0.2.1 (branch `feature/intake-cli`) for
`version`, `status`, `collections`, `propose`, `assign`, `approve`,
`reject`, `execute` (with `--dry-run` and `--resume`) and `gc`.

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

foobar2000 does not pass this variable on. To point the component at the
mock, write a small wrapper in your scratch folder (never in the repo) that
exports `INTAKE_MOCK_STATE` and runs `exec .../intake-mock "$@"`.

`--mock-setup <scenario>` throws away `root/`, `responses/`, every `*.mode`
and `*.next` file and `hang.pid`, then copies the scenario in. `calls.log` is
kept.

## Scenarios (`scenarios/<name>/`)

| Scenario | What it is |
|---|---|
| `default` | 15 roots in `income/dump` and `income/shop`: every status (`new`, `resolved`, `proposed`, `approved`, `placing`, `placed`, `gc_done`, `rejected`); `needs_review` on a resolved root, an engine proposal and a user override; `ranked` on every engine proposal and `[]` on a user-only one; a Various Artists root with `structure_slot: compilations` and a null target (propose refuses it with `E_NO_TARGET`); two virtual roots sharing one folder; library copies of the placed and gc_done roots under `root/library/` |
| `no-ranked` | `default` without `proposal.ranked` anywhere |
| `cli-0.1` | `default` as CLI 0.1.0 would show it: `version` reports 0.1.0, `reject` is an unknown command, no rejected root, no `ranked` |
| `schema2` | `default` with `"schema": 2` in `version` |
| `schema-string` | `default` with `"schema": "1"` (a string) in `version` |
| `perf-200` | 200 generated roots in `income/perf`, statuses cycling through the lifecycle |

The `default` ids are `itk_0000000a` to `itk_00000018`; `status --json` lists
them with their states.

## Modes: `$INTAKE_MOCK_STATE/<command>.mode`

The file holds a mode name (`exit2` also takes an error code) and applies to
every call of that command until you delete it. Modes never apply `.next`
states.

| Mode | Output |
|---|---|
| `exit2 [CODE]` | exit 2, `data: null`, one error (`E_INTERNAL` unless CODE is given, e.g. `exit2 E_NO_RULES`) |
| `partial` | exit 1, `ok: false`, the normal data plus an `E_PARSE` error |
| `garbage` | text that is not JSON, exit 0 |
| `empty` | nothing on stdout, exit 0 |
| `bare-array` | the data array alone (`[]` for object data), exit 0 |
| `noise` | about 140 KB of warnings on stderr, then the normal envelope wrapped in blank lines |
| `hang` | starts `sleep` as a child (not exec) and waits for it. Writes `<shell pid> <child pid>` to `hang.pid`. Killing only the shell leaves the child holding stdout open, so the caller has to kill the process group |
| `big` | about 1 MB of valid status-shaped rows, written row by row, exit 0 |
| `unknown-code` | exit 2 with the error code `E_MOCK_UNKNOWN_CODE` |
| `fds` | `{"ok":true,"data":{"fds":[0,1,2]},"errors":[]}`: the descriptors open in the spawned process, read from `/dev/fd` after an exec, so bash's own script descriptor is not listed |

An unknown mode word makes the mock exit 64.

## State changes: `$INTAKE_MOCK_STATE/<command>.next`

Each line names a state under `scenarios/<scenario>/states/`. After a
successful `propose`, `assign`, `approve`, `reject`, `execute` or `gc`
(exit 0 or 1, not `--dry-run`) the mock removes the first line and applies
that state before it prints its reply, the same order the real CLI writes
sidecars in. Applying a state rewrites the affected sidecars in `root/`, so
file watchers see the change.

States in `default`:

| State | Change |
|---|---|
| `b-proposed`, `b-approved`, `b-placed`, `b-gc_done` | walk `itk_0000000b` through the lifecycle; `b-placed` adds the library copy and `b-gc_done` deletes the local audio |
| `e-rejected` | rejects `itk_0000000e` |
| `e-assigned` | user-assigns `itk_0000000e` to the `--collection` of the call that applied it; `needs_review` stays set, as with the real CLI |

For example, for the whole flow on one root:

```bash
cd "$INTAKE_MOCK_STATE"
echo b-proposed > propose.next; echo b-approved > approve.next
echo b-placed > execute.next;   echo b-gc_done > gc.next
```

## calls.log

`$INTAKE_MOCK_STATE/calls.log` gets one line per invocation, `--mock-setup`
included, with the arguments joined by tabs. A backslash, tab or newline
inside an argument is written as `\\`, `\t` or `\n`.

## Other environment variables

| Variable | Default | Effect |
|---|---|---|
| `INTAKE_MOCK_HANG_SECONDS` | 300 | how long the `hang` child sleeps |
| `INTAKE_MOCK_BIG_BYTES` | 1048576 | output size for `big` |
| `INTAKE_MOCK_FD_MAX` | 1024 | highest descriptor number `fds` checks, exclusive |

## How replies are built

`$INTAKE_MOCK_STATE/responses/`, copied from the scenario at setup:

- `commands`: the commands this CLI knows; anything else is
  `E_BAD_ARGS "unknown command: <name>"`, exit 2.
- `version.json`, `collections.json`: the `data` member.
- `status.d/<id>.json`: one summary row per root, listed in id order.
  `--filter` works for `status`, `needs_review`, `root_path`, `albumartist`
  and `album`; another key makes the mock exit 64.
- `<key>.d/<id>.json` or `<key>.d/<id>.error`: the reply row, or the error
  object, for one root. The key is the command name, with a variant for
  `assign.user` (with `--collection`), `execute.dry-run`, `execute.resume`
  and `gc.dry-run`. Other `--dry-run` calls use the plain key, and `reject`
  rows then get `"dry_run": true`, as in the CLI.
- `<key>.envelope` (optional, plus `<key>.exit`): a complete stdout printed
  as is, for odd cases a test sets up itself. It skips the `.next` handling.

Roots are named by id or by directory. A directory selects every root whose
`root_path` is spelled exactly like it. A root with no reply file gets the
CLI's `E_BAD_STATUS "cannot <command> from status <s>"`; `gc` skips it
silently, like the CLI (CR-004.14). Unknown ids and other refs get the CLI's
`E_NOT_FOUND` messages. Exit codes and `data` follow the CLI's `finish()`:
0 with rows, 1 with rows and errors, 2 with `data: null`.

A fixture directory (a scenario or a state) may hold `responses/`, `tree/`
(copied into `root/`), `delete` (paths under the state directory to remove,
starting with `responses/` or `root/`), `base` (the scenario it extends) and
`generate` (`roots <n>`). In text fixtures `@ROOT@` becomes
`$INTAKE_MOCK_STATE/root`; in state files, and in `assign.user.d` replies,
`@COLLECTION@` becomes the call's `--collection`. Every `*.wav` is written as
a 0.1 s silent WAV, so foobar2000 can list the tracks. The mock refuses to
apply a state when it finds a symlink under `root/` or `responses/`.
