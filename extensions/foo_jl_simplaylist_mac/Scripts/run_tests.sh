#!/bin/bash
#
# run_tests.sh - Compile and run unit tests for pure-logic Core models.
#
# The models under test are Foundation-only (no foobar2000 SDK), so they
# compile standalone with clang in ~1s — no Xcode target or SDK needed.
# Invoked as a gating phase by build.sh; exits non-zero on any failure.
#
# Tests are auto-discovered: every Tests/*Tests.mm and Tests/*Tests.cpp
# becomes one binary. For FooTests.*, src/Core/Foo.mm or src/Core/Foo.cpp is
# linked automatically when it exists (header-only modules need nothing).
# Extra sources are declared in the test file itself with a comment line:
#   // TEST_DEPS: src/Core/PlaylistLayoutModel.mm
# .mm tests compile as Objective-C++ with Foundation; .cpp tests as plain C++.
#
# Tests run under ASan+UBSan (tests only — never the component build).
# UBSan findings abort (-fno-sanitize-recover) so they gate like any failure.
#
# Usage: run_tests.sh [--coverage]
#   --coverage  Recompile with llvm source coverage instead of sanitizers and
#               print a per-Core-file line coverage report after the run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"

mkdir -p "$TEST_BUILD_DIR"

COVERAGE=0
if [ "${1:-}" = "--coverage" ]; then
    COVERAGE=1
fi

if [ "$COVERAGE" = "1" ]; then
    INSTRUMENT_FLAGS=(-fprofile-instr-generate -fcoverage-mapping)
else
    INSTRUMENT_FLAGS=(-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer)
fi

BINARIES=()

for test_file in "$PROJECT_DIR"/Tests/*Tests.mm "$PROJECT_DIR"/Tests/*Tests.cpp; do
    [ -e "$test_file" ] || continue
    base="$(basename "$test_file")"
    name="${base%.*}"          # FooTests
    module="${base%Tests.*}"   # Foo

    sources=("$test_file")

    # Convention: link the module's implementation file when one exists.
    # .cpp tests only link plain C++ sources.
    if [[ "$test_file" == *.mm ]]; then
        candidates=("$PROJECT_DIR/src/Core/$module.mm" "$PROJECT_DIR/src/Core/$module.cpp")
    else
        candidates=("$PROJECT_DIR/src/Core/$module.cpp")
    fi
    for candidate in "${candidates[@]}"; do
        [ -f "$candidate" ] && sources+=("$candidate")
    done

    # Per-test extra deps: "// TEST_DEPS: <path> [<path>...]" (project-relative).
    # Paths are whitespace-split, so they must not contain spaces or glob chars.
    deps="$(grep -h '^// TEST_DEPS:' "$test_file" | sed 's|^// TEST_DEPS:||' || true)"
    for dep in $deps; do
        if [ ! -f "$PROJECT_DIR/$dep" ]; then
            echo "ERROR: $base declares missing TEST_DEPS file: $dep" >&2
            exit 1
        fi
        sources+=("$PROJECT_DIR/$dep")
    done

    out="$TEST_BUILD_DIR/$name"
    echo "==> Compiling unit tests ($module)..."
    if [[ "$test_file" == *.mm ]]; then
        clang++ -x objective-c++ -std=c++17 -fobjc-arc -O1 -Wall "${INSTRUMENT_FLAGS[@]}" \
            "${sources[@]}" \
            -framework Foundation \
            -o "$out"
    else
        clang++ -std=c++17 -O1 -Wall "${INSTRUMENT_FLAGS[@]}" \
            "${sources[@]}" \
            -o "$out"
    fi
    BINARIES+=("$out")
done

if [ "${#BINARIES[@]}" -eq 0 ]; then
    echo "ERROR: no tests discovered in $PROJECT_DIR/Tests" >&2
    exit 1
fi

echo "==> Running unit tests..."
for bin in "${BINARIES[@]}"; do
    if [ "$COVERAGE" = "1" ]; then
        LLVM_PROFILE_FILE="$bin.profraw" "$bin"
    else
        "$bin"
    fi
done

if [ "$COVERAGE" = "1" ]; then
    echo "==> Coverage report (src/Core)..."
    profdata="$TEST_BUILD_DIR/tests.profdata"
    xcrun llvm-profdata merge -sparse "${BINARIES[@]/%/.profraw}" -o "$profdata"
    # First binary positional, the rest as -object; trailing source paths
    # restrict the report to the Core modules.
    object_args=("${BINARIES[0]}")
    for bin in "${BINARIES[@]:1}"; do
        object_args+=(-object "$bin")
    done
    xcrun llvm-cov report "${object_args[@]}" -instr-profile="$profdata" \
        "$PROJECT_DIR"/src/Core/*.h "$PROJECT_DIR"/src/Core/*.mm "$PROJECT_DIR"/src/Core/*.cpp
fi
