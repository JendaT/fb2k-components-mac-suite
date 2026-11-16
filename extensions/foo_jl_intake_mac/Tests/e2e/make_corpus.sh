#!/bin/bash
#
# make_corpus.sh <dest> - build a synthetic intake corpus for the end-to-end
# run of the REAL intake CLI (run_flow.sh) and the in-app B8/B9 checks.
#
# Everything is created inside <dest>: a rules dir (INTAKE_RULES_DIR) whose
# every path points inside <dest>, three income folders with small tagged
# sine-tone releases (synthetic names only), the library tier roots, the
# journal location, a cache dir, a fake HOME, and bin/intake-e2e (the CLI
# wrapper; written when bun and the CLI are found, otherwise by run_flow.sh).
#
# Refuses (exit 64, before creating anything) unless <dest> resolves below
# $TMPDIR or a Claude Code session scratchpad, is not under /Volumes or
# /volume1, has no `..` component, is not a symlink, and is empty or absent.
# Makes no network calls and never runs the intake CLI.
#
# Needs: ffmpeg (flac + libmp3lame encoders). Bash 3.2 compatible.

set -u
set -o pipefail

E2E_SELF=make_corpus.sh
HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=e2e_lib.sh
. "$HERE/e2e_lib.sh"

usage() {
    cat >&2 <<'EOF'
usage: make_corpus.sh <dest>

  <dest>  new or empty directory below $TMPDIR or a session scratchpad
          (/private/tmp/claude-<uid>/<project>/<session>/scratchpad/...)

Then: run_flow.sh <dest> [steps]   (see README.md)
EOF
    exit "${1:-64}"
}

[ $# -eq 1 ] || usage
case $1 in
    -h|--help) usage 0 ;;
esac

DEST=$(e2e_guard_dest "$1" new) || exit 64

command -v ffmpeg >/dev/null 2>&1 || e2e_die "ffmpeg not found"
# Captured first: `ffmpeg | grep -q` can fail under pipefail when grep exits
# at the match and ffmpeg then gets SIGPIPE.
ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null) || ENCODERS=""
case $ENCODERS in
    *libmp3lame*) ;;
    *) e2e_die "ffmpeg has no libmp3lame encoder" ;;
esac

mkdir -p "$DEST" || e2e_die "cannot create $DEST"
real=$(cd -P "$DEST" && pwd -P) || e2e_die "cannot resolve $DEST after mkdir"
[ "$real" = "$DEST" ] || e2e_die "destination resolved to $real after mkdir (expected $DEST)"

RULES="$DEST/rules"
INC_WEB="$DEST/income/web"
INC_SLSK="$DEST/income/soulseek"
INC_MAN="$DEST/income/manual"
LIB="$DEST/library"

mkdir -p "$RULES" "$INC_WEB" "$INC_SLSK" "$INC_MAN" \
    "$LIB/music.hq" "$LIB/music.uhq" "$LIB/music.meta" "$LIB/dj" \
    "$DEST/cache" "$DEST/home" "$DEST/tmp" "$DEST/bin" "$DEST/logs" \
    || e2e_die "cannot create the corpus layout"

# ---------------------------------------------------------------------------
# Audio: 1 s sine tones, a distinct frequency per file (distinct audio_hash).
# ---------------------------------------------------------------------------

FREQ=200
next_freq() { FREQ=$((FREQ + 37)); }

