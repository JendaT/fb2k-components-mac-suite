#!/bin/bash
#
# e2e_lib.sh - guards and the CLI wrapper shared by make_corpus.sh and
# run_flow.sh. Sourced, never run. Bash 3.2 compatible (/bin/bash on macOS):
# no associative arrays, no ${x,,}, no mapfile.
#
# Every check prints the reason and returns non-zero; the callers stop
# before touching anything. Refusals exit 64, like Tests/mock-cli.

E2E_MARKER=".intake-e2e-corpus"
E2E_CORPUS_VERSION=2

e2e_die() {
    printf '%s: refused: %s\n' "${E2E_SELF:-e2e}" "$*" >&2
    exit 64
}

# Lowercase without ${x,,} (bash 3.2).
e2e_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Canonical absolute path of $1, which may not exist yet. Existing ancestors
# are resolved with `cd -P` (symlinks, /var -> /private/var); the missing
# tail is appended as written. Callers refuse `..` components first
# (e2e_check_dest_arg), because a missing tail is not normalised here.
e2e_realpath() {
    local p=$1 tail="" head
    case $p in
        /*) ;;
        *) p="$PWD/$p" ;;
    esac
    while [ ! -d "$p" ]; do
        [ -L "$p" ] && return 1    # dangling symlink: never followed
        tail="/$(basename "$p")$tail"
        p=$(dirname "$p")
    done
    head=$(cd -P "$p" 2>/dev/null && pwd -P) || return 1
    printf '%s%s\n' "${head%/}" "$tail"
}

# Refuse a path that is, or names, a share mount (/Volumes, /volume1),
# compared case-insensitively (APFS is case-insensitive and `cd -P` keeps
# the case it was given).
e2e_check_not_share() {
    local low
    low=$(e2e_lower "$1")
    case $low in
        /volumes|/volumes/*|/volume1|/volume1/*|*/volumes/*|*/volume1/*)
            echo "path is on or names a share mount: $1"; return 1 ;;
    esac
    return 0
}

# Checks on the raw <dest> argument, before anything is resolved.
e2e_check_dest_arg() {
    local d=$1
    [ -n "$d" ] || { echo "no destination given"; return 1; }
    case "/$d/" in
        */../*) echo "destination contains a .. component: $d"; return 1 ;;
    esac
    [ -L "$d" ] && { echo "destination is a symlink: $d"; return 1; }
    e2e_check_not_share "$d" || return 1
    return 0
}

# Realpath of $TMPDIR, accepted only when it is a per-user temp dir.
e2e_tmpdir_root() {
    local t=${TMPDIR:-} r
    [ -n "$t" ] && [ -d "$t" ] || return 1
    r=$(cd -P "$t" 2>/dev/null && pwd -P) || return 1
    case $r in
        /private/var/folders/?*|/private/tmp/?*) printf '%s\n' "${r%/}" ;;
        *) return 1 ;;
    esac
}

# Checks on the resolved destination: allowed root, characters, share mounts.
# Allowed: strictly below realpath($TMPDIR), or below a Claude Code session
# scratchpad /private/tmp/claude-<uid>/<project>/<session>/scratchpad/.
e2e_check_dest_real() {
    local real=$1 troot uid scratch_re
    e2e_check_not_share "$real" || return 1
    # The path goes unquoted into INTAKE_BEETS_SHIM (the CLI splits that on
    # spaces) and quoted into YAML, JSON and the wrapper. Keep it plain.
    if ! printf '%s' "$real" | LC_ALL=C grep -Eq '^/[A-Za-z0-9._/-]+$'; then
        echo "destination has characters outside [A-Za-z0-9._/-]: $real"; return 1
    fi
    troot=$(e2e_tmpdir_root) || troot=""
    if [ -n "$troot" ]; then
        case $real in
            "$troot"/?*) return 0 ;;
        esac
    fi
    uid=$(id -u)
    scratch_re="^/private/tmp/claude-${uid}/[^/]+/[^/]+/scratchpad/[^/]+"
    if printf '%s' "$real" | LC_ALL=C grep -Eq "$scratch_re"; then
        return 0
    fi
    echo "destination is not below \$TMPDIR (${troot:-unset}) or a session scratchpad /private/tmp/claude-${uid}/<project>/<session>/scratchpad/: $real"
    return 1
}

# The existing part of absolute path $1 resolves to itself: no symlink in
# any component (a missing tail is fine; a dangling symlink is not). The
# CLI follows a symlink at an income folder or a tier root (it lstats only
# their children), so a lexical "inside <dest>" check is not enough.
# Emitted into the wrapper (declare -f): self-contained.
e2e_path_unlinked() {
    local p=$1 r
    case $p in
        /*) ;;
        *) return 1 ;;
    esac
    while [ ! -e "$p" ] && [ ! -L "$p" ]; do
        p=${p%/*}
        [ -n "$p" ] || return 0
    done
    [ -L "$p" ] && return 1
    if [ -d "$p" ]; then
        r=$(cd -P "$p" 2>/dev/null && pwd -P) || return 1
    else
        r=$(cd -P "${p%/*}" 2>/dev/null && pwd -P) || return 1
        r="${r%/}/${p##*/}"
    fi
    [ "$r" = "$p" ]
}

