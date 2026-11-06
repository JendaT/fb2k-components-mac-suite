# Testing

Unit tests cover the SDK-free logic in `src/Core/`. They gate the build:
`Scripts/build.sh` runs `Scripts/run_tests.sh` first and aborts if anything
fails.

```bash
./Scripts/run_tests.sh              # compile + run (~1s)
./Scripts/run_tests.sh --coverage   # per-file line coverage for src/Core
```

## Why it is this shape

There is no test framework and no Xcode test target. Each test is a plain
`main()` compiled directly by clang against Foundation (or nothing at all).
That is what keeps the suite fast enough to run on every build, and it only
works because the modules under test have no foobar2000 SDK and no AppKit
dependency. Anything needing `metadb_handle`, `configStore`, or a `CGContext`
cannot be tested this way — which is the point: it is pressure to keep logic
out of the SDK and UI layers.

Tests run under ASan and UBSan. UBSan findings abort rather than warn, so
they gate like any other failure. The component build itself is never
sanitized.

## Adding a test

Drop `Tests/FooTests.cpp` (or `.mm`) next to the others; discovery is
automatic. Conventions:

- `Tests/FooTests.cpp` links `src/Core/Foo.cpp` when that file exists.
  Header-only modules need nothing.
- Extra sources: `// TEST_DEPS: src/Core/WaveformData.cpp` (project-relative,
  no spaces in paths).
- Extra link flags: `// TEST_LIBS: -lz`.
- Both markers need exactly one space after `//`, or they are silently
  ignored and you get a link error instead.
- `.cpp` compiles as plain C++, `.mm` as Objective-C++ with Foundation.

Use `TestSupport.h` (the redesign's suites still use the older `TestHarness.h`
with `CHECK` / `CHECK_EQ` / `CHECK_FLOAT_EQ` and `TEST_MAIN_END()`; both work):
`TEST_CASE("name")` labels the section, `CHECK(cond,
"what")` and `CHECK_NEAR(actual, expected, epsilon, "what")` assert, and
`testsupport::summarize("SuiteName")` returns the exit code from `main()`.
`CHECK_NEAR` fails on NaN, which a bare inequality would let through.

## What is covered

| Module | Covers |
|--------|--------|
| `TrackAnalyzer` | integrated loudness and gating, LRA, true peak, clip runs, Lo/Mid/Hi bands, correlation, column aggregation and mixdown, segments joining into one sequential pass (including clip runs at boundaries), the v2 cache round trip and rejection of truncated/corrupt blobs |
| `LayeredShape` | dBFS fractions, peak and loudness-body heights, tint positions |
| `SimpleShape` | linear lanes, asymmetric min/max, RMS core, one-lane mixdown |
| `ThemeTokens` | OKLCH conversion and gamut mapping, derived deep / hot / guide colours, the body tint ramp |
| `WaveformGeometry` | channel layouts, bucket-to-pixel mapping, band ranges and alpha, pointer-to-seek clamping, redraw threshold |
| `WaveformColorMap` | heat map and rainbow ramps, gamut bounds, exact ARGB round trip, BPM sync, oscillator bounds |
| `GradientBandTable` | index/value round trip, out-of-range and unknown stored values |
| `CachePolicy` | eviction count and bounds, prune cutoff, age, cache key identity |

## What these tests do not cover

Drawing, playback callbacks, SQLite, config persistence, and the decode path
all still need the running host. When changing render or scan behaviour, the
useful check is a differential one: transcribe the previous implementation
next to the new one and compare outputs over generated inputs. That is how
the Core extraction was validated — the binner was confirmed bit-identical
across chunk boundaries and short tracks (and again, after the parallel
segment scan moved into it; the analysis pass in `TrackAnalyzer` has since
replaced the binner, against that implementation across segment
counts, chunk sizes, over/under-length decodes, the rate-change fallback and
float/double samples, with a ThreadSanitizer run over concurrent segments),
and the rendering restructure was
confirmed to emit the same segments, comparing within-band order loosely
since a band is stroked as a single path. Those harnesses were throwaway and
are not in the repo; rebuild one when the situation calls for it rather than
trusting a visual glance.
