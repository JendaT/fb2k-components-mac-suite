#!/bin/bash
#
# make_perf_corpus.sh <dest> - a synthetic mock-CLI state for the B10
# performance checks (the decor_stats cache-hit gate: a playlist of about
# 5,000 rows, docs/hidden-options.md).
#
# What it builds in <dest> (which must be new or empty):
#   mock-cli/      a frozen copy of Tests/mock-cli (intake-mock and its
#                  scenarios), so later edits in the worktree change nothing
#   state/         an INTAKE_MOCK_STATE set up by that mock with the perf-200
#                  scenario: 200 roots in state/root/income/perf, statuses
#                  cycling new, resolved, proposed, approved, placing, placed,
#                  gc_done, rejected (25 each), one 0.1 s silent .wav per root
#                  except gc_done (175 intake rows). The same layout as the
#                  default scenario (root/, responses/, the marker), so the
#                  usual wrapper and test_playlist flow works unchanged.
#   state/root/archive/, state/root/shelf/
#                  filler: silent .wav files in no intake root, so the whole
#                  tree under state/root holds exactly PERF_TOTAL (5,000)
#                  audio files. Half of the filler sorts before income/ and
#                  half after it, so in the sorted test playlist the intake
#                  rows sit in the middle.
#   bin/intake-perf
#                  the wrapper for the component's cli_path: exports
#                  INTAKE_MOCK_STATE=<dest>/state and runs the frozen mock.
#   .intake-perf-corpus
#                  a marker naming <dest> and the counts.
#
# It runs nothing but the mock's own --mock-setup: no real intake CLI, no
# network, no ffmpeg. All names are synthetic ("Perf Artist 001", ...).
#
# Guards (e2e_lib.sh, the same as make_corpus.sh): <dest> must resolve below
# $TMPDIR or a Claude Code session scratchpad, never under or naming
# /Volumes or /volume1, no ".." component, not a symlink, only
# [A-Za-z0-9._/-] in its realpath, and new or empty. Refusals exit 64 before
# anything is written. Afterwards the tree is checked for symlinks and for
# the expected counts.
#
# Bash 3.2 compatible (/bin/bash on macOS). Only the orchestrator runs it;
# it is not a build gate.

set -u
LC_ALL=C
export LC_ALL

E2E_SELF=make_perf_corpus.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_SRC="$(cd "$HERE/../mock-cli" && pwd)"
# shellcheck source=e2e_lib.sh
. "$HERE/e2e_lib.sh"

PERF_TOTAL=5000        # audio files under state/root, intake rows included
PERF_TRACKS=25         # filler tracks per album
PERF_SCENARIO=perf-200
PERF_MARKER=".intake-perf-corpus"