# No symlinks where the CLI or the scripts write: the corpus dirs themselves
# and anything below rules, income, library and bin (make_corpus.sh creates
# none, and the CLI never does). Self-contained (emitted into the wrapper).
e2e_check_no_symlinks() {
    local dest=$1 d l
    for d in bin home tmp cache logs rules income library; do
        [ -L "$dest/$d" ] && { echo "corpus dir is a symlink: $dest/$d"; return 1; }
    done
    l=$(find "$dest/rules" "$dest/income" "$dest/library" "$dest/bin" -type l -print 2>/dev/null)
    [ -z "$l" ] || { echo "symlink inside the corpus: ${l%%$'\n'*}"; return 1; }
    return 0
}

# The CLI never writes income.yaml or structure.yaml, so make_corpus.sh pins
# them by SHA-256 in the marker; any edit (another YAML spelling of a path
# key included) is refused here, before the line check below. Self-contained
# (emitted into the wrapper; /usr/bin/shasum, as PATH may be minimal there).
e2e_check_rules_pinned() {
    local dest=$1 name h
    for name in income structure; do
        h=$(/usr/bin/shasum -a 256 < "$dest/rules/$name.yaml" 2>/dev/null) || { echo "cannot hash $dest/rules/$name.yaml"; return 1; }
        h=${h%% *}
        grep -qx "rules_sha256_$name=$h" "$dest/$E2E_MARKER" 2>/dev/null ||
            { echo "rules/$name.yaml differs from the one make_corpus.sh wrote (or the marker has no hash for it)"; return 1; }
    done
    return 0
}

