#!/bin/bash
#
# run_flow.sh <dest> [steps]      run the REAL intake CLI on a corpus made by
#                                 make_corpus.sh and assert every status
# run_flow.sh <dest> --cli-wrapper  only (re)write <dest>/bin/intake-e2e and
#                                 print it, for the component's cli_path
#
# All CLI calls go through <dest>/bin/intake-e2e (see e2e_lib.sh): env -i,
# HOME=<dest>/home (no ~/.config/intake/config.toml), INTAKE_RULES_DIR=
# <dest>/rules, INTAKE_CACHE_DIR=<dest>/cache, DISCOGS_TOKEN/LASTFM_API_KEY
# unset, beets shim stubbed, bun auto-install off, DO_NOT_TRACK=1. Nothing
# in the flow needs the network: identify runs offline (unconfirmed).
#
# Refuses (exit 64, before any CLI call) unless <dest> resolves below
# $TMPDIR or a session scratchpad, is not under /Volumes or /volume1, holds
# the make_corpus.sh marker naming this location, has no symlinks in it, its
# rules files are the ones make_corpus.sh wrote (pinned by hash), its rules
# dir resolves inside <dest> and every rules path resolves inside <dest>.
# Before every step it also refuses when an execute may be running on the
# corpus (guard_no_live_run). --cli-wrapper saves the component settings it
# is about to replace (read only) and prints how to put them back.
#
# Expectations are derived from the CLI source at 0.3.0 (feature/intake-cli
# d00daff8). Only the orchestrator runs this; it is not a build gate.
# Needs: jq, bun, the CLI worktree; metaflac for the provenance check.
# Bash 3.2 compatible.

set -u
set -o pipefail

E2E_SELF=run_flow.sh
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=e2e_lib.sh
. "$HERE/e2e_lib.sh"

ALL_STEPS="preflight scan reject assign identify propose approve execute resume gc"

usage() {
    cat >&2 <<'EOF'
usage: run_flow.sh <dest> [steps]
       run_flow.sh <dest> --cli-wrapper

steps (default: all):
  all          preflight scan reject assign identify propose approve execute resume gc
  to-approved  stop at approved   (in-app B8 check: Execute from foobar2000)
  to-placed    stop at placed     (in-app B9 check: Swap / Delete local copy)
  a,b,c        any comma-separated subset of the step names, run in order given

Run on a fresh corpus (make_corpus.sh); `gc` alone may follow `to-placed`.
Env overrides: INTAKE_E2E_BUN (bun binary), INTAKE_E2E_CLI (cli.ts path).
EOF
    exit "${1:-64}"
}

[ $# -ge 1 ] || usage
case $1 in
    -h|--help) usage 0 ;;
esac
ARG_DEST=$1
shift
MODE=flow
STEPS_ARG=all
if [ $# -gt 0 ]; then
    case $1 in
        --cli-wrapper) MODE=wrapper ;;
        -*) usage ;;
        *) STEPS_ARG=$1 ;;
    esac
    shift
fi
[ $# -eq 0 ] || usage

case $STEPS_ARG in
    all) STEPS=$ALL_STEPS ;;
    to-approved) STEPS="preflight scan reject assign identify propose approve" ;;
    to-placed) STEPS="preflight scan reject assign identify propose approve execute resume" ;;
    *)
        STEPS=$(printf '%s' "$STEPS_ARG" | tr ',' ' ')
        for s in $STEPS; do
            case " $ALL_STEPS " in
                *" $s "*) ;;
                *) e2e_die "unknown step: $s (known: $ALL_STEPS)" ;;
            esac
        done
        ;;
esac

