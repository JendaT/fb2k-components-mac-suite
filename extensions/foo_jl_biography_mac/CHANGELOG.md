# Changelog - Artist Biography

## [1.1.0] - 2026-07-17

### Added
- Artist image gallery: horizontal thumbnail strip above the biography with a
  full-screen lightbox viewer (keyboard navigation, prefetch)
- Image sources: Fanart.tv (requires MusicBrainz ID), TheAudioDB, Deezer;
  images are deduplicated by URL and sorted by source/type/likes
- MusicBrainz artist lookup: resolves the MBID when Last.fm does not return
  one, unlocking Fanart.tv images for many more artists (no API key needed)
- Wikipedia biography fallback: when Last.fm has no biography text, the
  article summary is resolved accurately via MusicBrainz -> Wikidata ->
  English Wikipedia (never by guessing article titles)
- Dual-layer artist image cache (memory + disk) with request coalescing and
  a 24h TTL for gallery metadata

### Changed
- Testable-core refactor following the SimPlaylist pattern: pure logic
  (response parsing, HTML sanitization, artist-name matching, gallery fetch
  state machine, cache keys, rate-limiter math) now lives in SDK-free Core
  classes with standalone unit tests
- Unit tests gate the build: `Scripts/build.sh` refuses to build the
  component when any of the 9 test suites (838 checks) fail

### Fixed
- Data race in the gallery coordinator: per-source completion flags were
  written from multiple queues without synchronization; a timeout firing
  while sources completed could double-finish or mutate results mid-build
- Crash path in the Fanart.tv client: a malformed MusicBrainz ID produced a
  nil URL that was passed straight to NSURLSession
- All attempted gallery sources failing now reports an error to the UI
  instead of an empty success

### Technical
- New SDK-free Core units: LastFmParsing, ArtistNameMatcher,
  GalleryImageParsing, GalleryFetchState, GalleryCacheKeys,
  MusicBrainzParsing, WikipediaParsing, BiographySource.h
- BiographyRateLimiter accepts an injectable clock source for tests
- New API clients: MusicBrainzClient (strict 1 req/s), WikipediaBioClient
- MusicBrainz/Wikipedia calls send a descriptive User-Agent as required

## [1.0.0] - 2025-12-30

### Added
- Initial release
- Artist biography display from Last.fm API
- Automatic updates on track/artist change with debounce
- SQLite caching with staleness detection
- Offline fallback, loading spinner, error state with retry
