# Changelog — foo_jl_intake

All notable changes to the Intake component are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Component scaffold: builds, registers, and installs as
  `foo_jl_intake.component` (version 0.1.0, registered in `shared/version.h`).
- `IntakeDecoratorProvider` — the intake system's `jl_row_decorator_provider`
  (intake doc 04, Part B), the first real consumer of the Part A extension
  point. Honours the full API contract: thread-safe under concurrent
  off-main-thread `decorate()` calls, non-blocking, supports multiple
  invalidate callbacks and tolerates unregistering an unknown one.
- `IntakeRootIndex` — maps playlist file paths to intake sidecar roots
  (doc 03, "Component read patterns"). Longest-match so a nested root wins
  over its parent, prefix matching constrained to path boundaries so
  `/a/bc` is not treated as a child of `/a/b`, lexical normalization only
  (no filesystem access on the decorate path). 27 checks under ASan+UBSan.

### Notes
- The provider renders nothing yet: it has no state source. Installing this
  build adds an empty 16 pt gutter to SimPlaylist and nothing else, because
  the gutter keys off provider presence rather than activity (doc 04 Part A).
- State acquisition (`intake version` gate, `intake status --json` load,
  FSEvents watch) is deliberately not implemented: it depends on doc 03
  change requests CR-002.1 and CR-002.3, and the context menu additionally
  depends on CR-002.2. See `docs/intake/CHANGE-REQUESTS.md`.