# gen <file> <codec> <freq> [key=value ...]
#   codec: flac16 | flac24 | mp3 | untagged (16-bit FLAC, no tags at all)
gen() {
    local file=$1 codec=$2 freq=$3 rate=44100 kv
    shift 3
    [ "$codec" = flac24 ] && rate=96000
    local args=(-hide_banner -loglevel error -nostdin -y
        -f lavfi -i "sine=frequency=${freq}:duration=1:sample_rate=${rate}")
    if [ "$codec" = untagged ]; then
        args+=(-map_metadata -1 -fflags +bitexact)
    else
        for kv in "$@"; do args+=(-metadata "$kv"); done
    fi
    case $codec in
        flac16|untagged) args+=(-c:a flac -sample_fmt s16) ;;
        flac24) args+=(-c:a flac -sample_fmt s32 -bits_per_raw_sample 24) ;;
        mp3) args+=(-c:a libmp3lame -b:a 320k -id3v2_version 3) ;;
        *) e2e_die "unknown codec $codec" ;;
    esac
    mkdir -p "$(dirname "$file")" || e2e_die "mkdir failed for $file"
    ffmpeg "${args[@]}" "$file" || e2e_die "ffmpeg failed: $file"
}

cover() {
    ffmpeg -hide_banner -loglevel error -nostdin -y -f lavfi -i "color=c=gray:s=16x16" \
        -frames:v 1 "$1/cover.jpg" || e2e_die "ffmpeg cover failed: $1"
}

# album <dir> <codec> <ext> <albumartist> <album> <date> <title>...
# Files "NN - Title.ext", album artist = artist, track numbers 1..n.
album() {
    local dir=$1 codec=$2 ext=$3 aa=$4 al=$5 date=$6 i=0 title
    shift 6
    for title in "$@"; do
        i=$((i + 1))
        next_freq
        gen "$dir/$(printf '%02d' "$i") - $title.$ext" "$codec" "$FREQ" \
            "album_artist=$aa" "artist=$aa" "album=$al" "title=$title" "track=$i" "date=$date"
    done
}

# --- A: normal album, artist already in the library -> <Artist>/ slot ------
A="$INC_WEB/Fixture Artist E2E [2024] Synthetic Album (Fixture Label E2E; FXE001)"
album "$A" flac16 flac "Fixture Artist E2E" "Synthetic Album" 2024 \
    "Opening Tone" "Middle Tone" "Closing Tone"
cover "$A"
printf 'Fixture Artist E2E - Synthetic Album\nSynthetic e2e fixture, sine tones only.\n' > "$A/fixture.nfo" ||
    e2e_die "cannot write $A/fixture.nfo"
printf '01 - Opening Tone.flac\n02 - Middle Tone.flac\n03 - Closing Tone.flac\n' > "$A/00 - fixture.m3u" ||
    e2e_die "cannot write $A/00 - fixture.m3u"

# --- B: quality shadows (FLAC primary, MP3 copies of the same tracks) ------
B="$INC_WEB/Fixture Shadow E2E - Doubled Album (2023)"
i=0
for title in "First Double" "Second Double"; do
    i=$((i + 1))
    next_freq
    for codec in flac16 mp3; do
        ext=flac
        [ "$codec" = mp3 ] && ext=mp3
        gen "$B/0$i - $title.$ext" "$codec" "$FREQ" \
            "album_artist=Fixture Shadow E2E" "artist=Fixture Shadow E2E" \
            "album=Doubled Album" "title=$title" "track=$i" "date=2023"
    done
done
cover "$B"

# --- C: Various Artists compilation (per-track album artists) --------------
C="$INC_WEB/VA [2024] Fixture Compilation E2E (Fixture Label E2E; FXE002)"
i=0
for n in One Two Three Four; do
    i=$((i + 1))
    next_freq
    gen "$C/0$i - Fixture Track Artist $n E2E - Compilation Song $n.flac" flac16 "$FREQ" \
        "album_artist=Fixture Track Artist $n E2E" "artist=Fixture Track Artist $n E2E" \
        "album=Fixture Compilation E2E" "title=Compilation Song $n" "track=$i" "date=2024"
done
cover "$C"

# --- D: flat dump -> two virtual roots + one loose single ------------------
D="$INC_SLSK/mixed_dump_e2e"
next_freq; gen "$D/mixer1_01_dawn.flac" flac16 "$FREQ" "album_artist=Fixture Mixer One E2E" \
    "artist=Fixture Mixer One E2E" "album=Mixed Album One E2E" "title=Dawn" "track=1" "date=2021"