[ $# -eq 1 ] || { echo "usage: $E2E_SELF <dest>" >&2; exit 64; }
REAL=$(e2e_guard_dest "$1" new) || exit 64

[ -x "$MOCK_SRC/intake-mock" ] || e2e_die "mock not found: $MOCK_SRC/intake-mock"
[ -d "$MOCK_SRC/scenarios/$PERF_SCENARIO" ] || e2e_die "mock scenario missing: $PERF_SCENARIO"
[ -z "$(find "$MOCK_SRC" -type l 2>/dev/null | head -n 1)" ] || e2e_die "symlink inside $MOCK_SRC"

fail() {
    printf '%s: %s\n' "$E2E_SELF" "$*" >&2
    exit 1
}

mkdir -p "$REAL" || fail "cannot create $REAL"
mkdir "$REAL/bin" "$REAL/state" || fail "cannot create the corpus folders"

# --- the frozen mock and its state ---

cp -R "$MOCK_SRC" "$REAL/mock-cli" || fail "cannot copy the mock"
INTAKE_MOCK_STATE="$REAL/state" "$REAL/mock-cli/intake-mock" --mock-setup "$PERF_SCENARIO" ||
    fail "the mock's --mock-setup $PERF_SCENARIO failed"
ROOT="$REAL/state/root"
[ -d "$ROOT/income/perf" ] || fail "the mock did not build $ROOT/income/perf"

count_wavs() {
    find "$1" -type f -name '*.wav' | wc -l | tr -d ' '
}

count_roots() {
    find "$REAL/state/responses/status.d" -type f -name 'itk_*.json' | wc -l | tr -d ' '
}

INTAKE_WAVS=$(count_wavs "$ROOT")
ROOTS=$(count_roots)
FILLER=$((PERF_TOTAL - INTAKE_WAVS))
[ "$FILLER" -gt 0 ] || fail "the scenario already has $INTAKE_WAVS audio files"

# --- filler: 0.1 s silent WAVs, tagged like the mock's (IPRD = album =
# the folder name, INAM = title = the file name), so SimPlaylist groups them
# by album ---

SILENCE=""

# $1 as a little-endian u32, as printf escapes.
le32() {
    printf -v REPLY '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255))
}

# The mock's write_wav (Tests/mock-cli/intake-mock): RIFF/WAVE, PCM, mono,
# 8 kHz, 8 bit, 800 bytes of silence, then a LIST/INFO chunk.
write_wav() {
    local path="$1" album title n1 n2 p1 p2 list riff z1="" z2="" e_riff e_list e_n1 e_n2
    if [ -z "$SILENCE" ]; then
        SILENCE=$'\x80'
        while [ ${#SILENCE} -lt 800 ]; do SILENCE="$SILENCE$SILENCE"; done
        SILENCE="${SILENCE:0:800}"
    fi
    title="${path##*/}"
    title="${title%.*}"
    album="${path%/*}"
    album="${album##*/}"
    n1=$((${#album} + 1))
    n2=$((${#title} + 1))
    p1=$((n1 & 1))
    p2=$((n2 & 1))
    [ $p1 -eq 1 ] && z1='\x00'
    [ $p2 -eq 1 ] && z2='\x00'
    list=$((4 + 8 + n1 + p1 + 8 + n2 + p2))
    riff=$((4 + 8 + 16 + 8 + 800 + 8 + list))
    le32 $riff; e_riff="$REPLY"
    le32 $list; e_list="$REPLY"
    le32 $n1; e_n1="$REPLY"
    le32 $n2; e_n2="$REPLY"
    {
        printf 'RIFF'"$e_riff"'WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00data\x20\x03\x00\x00'
        printf '%s' "$SILENCE"
        printf 'LIST'"$e_list"'INFOIPRD'"$e_n1"'%s\x00'"$z1"'INAM'"$e_n2"'%s\x00'"$z2" "$album" "$title"
    } > "$path"
}

ALBUMS=$(((FILLER + PERF_TRACKS - 1) / PERF_TRACKS))
HALF=$(((ALBUMS + 1) / 2))
written=0
album=1
while [ $album -le $ALBUMS ]; do
    # One artist per four albums; the first half under archive/ (before
    # income/), the rest under shelf/ (after it).
    if [ $album -le $HALF ]; then top=archive; else top=shelf; fi
    printf -v artist 'Perf Artist %03d' $(((album - 1) / 4 + 1))
    printf -v dir '%s/%s/%s/%s - Perf Album %03d' "$ROOT" "$top" "$artist" "$artist" "$album"
    mkdir -p "$dir" || fail "cannot create $dir"
    track=1
    while [ $track -le $PERF_TRACKS ] && [ $written -lt $FILLER ]; do
        printf -v file '%s/%02d - Perf Track %02d.wav' "$dir" "$track" "$track"
        write_wav "$file" || fail "cannot write $file"
        written=$((written + 1))
        track=$((track + 1))
    done
    album=$((album + 1))
done

# --- the wrapper ---

cat > "$REAL/bin/intake-perf" <<EOF || fail "cannot write the wrapper"
#!/bin/bash
# intake-perf: generated by Tests/e2e/make_perf_corpus.sh. Runs the frozen
# intake mock against this corpus's state and nothing else. Do not edit;
# make a new corpus instead.
export INTAKE_MOCK_STATE='$REAL/state'
exec '$REAL/mock-cli/intake-mock' "\$@"
EOF
chmod 755 "$REAL/bin/intake-perf" || fail "cannot make the wrapper executable"

# --- checks ---

[ -z "$(find "$REAL" -type l 2>/dev/null | head -n 1)" ] || fail "a symlink appeared inside $REAL"
TOTAL=$(count_wavs "$ROOT")
[ "$TOTAL" -eq "$PERF_TOTAL" ] || fail "expected $PERF_TOTAL audio files under $ROOT, found $TOTAL"
[ "$ROOTS" -eq 200 ] || fail "expected 200 roots, found $ROOTS"

{
    printf 'dest=%s\n' "$REAL"
    printf 'scenario=%s\n' "$PERF_SCENARIO"
    printf 'roots=%s\n' "$ROOTS"
    printf 'intake_audio=%s\n' "$INTAKE_WAVS"
    printf 'filler_audio=%s\n' "$FILLER"
    printf 'total_audio=%s\n' "$TOTAL"
} > "$REAL/$PERF_MARKER" || fail "cannot write the marker"

cat <<EOF
$E2E_SELF: corpus ready in $REAL
  $ROOTS intake roots ($INTAKE_WAVS audio rows; gc_done roots keep only their sidecar)
  $FILLER filler rows in $ALBUMS albums under state/root/archive and state/root/shelf
  $TOTAL audio files in all

Component settings (write them with sqlite3 while foobar2000 is quit; see
Tests/e2e/README.md "Perf corpus"):
  foo_jl_intake.cli_path           $REAL/bin/intake-perf
  foo_jl_intake.test_playlist_dir  $ROOT
  foo_jl_intake.test_playlist      1
EOF