# Every path in the rules files must be absolute and inside <dest>. The CLI
# reads paths from exactly these keys (config.ts): income[].path,
# tiers.<name>.root, journal.path, gc.dj_zone. Line based on purpose:
# make_corpus.sh writes one `key: "value"` per line and no flow mappings or
# anchors, so anything else is refused rather than parsed; the files are
# also pinned by hash (e2e_check_rules_pinned). Each path must also resolve
# to itself (e2e_path_unlinked). Emitted verbatim into the wrapper
# (declare -f), so it stays self-contained apart from e2e_path_unlinked.
e2e_check_rules_paths() {
    local dest=$1 spec f line val n min re
    re='^[[:space:]]*-?[[:space:]]*(path|root|dj_zone):[[:space:]]*(.*)$'
    for spec in "$dest/rules/income.yaml:3" "$dest/rules/structure.yaml:4"; do
        min=${spec##*:}
        f=${spec%:*}
        [ -f "$f" ] || { echo "rules file missing: $f"; return 1; }
        [ -L "$f" ] && { echo "rules file is a symlink: $f"; return 1; }
        n=0
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
                *'{'*|*'&'*|*'*'*|*'!'*) echo "unsupported YAML (flow mapping, anchor, tag) in $f: $line"; return 1 ;;
            esac
            if [[ $line =~ $re ]]; then
                val=${BASH_REMATCH[2]}
                val=${val#\"}
                val=${val%\"}
                case $val in
                    "$dest"/*) ;;
                    *) echo "path outside the corpus in $f: $val"; return 1 ;;
                esac
                case "$val/" in
                    */../*|*/./*|*'~'*|*'"'*|*'#'*) echo "non-canonical path in $f: $val"; return 1 ;;
                esac
                e2e_path_unlinked "$val" || { echo "path in $f goes through a symlink: $val"; return 1; }
                n=$((n + 1))
            fi
        done < "$f"
        [ "$n" -ge "$min" ] || { echo "expected at least $min path entries in $f, found $n"; return 1; }
    done
    return 0
}

# Full check of an existing corpus: real dir, marker naming this dir, rules
# dir not redirected, no symlinks, rules files as written, rules paths
# inside.
e2e_check_corpus() {
    local real=$1 marker rules_real
    [ -d "$real" ] || { echo "not a directory: $real"; return 1; }
    marker="$real/$E2E_MARKER"
    [ -f "$marker" ] || { echo "no $E2E_MARKER in $real (not made by make_corpus.sh)"; return 1; }
    grep -qx "dest=$real" "$marker" || { echo "$E2E_MARKER names another location (moved corpus?): $real"; return 1; }
    rules_real=$(cd -P "$real/rules" 2>/dev/null && pwd -P) || { echo "rules dir missing: $real/rules"; return 1; }
    [ "$rules_real" = "$real/rules" ] || { echo "rules dir resolves outside the corpus: $rules_real"; return 1; }
    e2e_check_no_symlinks "$real" || return 1
    e2e_check_rules_pinned "$real" || return 1
    e2e_check_rules_paths "$real" || return 1
    return 0
}

# Resolve and check a destination argument; prints the realpath. Mode "new"
# (make_corpus: may not exist yet, must be empty) or "existing" (run_flow:
# must be a corpus made by make_corpus). Call as REAL=$(...) || exit 64.
e2e_guard_dest() {
    local arg=$1 mode=$2 real why
    why=$(e2e_check_dest_arg "$arg") || e2e_die "$why"
    real=$(e2e_realpath "$arg") || e2e_die "cannot resolve destination: $arg"
    why=$(e2e_check_dest_real "$real") || e2e_die "$why"
    if [ "$mode" = new ]; then
        if [ -e "$real" ]; then
            [ -d "$real" ] || e2e_die "destination exists and is not a directory: $real"
            [ -z "$(ls -A "$real" 2>/dev/null)" ] || e2e_die "destination is not empty (use a fresh directory): $real"
        fi
    else
        why=$(e2e_check_corpus "$real") || e2e_die "$why"
    fi
    printf '%s\n' "$real"
}

e2e_find_bun() {
    local c
    for c in "${INTAKE_E2E_BUN:-}" "$(command -v bun 2>/dev/null)" "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
        if [ -n "$c" ] && [ -x "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

e2e_default_cli() {
    printf '%s\n' "${INTAKE_E2E_CLI:-$HOME/Projects/Foobar2000-worktrees/intake-cli/tools/intake/src/cli.ts}"
}

# Write <dest>/bin/beets-offline-stub and <dest>/bin/intake-e2e; prints the
# wrapper path. The wrapper is what run_flow.sh calls and what the
# component's cli_path can point at. Re-checks the corpus on every call.
e2e_write_wrapper() {
    local dest=$1 bun=$2 cli=$3 w="$1/bin/intake-e2e" stub="$1/bin/beets-offline-stub"
    case "$bun$cli" in
        *"'"*) echo "bun or CLI path contains a single quote" >&2; return 1 ;;
    esac
    mkdir -p "$dest/bin" "$dest/home" "$dest/tmp" "$dest/cache" || return 1

    cat > "$stub" <<'STUB'
#!/bin/sh
# Offline stand-in for the CLI's shim/beets_identify.py (INTAKE_BEETS_SHIM).
# Answers like a machine without beets, so identify never reaches MusicBrainz.
printf '{"error":"beets_unavailable"}\n'
exit 3
STUB
    chmod 755 "$stub" || return 1

    {
        cat <<'HEAD'
#!/bin/bash
# intake-e2e: generated by Tests/e2e (e2e_lib.sh). Runs the REAL intake CLI
# against the synthetic corpus in DEST and nothing else. Regenerate with
# run_flow.sh <dest> --cli-wrapper; do not edit.
#
# Environment: env -i (no inherited tokens, proxies or INTAKE_* values),
# HOME inside the corpus (so ~/.config/intake/config.toml cannot be found),
# INTAKE_RULES_DIR and INTAKE_CACHE_DIR inside the corpus, beets shim
# stubbed (no MusicBrainz), DO_NOT_TRACK=1 (no bun crash-report upload),
# bun auto-install off.
# Refusal: message on stderr, exit 64, no JSON envelope.

HEAD
        printf "DEST='%s'\n" "$dest"
        printf "BUN='%s'\n" "$bun"
        printf "CLI_TS='%s'\n" "$cli"
        printf "E2E_MARKER='%s'\n\n" "$E2E_MARKER"
        declare -f e2e_path_unlinked e2e_check_no_symlinks e2e_check_rules_pinned e2e_check_rules_paths
        cat <<'BODY'

refuse() {
    printf 'intake-e2e: refused: %s\n' "$*" >&2
    exit 64
}

[ -f "$DEST/$E2E_MARKER" ] || refuse "no $E2E_MARKER in $DEST"
grep -qx "dest=$DEST" "$DEST/$E2E_MARKER" || refuse "$E2E_MARKER names another location"
real=$(cd -P "$DEST" 2>/dev/null && pwd -P) || refuse "corpus missing: $DEST"
[ "$real" = "$DEST" ] || refuse "corpus resolves elsewhere: $real"
real=$(cd -P "$DEST/rules" 2>/dev/null && pwd -P) || refuse "rules dir missing"
[ "$real" = "$DEST/rules" ] || refuse "rules dir resolves outside the corpus: $real"
why=$(e2e_check_no_symlinks "$DEST") || refuse "$why"
why=$(e2e_check_rules_pinned "$DEST") || refuse "$why"
why=$(e2e_check_rules_paths "$DEST") || refuse "$why"
[ -x "$BUN" ] || { printf 'intake-e2e: bun not found: %s\n' "$BUN" >&2; exit 127; }
[ -f "$CLI_TS" ] || { printf 'intake-e2e: CLI not found: %s\n' "$CLI_TS" >&2; exit 127; }
cd "$DEST/home" || refuse "home dir missing"

unset DISCOGS_TOKEN LASTFM_API_KEY
exec /usr/bin/env -i \
    HOME="$DEST/home" \
    PATH="${BUN%/*}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="$DEST/tmp/" \
    LANG=en_US.UTF-8 \
    DO_NOT_TRACK=1 \
    INTAKE_RULES_DIR="$DEST/rules" \
    INTAKE_CACHE_DIR="$DEST/cache" \
    INTAKE_BEETS_SHIM="$DEST/bin/beets-offline-stub" \
    BEETSDIR="$DEST/home/.config/beets" \
    "$BUN" run --no-install "$CLI_TS" "$@"
BODY
    } > "$w" || return 1
    chmod 755 "$w" || return 1
    printf '%s\n' "$w"
}