next_freq; gen "$D/mixer1_02_dusk.flac" flac16 "$FREQ" "album_artist=Fixture Mixer One E2E" \
    "artist=Fixture Mixer One E2E" "album=Mixed Album One E2E" "title=Dusk" "track=2" "date=2021"
next_freq; gen "$D/mixer2_01_rise.mp3" mp3 "$FREQ" "album_artist=Fixture Mixer Two E2E" \
    "artist=Fixture Mixer Two E2E" "album=Mixed Album Two E2E" "title=Rise" "track=1" "date=2022"
next_freq; gen "$D/mixer2_02_fall.mp3" mp3 "$FREQ" "album_artist=Fixture Mixer Two E2E" \
    "artist=Fixture Mixer Two E2E" "album=Mixed Album Two E2E" "title=Fall" "track=2" "date=2022"
next_freq; gen "$D/stray_single_e2e.mp3" mp3 "$FREQ" \
    "artist=Fixture Stray E2E" "album=Stray Single E2E" "title=Stray Single" "track=1" "date=2020"

# --- E: one-track release in its own folder ---------------------------------
E="$INC_MAN/Fixture Single E2E [2025] Lone Track"
album "$E" flac16 flac "Fixture Single E2E" "Lone Track" 2025 "Lone Track"
cover "$E"

# --- F: hi-res (24/96) -> music.uhq tier ------------------------------------
F="$INC_MAN/Fixture Hires E2E [2022] High Rate"
album "$F" flac24 flac "Fixture Hires E2E" "High Rate" 2022 "High One" "High Two"
cover "$F"

# --- G: release the flow rejects --------------------------------------------
G="$INC_MAN/Fixture Reject E2E [2020] Unwanted"
album "$G" flac16 flac "Fixture Reject E2E" "Unwanted" 2020 "Unwanted One" "Unwanted Two"
cover "$G"

# --- H: untagged, unparseable folder -> status new --------------------------
H="$INC_MAN/zz_unsorted_e2e"
next_freq; gen "$H/a.flac" untagged "$FREQ"
next_freq; gen "$H/b.flac" untagged "$FREQ"

# --- Library: an existing release of A's artist (makes A use <Artist>/) ----
L="$LIB/music.hq/[E2E Ambient]/Fixture Artist E2E/Fixture Artist E2E [2019] Earlier Album"
next_freq
gen "$L/01 - Earlier Tone.flac" flac16 "$FREQ" "album_artist=Fixture Artist E2E" \
    "artist=Fixture Artist E2E" "album=Earlier Album" "title=Earlier Tone" "track=1" "date=2019"

# ---------------------------------------------------------------------------
# Rules (INTAKE_RULES_DIR). One `key: "value"` per line, no flow mappings in
# income.yaml/structure.yaml: the wrapper's path check reads them by line.
# ---------------------------------------------------------------------------

{ cat > "$RULES/income.yaml" <<EOF
# Synthetic e2e rules written by Tests/e2e/make_corpus.sh. All paths inside the corpus.
income:
  - name: e2e-web
    path: "$INC_WEB"
    source_type: web
  - name: e2e-soulseek
    path: "$INC_SLSK"
    source_type: soulseek
  - name: e2e-manual
    path: "$INC_MAN"
    source_type: manual
EOF
} || e2e_die "cannot write $RULES/income.yaml"

{ cat > "$RULES/structure.yaml" <<EOF
# Synthetic e2e structure written by Tests/e2e/make_corpus.sh. All paths inside the corpus.
resolver:
  thresholds:
    resolved: 0.80
    review: 0.50
tiers:
  music.uhq:
    root: "$LIB/music.uhq"
    gate: hires
    growth: active
  music.hq:
    root: "$LIB/music.hq"
    gate: lossless-first
    growth: primary
assign:
  short_circuit:
    min_releases: 2
    confidence: 0.95
  needs_review:
    confidence: 0.6
    margin: 0.2
journal:
  path: "$LIB/music.meta/intake-journal.ndjson"
gc:
  dj_zone: "$LIB/dj"
  dj_collections: []
EOF
} || e2e_die "cannot write $RULES/structure.yaml"