# --- Guards: nothing below runs unless these pass ---------------------------
DEST=$(e2e_guard_dest "$ARG_DEST" existing) || exit 64
command -v jq >/dev/null 2>&1 || e2e_die "jq not found"
BUN=$(e2e_find_bun) || e2e_die "bun not found (set INTAKE_E2E_BUN)"
CLI=$(e2e_default_cli)
case $CLI in
    /*) ;;
    *) e2e_die "CLI path must be absolute: $CLI" ;;
esac
[ -f "$CLI" ] || e2e_die "CLI not found: $CLI (set INTAKE_E2E_CLI)"

WRAPPER=$(e2e_write_wrapper "$DEST" "$BUN" "$CLI") || e2e_die "cannot write the wrapper"

# The component settings the in-app check replaces. Read only, never
# written here: saved once per corpus (a second --cli-wrapper run would
# otherwise save the e2e values), with a SQL file that puts them back.
CONFIG_DB="$HOME/Library/foobar2000-v2/config.sqlite"
PREFS_KEYS="cli_path bun_path rules_dir watch_folders swap_prefix_from swap_prefix_to"
PREFS_BEFORE="$DEST/logs/prefs-before.txt"
PREFS_RESTORE="$DEST/logs/prefs-restore.sql"

save_prefs() {
    local names="" k
    for k in $PREFS_KEYS; do names="$names${names:+,}'foo_jl_intake.$k'"; done
    if [ -s "$PREFS_RESTORE" ]; then
        echo "saved earlier (kept): $PREFS_BEFORE"
        return 0
    fi
    if ! command -v sqlite3 >/dev/null 2>&1 || [ ! -f "$CONFIG_DB" ]; then
        echo "NOT saved (no sqlite3 or no $CONFIG_DB): note the current values by hand before changing them"
        return 1
    fi
    mkdir -p "$DEST/logs" || return 1
    if ! sqlite3 -readonly "$CONFIG_DB" \
        "SELECT name || ' = ' || quote(value) FROM configStrings WHERE name IN ($names) ORDER BY name;" \
        > "$PREFS_BEFORE"; then
        echo "NOT saved (cannot read $CONFIG_DB): note the current values by hand before changing them"
        return 1
    fi
    local inserts
    if ! inserts=$(sqlite3 -readonly "$CONFIG_DB" \
        "SELECT 'INSERT INTO configStrings(name,value) VALUES(' || quote(name) || ',' || quote(value) || ');' FROM configStrings WHERE name IN ($names) ORDER BY name;"); then
        echo "NOT saved (cannot read $CONFIG_DB): note the current values by hand before changing them"
        return 1
    fi
    if ! {
        echo "-- foo_jl_intake settings as run_flow.sh --cli-wrapper found them on $(date '+%Y-%m-%d %H:%M:%S')."
        echo "-- Quit foobar2000 first, then: sqlite3 $CONFIG_DB < $PREFS_RESTORE"
        echo "BEGIN;"
        echo "DELETE FROM configStrings WHERE name IN ($names);"
        [ -z "$inserts" ] || printf '%s\n' "$inserts"
        echo "COMMIT;"
    } > "$PREFS_RESTORE.tmp" || ! mv "$PREFS_RESTORE.tmp" "$PREFS_RESTORE"; then
        rm -f "$PREFS_RESTORE.tmp"
        echo "NOT saved (cannot write $PREFS_RESTORE): note the current values by hand before changing them"
        return 1
    fi
    echo "saved: $PREFS_BEFORE"
    return 0
}

if [ "$MODE" = wrapper ]; then
    cat <<EOF
wrapper: $WRAPPER
  runs:  $BUN run --no-install $CLI <args>
  env:   HOME=$DEST/home INTAKE_RULES_DIR=$DEST/rules INTAKE_CACHE_DIR=$DEST/cache (env -i, no tokens)

Current component settings (they are about to be replaced):
EOF
    saved=$(save_prefs) || true
    printf '  %s\n' "$saved"
    if [ -s "$PREFS_BEFORE" ]; then
        sed 's/^/    /' "$PREFS_BEFORE"
    elif [ -f "$PREFS_BEFORE" ]; then
        echo "    (none of them is set)"
    fi
    cat <<EOF

For the in-app check: ask the user before quitting foobar2000, and only
when it is idle and nothing is playing. With foobar2000 quit, set in
config.sqlite:
  foo_jl_intake.cli_path       $WRAPPER
  foo_jl_intake.rules_dir      leave empty (the wrapper always uses $DEST/rules)
  foo_jl_intake.watch_folders  $DEST/income
  swap prefixes                leave empty (library copies are local, under $DEST/library)

Afterwards (foobar2000 quit again, before <dest> is removed), put the saved
settings back:
  sqlite3 $CONFIG_DB < $PREFS_RESTORE
EOF
    exit 0
fi

# --- Corpus facts (must match make_corpus.sh) --------------------------------
LIB="$DEST/library"
HQ="$LIB/music.hq"
UHQ="$LIB/music.uhq"
JOURNAL="$LIB/music.meta/intake-journal.ndjson"
UNTAGGED_DIR="$DEST/income/manual/zz_unsorted_e2e"
DUMP_DIR="$DEST/income/soulseek/mixed_dump_e2e"
ALL_KEYS="A B C D1 D2 DS E F G H"
PLACE_KEYS="A B C D1 D2 E F"

LOGS="$DEST/logs/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS" || e2e_die "cannot create $LOGS"

# jq selector of each root inside a status --json row ($untagged is passed in).
sel_of() {
    case $1 in
        A) echo '.cluster.album == "Synthetic Album"' ;;
        B) echo '.cluster.album == "Doubled Album"' ;;
        C) echo '.cluster.album == "Fixture Compilation E2E"' ;;
        D1) echo '.cluster.album == "Mixed Album One E2E"' ;;
        D2) echo '.cluster.album == "Mixed Album Two E2E"' ;;
        DS) echo '.cluster.albumartist == "Fixture Stray E2E"' ;;
        E) echo '.cluster.album == "Lone Track"' ;;
        F) echo '.cluster.album == "High Rate"' ;;
        G) echo '.cluster.album == "Unwanted"' ;;
        H) echo '.root_path == $untagged' ;;
        *) echo 'false' ;;
    esac
}

name_of() {
    case $1 in
        A) echo "normal album" ;;
        B) echo "shadow album" ;;
        C) echo "VA compilation" ;;
        D1) echo "virtual root, FLAC" ;;
        D2) echo "virtual root, MP3" ;;
        DS) echo "loose single" ;;
        E) echo "one-track release" ;;
        F) echo "hi-res" ;;
        G) echo "rejected" ;;
        H) echo "untagged" ;;
    esac
}

# --- Result bookkeeping ------------------------------------------------------
PASS=0
FAIL=0
FAILED=""
pass() {
    PASS=$((PASS + 1))
    printf '  PASS  %s\n' "$1"
}
fail() {
    FAIL=$((FAIL + 1))
    FAILED="$FAILED
  - $1"
    printf '  FAIL  %s%s\n' "$1" "${2:+  ($2)}"
}
check() {    # check <name> <command...>
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

# --- CLI calls ---------------------------------------------------------------
N=0
OUT=""
RC=0
STATUS=""
IDS=""

# cli <label> <args...>: runs the wrapper with --json; OUT = stdout file, RC.
# Checks the envelope invariants (doc 03): one object with bool ok, array
# errors and a data key; ok iff exit 0; exit in 0..2; data null on exit 2.
cli() {
    local label=$1 ok
    shift
    N=$((N + 1))
    OUT=$(printf '%s/%03d-%s.json' "$LOGS" "$N" "$label")
    printf '%s\n' "$*" > "${OUT%.json}.cmd"
    "$WRAPPER" "$@" --json > "$OUT" 2> "${OUT%.json}.err"
    RC=$?
    if [ "$RC" -eq 64 ] || [ "$RC" -eq 127 ]; then
        fail "$label: wrapper refused or CLI missing (exit $RC)" "$(head -c 300 "${OUT%.json}.err")"
        return 1
    fi
    if ! jq -s -e 'length == 1 and (.[0] | type == "object" and (.ok | type == "boolean") and (.errors | type == "array") and has("data"))' "$OUT" >/dev/null 2>&1; then
        fail "$label: one JSON envelope on stdout" "exit $RC, see $OUT"
        return 1
    fi
    ok=$(jq -r '.ok' "$OUT")
    case "$ok:$RC" in
        true:0|false:1|false:2) ;;
        *) fail "$label: ok matches exit code" "ok=$ok exit=$RC, see $OUT"; return 1 ;;
    esac
    if [ "$RC" -eq 2 ] && ! jq -e '.data == null' "$OUT" >/dev/null 2>&1; then
        fail "$label: data is null on exit 2" "see $OUT"
        return 1
    fi
    return 0
}

first_error() {
    jq -r '.errors[0] | "\(.code): \(.msg)"' "$OUT" 2>/dev/null
}

expect_rc() {    # expect_rc <label> <code>
    if [ "$RC" -eq "$2" ]; then
        pass "$1: exit $2"
    else
        fail "$1: exit $2" "got $RC; $(first_error)"
    fi
}

ok_jq() {    # ok_jq <name> <filter> [jq args]: filter on the last reply
    local name=$1 filter=$2
    shift 2
    if jq -e --arg untagged "$UNTAGGED_DIR" --arg dest "$DEST" --arg lib "$LIB" "$@" "$filter" "$OUT" >/dev/null 2>&1; then
        pass "$name"
    else
        fail "$name" "jq '$filter' on $OUT"
    fi
}

expect_error() {    # expect_error <label> <code> [msg substring]
    local label=$1 code=$2 sub=${3:-}
    expect_rc "$label" 2
    ok_jq "$label: $code${sub:+ ($sub)}" '.errors[0].code == $code and (.errors[0].msg | contains($sub))' \
        --arg code "$code" --arg sub "$sub"
}

snap() {
    if cli status status; then
        STATUS=$OUT
    else
        STATUS=""
    fi
}

st_jq() {    # st_jq <name> <filter> [jq args]: filter on the last status
    local name=$1 filter=$2
    shift 2
    if [ -n "$STATUS" ] && jq -e --arg untagged "$UNTAGGED_DIR" --arg dest "$DEST" --arg lib "$LIB" "$@" "$filter" "$STATUS" >/dev/null 2>&1; then
        pass "$name"
    else
        fail "$name" "jq '$filter' on ${STATUS:-<no status>}"
    fi
}

rfield() {    # rfield <key> <jq path>: field of the one matching status row
    [ -n "$STATUS" ] || return 1
    jq -r --arg untagged "$UNTAGGED_DIR" \
        "[.data[] | select($(sel_of "$1"))] | if length == 1 then .[0]$2 else empty end" "$STATUS" 2>/dev/null
}

rid() { rfield "$1" .id; }

# ids_of <keys...>: prints the ids, or "missing: <keys>" and returns 1. Runs
# inside $(...), so it must not call fail (the count would be lost).
ids_of() {
    local k id out="" missing=""
    for k in "$@"; do
        id=$(rid "$k")
        if [ -n "$id" ]; then out="$out $id"; else missing="$missing $k"; fi
    done
    if [ -n "$missing" ]; then
        printf 'missing:%s\n' "$missing"
        return 1
    fi
    printf '%s\n' "$out"
}

need_place_ids() {    # sets IDS to the 7 placeable roots' ids, or records a failure
    IDS=$(ids_of $PLACE_KEYS) && return 0
    fail "the 7 placeable roots are in status" "$IDS"
    return 1
}

expect_root() {    # expect_root <key> <status> <needs_review>
    local key=$1 st=$2 nr=$3 got
    [ -n "$STATUS" ] || { fail "$key: status available"; return; }
    got=$(jq -r --arg untagged "$UNTAGGED_DIR" \
        "[.data[] | select($(sel_of "$key"))] | if length == 1 then \"\(.[0].status) \(.[0].needs_review)\" else \"matches=\(length)\" end" "$STATUS")
    if [ "$got" = "$st $nr" ]; then
        pass "$key ($(name_of "$key")): $st, needs_review=$nr"
    else
        fail "$key ($(name_of "$key")): $st, needs_review=$nr" "got: $got"
    fi
}

sidecar_of() {
    local root id
    root=$(rfield "$1" .root_path)
    id=$(rfield "$1" .id)
    if [ -n "$id" ] && [ -f "$root/.intake.$id.json" ]; then
        printf '%s\n' "$root/.intake.$id.json"
    else
        printf '%s\n' "$root/.intake.json"
    fi
}

sc_jq() {    # sc_jq <name> <key> <filter>: filter on the root's sidecar file
    local name=$1 sc
    sc=$(sidecar_of "$2")
    if [ -f "$sc" ] && jq -e "$3" "$sc" >/dev/null 2>&1; then
        pass "$name"
    else
        fail "$name" "jq '$3' on $sc"
    fi
}

expect_target() {    # expect_target <key> <slot dir> <album>: release folder directly in the slot
    local key=$1 slot=$2 al=$3
    if [ -n "$STATUS" ] && jq -e --arg untagged "$UNTAGGED_DIR" --arg p "$slot/" --arg al "$al" \
        "[.data[] | select($(sel_of "$key"))][0].proposal.target_path | . != null and startswith(\$p) and (ltrimstr(\$p) | contains(\$al)) and (ltrimstr(\$p) | contains(\"/\") | not)" \
        "$STATUS" >/dev/null 2>&1; then
        pass "$key target: ${slot#"$LIB"/}/...$al..."
    else
        fail "$key target: ${slot#"$LIB"/}/...$al..." "got $(rfield "$key" .proposal.target_path)"
    fi
}

# check_library <key>: every primary file at target/<path>, no shadow copied.
check_library() {
    local key=$1 sc target kind path missing=0 shadows=0 total=0
    sc=$(sidecar_of "$key")
    target=$(rfield "$key" .placed.target_path)
    if [ -z "$target" ] || [ "$target" = null ] || [ ! -f "$sc" ]; then
        fail "$key library copy: placed target known"
        return
    fi
    while IFS=$'\t' read -r kind path; do
        total=$((total + 1))
        if [ "$kind" = P ]; then
            [ -f "$target/$path" ] || missing=$((missing + 1))
        else
            [ -e "$target/$path" ] && shadows=$((shadows + 1))
        fi
    done < <(jq -r '.files[] | (if .quality_shadow == true then "S" else "P" end) + "\t" + .path' "$sc")
    if [ "$total" -gt 0 ] && [ "$missing" -eq 0 ] && [ "$shadows" -eq 0 ]; then
        pass "$key library copy: all primary files present, no shadows"
    else
        fail "$key library copy: all primary files present, no shadows" "files=$total missing=$missing shadows_copied=$shadows in $target"
    fi
}

# set_status <key> <status>: hand-edit the root's sidecar status (synthetic
# corpus only; to make `placing` roots for the resume checks).
set_status() {
    local sc
    sc=$(sidecar_of "$1")
    case $sc in
        "$DEST"/income/?*) ;;
        *) fail "$1: sidecar inside the corpus" "$sc"; return 1 ;;
    esac
    if [ ! -f "$sc" ] || [ -L "$sc" ]; then
        fail "$1: sidecar found" "$sc"
        return 1
    fi
    if jq --arg s "$2" '.status = $s' "$sc" > "$sc.e2e-tmp" && mv "$sc.e2e-tmp" "$sc"; then
        pass "$1: sidecar hand-set to $2"
    else
        rm -f "$sc.e2e-tmp"
        fail "$1: sidecar hand-set to $2"
        return 1
    fi
}

count_audio() {    # count_audio <dir>: audio files directly in dir
    find "$1" -maxdepth 1 -type f \( -name '*.flac' -o -name '*.mp3' \) 2>/dev/null | wc -l | tr -d ' '
}

journal_count() {    # journal_count <event>
    [ -f "$JOURNAL" ] || { echo 0; return; }
    jq -s --arg e "$1" '[.[] | select(.event == $e)] | length' "$JOURNAL" 2>/dev/null || echo -1
}

# --- Guard against a live execute on this corpus ------------------------------
# The in-app B8 check runs a detached execute from foobar2000 on this corpus,
# and the CLI has no locking: a step that runs `execute` (or `--resume`)
# beside it would share its .intake-tmp-<id> dir. Before every step, refuse
# when a root is placing, a .intake-tmp-* dir exists in the library, or a
# component run file (~/Library/Caches/foo_jl_intake/execute-*.run, read
# only) names a live pid or has no pid yet.
COMPONENT_CACHE="$HOME/Library/Caches/foo_jl_intake"

guard_no_live_run() {
    local tmp f pid n
    tmp=$(find "$LIB" -name '.intake-tmp-*' -print 2>/dev/null)
    [ -z "$tmp" ] || e2e_die "an execute may be running on this corpus: ${tmp%%$'\n'*} exists"
    for f in "$COMPONENT_CACHE"/execute-*.run; do
        [ -f "$f" ] || continue
        pid=$(jq -r '.pid // empty' "$f" 2>/dev/null) || pid=""
        [ -n "$pid" ] || e2e_die "the component has a run file without a pid: $f (let foobar2000 settle it first)"
        case $pid in
            *[!0-9]*) e2e_die "unreadable component run file: $f" ;;
        esac
        ! kill -0 "$pid" 2>/dev/null || e2e_die "a foobar2000 execute run is live (pid $pid, $f): wait until it ends"
    done
    "$WRAPPER" status --json > "$LOGS/guard-status.json" 2> "$LOGS/guard-status.err"
    n=$(jq -e '[.data // [] | .[] | select(.status == "placing")] | length' "$LOGS/guard-status.json" 2>/dev/null) ||
        e2e_die "cannot read status before the step (see $LOGS/guard-status.err)"
    [ "$n" -eq 0 ] || e2e_die "$n root(s) are placing: an execute may be running on this corpus"
}

# --- Steps -------------------------------------------------------------------

step_preflight() {
    cli version version || return 1
    expect_rc version 0
    ok_jq "version: schema == 1" '.data.schema == 1'
    ok_jq "version: commands cover the B8/B9 surface" \
        '(["scan","resolve","identify","assign","propose","approve","reject","execute","gc","status","income","collections","version"] - .data.commands) == []'
    printf '        cli %s, engine %s\n' "$(jq -r '.data.cli' "$OUT")" "$(jq -r '.data.engine' "$OUT")"

    cli income income || return 1
    expect_rc income 0
    ok_jq "income: 3 folders, all inside the corpus and present" \
        '(.data | length) == 3 and all(.data[]; (.path | startswith($dest + "/income/")) and .exists == true)'

    cli collections collections || return 1
    expect_rc collections 0
    ok_jq "collections: synthetic genre map ([E2E Ambient], [E2E Downtempo])" \
        '(["[E2E Ambient]", "[E2E Downtempo]"] - [.data[].collection]) == []'

    snap
    st_jq "status: every root inside the corpus income folders" 'all(.data[]; .root_path | startswith($dest + "/income/"))'
}

step_scan() {
    local k
    cli scan scan --all || return 1
    expect_rc scan 0
    ok_jq "scan: 3 income blocks, not dry-run, no archives" \
        '(.data | length) == 3 and all(.data[]; .dry_run == false and (.archives | length) == 0)'
    ok_jq "scan: 10 sidecars written" '[.data[].written[]] | length == 10'

    snap
    st_jq "status: 10 roots" '.data | length == 10'
    for k in $ALL_KEYS; do
        st_jq "status: exactly one row for $k ($(name_of "$k"))" "[.data[] | select($(sel_of "$k"))] | length == 1"
    done
    expect_root A resolved false
    expect_root B resolved false
    expect_root C resolved false
    expect_root D1 resolved true
    expect_root D2 resolved true
    expect_root DS resolved true
    expect_root E resolved false
    expect_root F resolved false
    expect_root G resolved false
    expect_root H new true

    st_jq "C credited to Various Artists" "[.data[] | select($(sel_of C))][0].cluster.albumartist == \"Various Artists\""
    sc_jq "A: whole-dir root, tier hq" A '.virtual == false and .quality.tier_eligible == "hq"'
    sc_jq "B: the 2 MP3s are quality shadows" B \
        '([.files[] | select(.quality_shadow == true) | .codec] == ["mp3", "mp3"]) and (.quality.issues | any(. == "quality_shadow_set:mp3"))'
    sc_jq "D1: virtual root" D1 '.virtual == true and (.singles // false) == false'
    sc_jq "D2: virtual root, lossy hq" D2 '.virtual == true and .quality.tier_eligible == "hq" and (.quality.issues | any(. == "lossy"))'
    sc_jq "DS: virtual singles root" DS '.virtual == true and .singles == true'
    sc_jq "F: tier uhq" F '.quality.tier_eligible == "uhq"'
    check "D: 3 sidecars in the dump dir" test "$(find "$DUMP_DIR" -maxdepth 1 -name '.intake.*.json' | wc -l | tr -d ' ')" -eq 3

    cli status-singles status --filter singles=true || return 1
    ok_jq "status --filter singles=true: only DS" '(.data | length) == 1 and .data[0].id == $id' --arg id "$(rid DS)"
    cli status-uhq status --filter tier=uhq || return 1
    ok_jq "status --filter tier=uhq: only F" '(.data | length) == 1 and .data[0].id == $id' --arg id "$(rid F)"

    cli rescan scan --all || return 1
    expect_rc rescan 0
    ok_jq "rescan: nothing written, 8 dirs kept" '([.data[].written[]] | length) == 0 and ([.data[].kept[]] | length) == 8'

    cli resolve-kept resolve "$UNTAGGED_DIR" || return 1
    expect_rc resolve-kept 0
    ok_jq "resolve: existing sidecar kept" '(.data.written | length) == 0 and .data.kept == [$untagged]'
    cli resolve-force-dry resolve "$UNTAGGED_DIR" --force --dry-run || return 1
    expect_rc resolve-force-dry 0
    ok_jq "resolve --force --dry-run: rebuild computed, status new" \
        '.data.dry_run == true and (.data.written | length) == 1 and .data.written[0].status == "new"'
    snap
    expect_root H new true
}

step_reject() {
    local g
    snap
    g=$(rfield G .root_path)
    [ -n "$g" ] || { fail "G found in status"; return 1; }
    cli reject reject "$g" --reason "e2e synthetic reject" || return 1
    expect_rc reject 0
    ok_jq "reject: G -> rejected" '(.data | length) == 1 and .data[0].status == "rejected"'
    snap
    expect_root G rejected false
    sc_jq "G: history ends with rejected + reason" G '.history[-1].event == "rejected" and .history[-1].reason == "e2e synthetic reject"'
    cli reject-again reject "$g" || return 1
    expect_error reject-again E_BAD_STATUS
}

step_assign() {
    local b
    snap
    b=$(rfield B .root_path)
    [ -n "$b" ] || { fail "B found in status"; return 1; }
    cli assign-user assign "$b" --collection "[E2E Downtempo]" --by user || return 1
    expect_rc assign-user 0
    ok_jq "assign --collection: B by user to [E2E Downtempo]" \
        '.data[0].assigned_by == "user" and .data[0].target_collection == "[E2E Downtempo]"'
    snap
    st_jq "B: still resolved, proposal by user, ranked []" \
        "[.data[] | select($(sel_of B))][0] | .status == \"resolved\" and .proposal.assigned_by == \"user\" and .proposal.ranked == [] and .proposal.target_collection == \"[E2E Downtempo]\""
    check "rules: override logged for Fixture Shadow E2E" grep -q "Fixture Shadow E2E" "$DEST/rules/overrides.log.yaml"
    check "rules: genre-map feedback for Fixture Shadow E2E" grep -q "Fixture Shadow E2E" "$DEST/rules/genre-map.yaml"
    cli assign-rejected assign "$(rid G)" --collection "[E2E Ambient]" || return 1
    expect_error assign-rejected E_BAD_STATUS
}

step_identify() {
    local a
    snap
    a=$(rid A)
    [ -n "$a" ] || { fail "A found in status"; return 1; }
    cli identify identify "$a" || return 1
    expect_rc identify 0
    ok_jq "identify (offline): unconfirmed, beets stub answered, needs_review" \
        '.data[0].status == "unconfirmed" and (.data[0].issues | any(. == "beets_unavailable")) and .data[0].needs_review == true'
    ok_jq "identify: Discogs not attempted (no token)" '.data[0].issues | any(. == "discogs_unreachable") | not'
    snap
    expect_root A resolved true
    cli identify-rejected identify "$(rid G)" || return 1
    expect_error identify-rejected E_BAD_STATUS
}

step_propose() {
    local k
    snap
    need_place_ids || return 1
    # shellcheck disable=SC2086
    cli propose propose $IDS || return 1
    expect_rc propose 0
    ok_jq "propose: 7 roots -> proposed" '(.data | length) == 7 and all(.data[]; .status == "proposed")'
    snap
    for k in $PLACE_KEYS; do expect_root "$k" proposed true; done
    expect_target A "$HQ/[E2E Ambient]/Fixture Artist E2E" "Synthetic Album"
    expect_target B "$HQ/[E2E Downtempo]/[Releases]" "Doubled Album"
    expect_target C "$HQ/[E2E Compilations]/[Compilations]" "Fixture Compilation E2E"
    expect_target D1 "$HQ/[E2E Ambient]/[Releases]" "Mixed Album One E2E"
    expect_target D2 "$HQ/[E2E Downtempo]/[Releases]" "Mixed Album Two E2E"
    expect_target E "$HQ/[E2E Ambient]/[Releases]" "Lone Track"
    expect_target F "$UHQ/[E2E Ambient]/[Releases]" "High Rate"
    sc_jq "A: artist slot (artist already in the library)" A '.proposal.structure_slot == "artist"'
    sc_jq "B: still assigned by user" B '.proposal.assigned_by == "user"'
    sc_jq "C: compilations slot, label evidence, engine" C \
        '.proposal.structure_slot == "compilations" and .proposal.target_collection == "[E2E Compilations]" and .proposal.assigned_by == "engine"'

    cli propose-single propose "$(rid DS)" || return 1
    expect_error propose-single E_NO_TARGET "singles"
    cli propose-new propose "$UNTAGGED_DIR" || return 1
    expect_error propose-new E_BAD_STATUS
    cli propose-rejected propose "$(rid G)" || return 1
    expect_error propose-rejected E_BAD_STATUS
    snap
    expect_root DS resolved true
    expect_root H new true
    expect_root G rejected false
}

step_approve() {
    local k
    snap
    need_place_ids || return 1
    # shellcheck disable=SC2086
    cli approve approve $IDS || return 1
    expect_rc approve 0
    ok_jq "approve: 7 roots -> approved" '(.data | length) == 7 and all(.data[]; .status == "approved")'
    snap
    for k in $PLACE_KEYS; do expect_root "$k" approved false; done
    cli approve-single approve "$(rid DS)" || return 1
    expect_error approve-single E_BAD_STATUS
}

step_execute() {
    local k t made=0 ta tb src
    snap
    need_place_ids || return 1
    # shellcheck disable=SC2086
    cli execute-dry execute $IDS --dry-run || return 1
    expect_rc execute-dry 0
    ok_jq "execute --dry-run: 7 rows, all dry_run" '(.data | length) == 7 and all(.data[]; .dry_run == true)'
    ok_jq "dry-run A: 3 files, 3 artifacts" '.data[] | select(.id == $id) | .files == 3 and .artifacts == 3' --arg id "$(rid A)"
    ok_jq "dry-run B: 2 files, 2 shadows skipped" '.data[] | select(.id == $id) | .files == 2 and .skipped_shadows == 2' --arg id "$(rid B)"
    ok_jq "dry-run C: 4 files, 1 artifact" '.data[] | select(.id == $id) | .files == 4 and .artifacts == 1' --arg id "$(rid C)"
    ok_jq "dry-run D1: 2 files, no artifacts (virtual)" '.data[] | select(.id == $id) | .files == 2 and .artifacts == 0' --arg id "$(rid D1)"
    snap
    for k in $PLACE_KEYS; do
        t=$(rfield "$k" .proposal.target_path)
        [ -n "$t" ] && [ -e "$t" ] && made=$((made + 1))
    done
    check "dry-run created no target dirs" test "$made" -eq 0
    for k in $PLACE_KEYS; do expect_root "$k" approved false; done

    # shellcheck disable=SC2086
    cli execute execute $IDS || return 1
    expect_rc execute 0
    ok_jq "execute: 7 rows with a journal_seq" '(.data | length) == 7 and all(.data[]; (.journal_seq | type) == "number")'
    snap
    for k in $PLACE_KEYS; do
        expect_root "$k" placed false
        st_jq "$k: placed.verified, placed target == proposal target" \
            "[.data[] | select($(sel_of "$k"))][0] | .placed.verified == true and .placed.target_path == .proposal.target_path"
        check_library "$k"
    done
    ta=$(rfield A .placed.target_path)
    check "A: artifacts copied (cover, nfo, m3u)" test -f "$ta/cover.jpg" -a -f "$ta/fixture.nfo" -a -f "$ta/00 - fixture.m3u"
    check "D1: virtual root copies audio only (2 files)" test "$(find "$(rfield D1 .placed.target_path)" -type f | wc -l | tr -d ' ')" -eq 2
    check "journal: 7 placed records" test "$(journal_count placed)" -eq 7
    check "no .intake-tmp-* dirs left in the library" test -z "$(find "$LIB" -name '.intake-tmp-*' 2>/dev/null)"
    src=$(rfield A .root_path)
    check "A: income originals untouched (3 FLAC)" test "$(count_audio "$src")" -eq 3
    if command -v metaflac >/dev/null 2>&1; then
        check "A copy: INTAKE_BATCH provenance tag" test -n "$(metaflac --show-tag=INTAKE_BATCH "$ta/01 - Opening Tone.flac" 2>/dev/null)"
        check "A original: no provenance tag" test -z "$(metaflac --show-tag=INTAKE_BATCH "$src/01 - Opening Tone.flac" 2>/dev/null)"
    else
        fail "metaflac available for the provenance check"
    fi
    tb=$(rfield D2 .placed.target_path)
    check "D2 copy: TXXX INTAKE_BATCH in the MP3" grep -q INTAKE_BATCH "$tb/mixer2_01_rise.mp3"
    check "D2 original: no provenance frame" sh -c '! grep -q INTAKE_BATCH "$1"' sh "$DUMP_DIR/mixer2_01_rise.mp3"

    cli execute-again execute "$(rid A)" || return 1
    expect_error execute-again E_BAD_STATUS
}

# Per root, as the component sends it (B8: `execute <ids> --resume`). The
# bare all-roots form is never used: it would revert the placing roots of a
# run still going elsewhere.
step_resume() {
    local a e te moved
    snap
    need_place_ids || return 1
    # shellcheck disable=SC2086
    cli resume-placed execute $IDS --resume || return 1
    expect_rc resume-placed 2
    ok_jq "execute <7 ids> --resume on placed roots: E_BAD_STATUS for each" \
        '(.errors | length) == 7 and all(.errors[]; .code == "E_BAD_STATUS" and (.msg | contains("from status placed")))'

    # completed: A back to placing, its library copy intact.
    a=$(rid A)
    set_status A placing || return 1
    snap
    expect_root A placing false
    cli resume-completed execute "$a" --resume || return 1
    expect_rc resume-completed 0
    ok_jq "resume A: resumed completed" \
        '(.data | length) == 1 and .data[0].id == $id and .data[0].resumed == "completed"' --arg id "$a"
    snap
    expect_root A placed false
    st_jq "A: placed.verified again" "[.data[] | select($(sel_of A))][0].placed.verified == true"
    check "journal: still 7 placed records (resume reused A's)" test "$(journal_count placed)" -eq 7

    # reverted_to_approved: E back to placing with its library copy gone.
    e=$(rid E)
    te=$(rfield E .placed.target_path)
    case $te in
        "$LIB"/?*) ;;
        *) fail "E: placed target inside the library" "got $te"; return 1 ;;
    esac
    moved="$te.e2e-moved"
    mv "$te" "$moved" || { fail "E: library copy moved aside"; return 1; }
    set_status E placing || return 1
    cli resume-reverted execute "$e" --resume || return 1
    expect_rc resume-reverted 0
    ok_jq "resume E: resumed reverted_to_approved" \
        '(.data | length) == 1 and .data[0].id == $id and .data[0].resumed == "reverted_to_approved"' --arg id "$e"
    snap
    expect_root E approved false
    check "no .intake-tmp-* dirs left in the library" test -z "$(find "$LIB" -name '.intake-tmp-*' 2>/dev/null)"

    # Back to placed for gc: drop the moved copy, execute E again.
    rm -rf "$moved" || { fail "E: moved copy removed"; return 1; }
    cli execute-e-again execute "$e" || return 1
    expect_rc execute-e-again 0
    snap
    expect_root E placed false
    check_library E
}

step_gc() {
    local k notplaced=0 r
    snap
    for k in $PLACE_KEYS; do
        [ "$(rfield "$k" .status)" = placed ] || notplaced=$((notplaced + 1))
    done
    if [ "$notplaced" -ne 0 ]; then
        fail "gc precondition: the 7 roots are placed" "$notplaced are not; run to-placed first"
        return 1
    fi
    need_place_ids || return 1

    cli gc-noargs gc || return 1
    expect_error gc-noargs E_BAD_ARGS
    cli gc-rejected gc "$(rid G)" || return 1
    expect_error gc-rejected E_BAD_STATUS

    # shellcheck disable=SC2086
    cli gc-dry gc $IDS --dry-run || return 1
    expect_rc gc-dry 0
    ok_jq "gc --dry-run: 7 rows, delete, dry_run" '(.data | length) == 7 and all(.data[]; .dry_run == true and .action == "delete")'
    ok_jq "gc --dry-run B: 4 local files (shadows included)" '.data[] | select(.id == $id) | .files == 4' --arg id "$(rid B)"
    snap
    for k in $PLACE_KEYS; do expect_root "$k" placed false; done
    check "dry-run deleted nothing (A still has 3 FLAC)" test "$(count_audio "$(rfield A .root_path)")" -eq 3

    # shellcheck disable=SC2086
    cli gc gc $IDS || return 1
    expect_rc gc 0
    ok_jq "gc: 7 rows, action delete" '(.data | length) == 7 and all(.data[]; .action == "delete")'
    snap
    for k in $PLACE_KEYS; do
        expect_root "$k" gc_done false
        check_library "$k"
    done
    for k in A B C E F; do
        r=$(rfield "$k" .root_path)
        check "$k: local audio and artifacts gone, sidecar kept" \
            test "$(count_audio "$r")" -eq 0 -a ! -e "$r/cover.jpg" -a -f "$r/.intake.json"
    done
    check "D: mixer files gone, loose single kept, 3 sidecars kept" \
        test "$(count_audio "$DUMP_DIR")" -eq 1 -a -f "$DUMP_DIR/stray_single_e2e.mp3" \
        -a "$(find "$DUMP_DIR" -maxdepth 1 -name '.intake.*.json' | wc -l | tr -d ' ')" -eq 3
    check "G (rejected): local files kept" test "$(count_audio "$(rfield G .root_path)")" -eq 2
    check "H (new): local files kept" test "$(count_audio "$UNTAGGED_DIR")" -eq 2
    check "journal: 7 gc_done records" test "$(journal_count gc_done)" -eq 7
}

# --- Run ---------------------------------------------------------------------
echo "intake e2e flow"
echo "  corpus:  $DEST"
echo "  wrapper: $WRAPPER"
echo "  cli:     $CLI"
echo "  logs:    $LOGS"
echo "  steps:   $STEPS"

for s in $STEPS; do
    echo
    echo "== $s"
    guard_no_live_run
    before=$FAIL
    "step_$s" || [ "$FAIL" -gt "$before" ] || fail "$s: step stopped early"
done

echo
if "$WRAPPER" status --json > "$LOGS/final-status.json" 2>/dev/null; then
    echo "status now: $(jq -r '.data | group_by(.status) | map("\(.[0].status)=\(length)") | join(" ")' "$LOGS/final-status.json" 2>/dev/null)"
fi
echo "result: $PASS passed, $FAIL failed (logs: $LOGS)"
if [ "$FAIL" -gt 0 ]; then
    printf 'failed:%s\n' "$FAILED"
    exit 1
fi
exit 0
