# Testable Core Pattern

How SimPlaylist (1.5.0) and the Last.fm Scrobbler (post-1.4.0) structure logic
so it is unit-testable without the foobar2000 SDK, Xcode, or a running host.
Apply this pattern when adding logic to any component.

## The rules

1. **Pure logic lives in `src/Core/` (or a pure header next to its service)
   and never touches the foobar2000 SDK.** Replace SDK types at the boundary:
   `t_size` -> `size_t`, `pfc::string8` -> `std::string`/`const char*`,
   metadb/file_info reads happen in the caller. Foundation value types
   (NSString, NSDictionary, NSDate) are acceptable; AppKit is not.

2. **Host data crosses the boundary one of three ways:**
   - plain event/parameter values (Scrobbler `PlaybackTracker`: durations,
     times, stop reasons in; decision structs out),
   - mirrored properties the UI copies in (SimPlaylist `PlaylistLayoutModel`),
   - `std::function` callback structs whose lambdas wrap the SDK
     (SimPlaylist `GroupBuildCallbacks`).

3. **Inject time and secrets.** No `[NSDate date]`, `time(nullptr)`, or
   `CFAbsoluteTimeGetCurrent()` inside testable logic — take `now` (or a clock
   block) as a parameter. API secrets are passed in, never read from
   `SecretConfig.h` inside the pure layer, so tests build without credentials.

4. **The shell stays thin.** Views/services keep drawing, locking, dispatch,
   NSURLSession, persistence, and notifications, and forward decisions/geometry
   to the pure module. If a method in a shell grows a branch that isn't I/O,
   it belongs in Core.

## Test harness

- Tests live in `Tests/` and are **not** part of the Xcode project (the
  project generator only globs `src/`).
- Each test file is a standalone binary: custom `CHECK`/`CHECK_EQ` macros,
  `int main()`, exit code = failure count clamped to 1. No XCTest.
- `Scripts/run_tests.sh` compiles each with bare `clang++` (plus
  `-framework Foundation` for `.mm`) and runs them — ~1s total.
- `Scripts/build.sh` runs `run_tests.sh` first and aborts the build on
  failure. Tests are a gate, not a suggestion.
- Prefer oracle/equivalence tests for extracted code: golden vectors
  (e.g. precomputed MD5 signature), naive reference implementations,
  randomized sweeps with a seeded PRNG (see `ReorderPlannerTests.cpp`).

## Where the pattern is applied

| Component | Pure modules | Tests |
|-----------|--------------|-------|
| SimPlaylist | PlaylistLayoutModel, PlaylistSelectionModel, ReorderPlanner, SubgroupDetector, GroupBuilder | ~108k checks |
| Scrobbler | PlaybackTracker, ScrobbleRules, LastFmRequestBuilder, LastFmResponseParser, ScrobblePolicy, ScrobbleQueueModel, RateLimiter, StreakValidity, StreakWalker, WidgetLayoutMath | ~430 checks |

The Scrobbler widget also demonstrates the compute-then-draw inversion:
`computeGeometry` builds every interactive rect (header pills, item
tiles, content/scroll metrics) via `WidgetLayout::headerGeometry` /
`contentGeometry` before any drawing, and both `drawRect:` and mouse
hit-testing consume the same stored rects. Rects must never be produced
as a side effect of drawing.