{ cat > "$RULES/genre-map.yaml" <<'EOF'
# Synthetic e2e genre map: artist -> collection -> release count.
artists:
  Fixture Artist E2E:
    "[E2E Ambient]": 3
  Fixture Mixer One E2E:
    "[E2E Ambient]": 2
  Fixture Mixer Two E2E:
    "[E2E Downtempo]": 2
  Fixture Single E2E:
    "[E2E Ambient]": 1
  Fixture Hires E2E:
    "[E2E Ambient]": 2
feedback: {}
aliases: {}
exceptions: []
EOF
} || e2e_die "cannot write $RULES/genre-map.yaml"

{ cat > "$RULES/label-map.yaml" <<'EOF'
# Synthetic e2e label map: label -> collection -> release count.
labels:
  Fixture Label E2E:
    "[E2E Compilations]": 4
EOF
} || e2e_die "cannot write $RULES/label-map.yaml"

{ cat > "$RULES/styles.yaml" <<'EOF'
# Synthetic e2e style hints (none).
styles: {}
genres: {}
EOF
} || e2e_die "cannot write $RULES/styles.yaml"

# The CLI never writes income.yaml or structure.yaml: pin them (the guards
# refuse a corpus whose files no longer match).
sha_of() {
    local h
    h=$(/usr/bin/shasum -a 256 < "$1") || return 1
    printf '%s\n' "${h%% *}"
}
SHA_INCOME=$(sha_of "$RULES/income.yaml") || e2e_die "cannot hash income.yaml"
SHA_STRUCTURE=$(sha_of "$RULES/structure.yaml") || e2e_die "cannot hash structure.yaml"

{ cat > "$DEST/$E2E_MARKER" <<EOF
dest=$DEST
corpus_version=$E2E_CORPUS_VERSION
generator=Tests/e2e/make_corpus.sh
rules_sha256_income=$SHA_INCOME
rules_sha256_structure=$SHA_STRUCTURE
EOF
} || e2e_die "cannot write $DEST/$E2E_MARKER"

# Self-check: every generated file is there and non-empty, and the corpus
# passes the same checks run_flow.sh and the wrapper use.
for f in "$RULES/genre-map.yaml" "$RULES/label-map.yaml" "$RULES/styles.yaml" \
    "$A/cover.jpg" "$A/fixture.nfo" "$A/00 - fixture.m3u"; do
    [ -s "$f" ] || e2e_die "generated corpus is incomplete: $f is missing or empty"
done
why=$(e2e_check_corpus "$DEST") || e2e_die "generated corpus fails its own check: $why"

WRAPPER=""
if BUN=$(e2e_find_bun) && CLI=$(e2e_default_cli) && [ -f "$CLI" ]; then
    WRAPPER=$(e2e_write_wrapper "$DEST" "$BUN" "$CLI") || e2e_die "cannot write the wrapper"
fi

n_audio=$(find "$DEST/income" -type f \( -name '*.flac' -o -name '*.mp3' \) | wc -l | tr -d ' ')
echo "corpus: $DEST"
echo "  rules:   $RULES (INTAKE_RULES_DIR)"
echo "  income:  $INC_WEB, $INC_SLSK, $INC_MAN ($n_audio audio files)"
echo "  library: $LIB/music.hq, $LIB/music.uhq; journal $LIB/music.meta/intake-journal.ndjson"
if [ -n "$WRAPPER" ]; then
    echo "  wrapper: $WRAPPER"
else
    echo "  wrapper: not written (bun or the CLI not found); run_flow.sh writes it"
fi
echo "next: $HERE/run_flow.sh $DEST"
