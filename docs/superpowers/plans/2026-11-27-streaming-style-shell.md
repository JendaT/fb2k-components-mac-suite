# Streaming-style Shell + Up Next Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One "Now Playing" up-next list with Play / Play Next / Add to Queue everywhere, an Up Next popover in PlayVanced, a new ShellVanced panel (sidebar + navigable content area hosting existing panels) with an artist browser, and Spotify-style keyboard shortcuts.

**Architecture:** Pure, SDK-free decision logic in header-only `shared/UpNextCore.h` (unit-tested), a thin header-only SDK wrapper `shared/UpNext.h` compiled into each consumer. ShellVanced hosts other components by enumerating `ui_element_mac` services and instantiating them by GUID; it keeps instances alive and swaps visibility.

**Tech Stack:** Objective-C++ / AppKit, foobar2000 SDK 2025-03-07 (C++17), standalone clang test binaries (see `docs/testable-core-pattern.md`).

**Spec:** `docs/superpowers/specs/2026-11-27-streaming-style-shell-design.md`

## Global Constraints

- Build only via `./Scripts/build.sh` in the component dir; success = `BUILD SUCCEEDED` banner. Never call xcodebuild. Use `--regenerate` after adding/removing source files. Implementers build **without** `--install`; the orchestrator installs at the end.
- Implementers do **not** commit; the orchestrator reviews and commits each task.
- Now Playing playlist name: `"Now Playing"` (exact).
- None of the up-next helpers may change the *active* playlist; they may change the *playing* playlist only.
- Shared code is header-only (`inline`), included by relative path (e.g. `#import "../../../../shared/UpNext.h"` from `src/UI/`). Do not add `shared/*.mm` to any target.
- Standalone behaviour of SimPlaylist must be unchanged unless instantiated with `{"vanced": "1"}`.
- Do not edit `~/Library/foobar2000-v2/UI-Layout.txt`.
- Pure logic follows `docs/testable-core-pattern.md` (no SDK, no AppKit in Core headers).
- Version bumps, CHANGELOGs, READMEs and docs are done by the orchestrator in Task 8, not by implementers.

## Review Focus

1. **Playing from a regular playlist, then Play Next / Add to Queue** — current track keeps playing uninterrupted and the next track comes from Now Playing (Task 1 `planEdit` tests + Task 1 manual check).
2. **Now Playing playlist deleted or renamed by the user** — helpers recreate it on next action; popover shows empty state, no crash (Task 1 `findOrCreateNowPlaying`, Task 5 empty state).
3. **Playback stopped** — Play Next inserts after focus (or at 0), nothing auto-starts (Task 1 tests).
4. **Hosted component not installed** — shell shows a placeholder instead of crashing (Task 6 step).
5. **Artist photos for same-name artists** — never show a stranger's photo; ambiguous names without an album-title overlap fall back to the album cover (Task 9 `exactCandidates`/`titlesOverlap` tests).
6. **Playlist list churn while shell is open** (create/rename/delete/reorder playlists, including "Now Playing" being created) — sidebar never shows "Now Playing", selection survives or falls back to Albums (Task 7 `sidebarPlaylists` tests + callback refresh).

---

## Execution order and lanes

| Phase | Tasks (parallel within a phase; disjoint files) |
|---|---|
| 1 | Task 1 (fixer) · Task 6 shell spike (fixer) · GUID fix (orchestrator, inline) — orchestrator commits all before phase 2 |
| 2 | Task 2 (fixer) · Task 4 (fixer) · Task 5 (designer) · Task 7 (designer, only if Task 6 passed) · Task 9 (fixer, **own git worktree**, only if Task 6 passed) |
| 3 | Task 7 agent wires Task 9's artist classes into the sidebar/navigation · Task 8 (orchestrator) |

Task 3 (LibVanced) was dropped: LibVanced is not part of the shell and stays unchanged.

**Worktree note (Task 9):** the SDK folder is gitignored, so in a worktree export `FB2K_SDK_PATH=/Users/codrin/Documents/Workspace/fb2k-components-mac-suite/SDK-2025-03-07` before `./Scripts/build.sh`. Task 9 touches only `extensions/foo_jl_shellvanced_mac/src/Artists/` and `extensions/foo_jl_shellvanced_mac/Tests/Artist*`; Task 7 owns every other shell file, including `Scripts/run_tests.sh`.

---

### Task 1: Shared up-next core + SDK wrapper

**Files:**
- Create: `shared/UpNextCore.h` (pure C++17, no SDK)
- Create: `shared/UpNext.h` (header-only SDK wrapper; includes `UpNextCore.h`)
- Create: `shared/Tests/UpNextCoreTests.cpp`, `shared/Tests/TestHarness.h` (copy of `extensions/foo_jl_simplaylist_mac/Tests/TestHarness.h`)
- Create: `shared/ArtistNames.h` (pure) + `shared/Tests/ArtistNamesTests.cpp`
- Create: `shared/scripts/run_tests.sh` (same conventions as `extensions/foo_jl_simplaylist_mac/Scripts/run_tests.sh`: auto-discover `shared/Tests/*Tests.cpp`, ASan+UBSan, exit non-zero on failure)

**Interfaces — Produces (`namespace upnext`, in `UpNextCore.h`):**
```cpp
enum class Action { PlayNext, AddToQueue };
struct PlaybackState {
    bool playing = false;               // playing or paused
    bool playingFromNowPlaying = false;
    size_t playingIndex = 0;            // index in the playing playlist (valid if playing)
    size_t playingPlaylistCount = 0;    // item count of the playing playlist
    size_t nowPlayingCount = 0;
    std::optional<size_t> nowPlayingFocus; // used when stopped
    bool shuffle = false;
};
struct EditPlan {
    bool copyRemainder = false;          // replace NP with playing playlist [copyFrom, end)
    size_t copyFrom = 0;
    bool switchPlayingToNowPlaying = false;
    bool useFoobarQueue = false;         // PlayNext under shuffle
    size_t insertAt = 0;                 // NP index after any copy
};
EditPlan planEdit(Action action, const PlaybackState& s);
bool isShuffleOrderName(std::string_view name);
struct UpNextSections { bool showCurrent; size_t nextFrom; size_t nextCount; };
UpNextSections buildSections(bool playing, size_t playingIndex, size_t playlistCount);
bool isDuplicateFoobarMenuItem(std::string_view name);
inline constexpr const char* kNowPlayingName = "Now Playing";
```
**Produces (`namespace upnext::fb`, in `UpNext.h`):**
```cpp
t_size findOrCreateNowPlaying();                       // never activates it
void playNow(metadb_handle_list_cref items, t_size startIndex, const char* sourceLabel);
void playNext(metadb_handle_list_cref items);
void addToQueue(metadb_handle_list_cref items);
void playPlaylistIntoNowPlaying(t_size srcPlaylist, t_size startRow); // label "Next from: <name>"
void setSourceLabel(const char* label);
pfc::string8 getSourceLabel();                          // "Now Playing" if unset
PlaybackState currentPlaybackState();
extern/inline const GUID kSourceLabelProperty;         // generate a fresh GUID
```

- [ ] **Step 1: Write failing tests in `shared/Tests/UpNextCoreTests.cpp`**

`planEdit` cases (exact expectations):
- playing from NP, idx 3, NP count 10, PlayNext → `copyRemainder=false, insertAt=4, useFoobarQueue=false, switchPlayingToNowPlaying=false`.
- same, AddToQueue → `insertAt=10`.
- same with `shuffle=true`, PlayNext → `useFoobarQueue=true`; AddToQueue → `useFoobarQueue=false, insertAt=10`.
- playing from other playlist, idx 5, count 12, PlayNext → `copyRemainder=true, copyFrom=5, switchPlayingToNowPlaying=true, insertAt=1`.
- same, AddToQueue → `insertAt=7` (12-5).
- stopped, NP count 4, focus 2, PlayNext → `insertAt=3`; focus none → `insertAt=0`; AddToQueue → `insertAt=4`; `copyRemainder=false` in all.
`isShuffleOrderName`: false for "Default", "Repeat (playlist)", "repeat (TRACK)"; true for "Shuffle (tracks)", "Shuffle (albums)", "Shuffle (folders)", "Random".
`buildSections`: playing idx 2 of 5 → `{true, 3, 2}`; playing last of 5 → `{true, 5, 0}`; stopped count 4 → `{false, 0, 4}`; stopped count 0 → `{false, 0, 0}`.
`isDuplicateFoobarMenuItem`: true for "Play", " play ", "Add to playback queue", "Add to Playback Queue"; false for "Play Next", "Add to Queue", "Playback Statistics".

`ArtistNames.h` (`namespace artistnames`): `std::vector<std::string> splitArtists(std::string_view)`, `bool isVariousArtists(std::string_view)`, `std::string artistKey(std::string_view)`. Tests in `shared/Tests/ArtistNamesTests.cpp`:
- `splitArtists("Radice & Uyak") == {"Radice","Uyak"}`; `"Audiokidnapping vs Der Sandmann"` → `{"Audiokidnapping","Der Sandmann"}`; `"Magnethik Sadhu & Xydur (Trimurti)"` → `{"Magnethik Sadhu","Xydur","Trimurti"}`; `"Psykovsky & Friends"` → `{"Psykovsky"}`; `"A feat. B"`, `"A ft. B"`, `"A x B"`, `"A, B"` → `{"A","B"}`; `"Armec"` → `{"Armec"}`; words containing x/vs inside (`"Xydur"`, `"Vulkan"`) are not split.
- `isVariousArtists`: true for "Various Artists", "various artists", "VA", "V/A"; false for "Vali", "Vavaa".
- `artistKey("KiLLΔTK") != artistKey("KiLLATK")` is acceptable; `artistKey("Beyoncé") == artistKey("beyonce")`; `artistKey("D.o.c.") == artistKey("doc")`; `artistKey("Alice D") != artistKey("Alice DJ")`.

- [ ] **Step 2: Run** `shared/scripts/run_tests.sh` — expected: FAIL (functions undefined).
- [ ] **Step 3: Implement `shared/UpNextCore.h` and `shared/ArtistNames.h`** to the interfaces above (accent folding: a small built-in Latin-1/Latin-Extended-A fold table is enough; no ICU).
- [ ] **Step 4: Run** `shared/scripts/run_tests.sh` — expected: all pass, exit 0.
- [ ] **Step 5: Implement `shared/UpNext.h`.** Approach:
  - `currentPlaybackState()` from `playback_control::is_playing`, `playlist_manager::get_playing_item_location`, NP index via `find_playlist(kNowPlayingName)`, `playback_order_get_name(playback_order_get_active())` → `isShuffleOrderName`.
  - `playNext`/`addToQueue`: `planEdit`; if `copyRemainder`: clear NP, insert playing playlist items `[copyFrom, end)`, `set_playing_playlist(np)`, set NP focus 0, label "Next from: <playing playlist name>"; then insert items at `insertAt`; if `useFoobarQueue`, `queue_add_item_playlist(np, insertAt + i)` for each inserted item.
  - `playNow`: clear NP, insert, set label, then start at `startIndex` via `playlist_execute_default_action(np, startIndex)`; must not call `set_active_playlist`.
  - Label stored with `playlist_set_property(np, kSourceLabelProperty, bytes)`.
- [ ] **Step 6: Compile check** — temporarily `#import` `UpNext.h` from `extensions/foo_jl_playvanced_mac/src/Integration/Main.mm`, run `./Scripts/build.sh` there → `BUILD SUCCEEDED`; remove the import again.

### Task 2: AlbumViewVanced unified actions

**Files:** Modify `extensions/foo_jl_albumviewvanced_mac/src/UI/AlbumViewVancedController.mm` (play path `:374-400`, queue `:402-436`, menu `:460-612`, Now Playing helpers `:634-700`), `src/UI/AlbumGridView.mm` (`keyDown` `:786-814` only if Q routing lives there), `src/Core/*Config*` (remove `kStableNowPlayingPlaylistName` if unused).

**Consumes:** `upnext::fb::playNow/playNext/addToQueue`, `upnext::isDuplicateFoobarMenuItem`, `artistnames::*` (Task 1).
**Produces:** selector `setArtistFilter:` (NSString or nil) on the AlbumViewVanced view controller.

- [ ] **Step 1:** `playPaths:startIndex:` → build handles as today, call `upnext::fb::playNow(items, startIndex, <album title>)`. No queue flush, no `set_active_playlist`.
- [ ] **Step 2:** Menu top section in this order: Play, Play Next, Add to Queue (key equivalent `q`), Add to Playlist ▸ (existing submenu, still excluding Now Playing), separator, foobar tree. Remove "Add to Now Playing" and "Add to Playback Queue" items and their now-dead methods.
- [ ] **Step 3:** In the recursive foobar-menu builder (`:580-612`), skip nodes where `upnext::isDuplicateFoobarMenuItem(name)` is true.
- [ ] **Step 4:** Q key → Add to Queue (`upnext::fb::addToQueue`).
- [ ] **Step 5: Artist filter.** Add `- (void)setArtistFilter:(nullable NSString *)name;` on the controller (declared in its header, but the shell calls it via `respondsToSelector:`/`performSelector:` — keep the exact selector). Owned albums = album artist's `artistnames::splitArtists` parts contain a part with equal `artistKey`; appears-on = any track artist part matches but not owned. Owned first, then an "Appears on" section label in the grid; search field hidden while a filter is set; `nil` restores everything. Exclude `isVariousArtists` names from owned matching.
- [ ] **Step 6:** ⌘F / ⌘L (`performKeyEquivalent:` on the controller's view, only when the window is key) → focus the search field (`makeFirstResponder:`), unless an artist filter hides it.
- [ ] **Step 7:** `./Scripts/build.sh` → `BUILD SUCCEEDED`. Grep shows no remaining `queue_flush` or `set_active_playlist` in the play path.

### Task 4: SimPlaylist shell mode

**Files:** Modify `extensions/foo_jl_simplaylist_mac/src/Integration/Main.mm:30-60` (read `arg`), `src/UI/SimPlaylistController.{h,mm}` (double-click `~:2300-2345`, context menu `:2418-2436`, recursive builder `:2594-2627`, Q key).

**Consumes:** `upnext::fb::playPlaylistIntoNowPlaying/playNext/addToQueue`, `upnext::isDuplicateFoobarMenuItem`.
**Produces:** SimPlaylist honours instantiate param `@{@"vanced": @"1"}`.

- [ ] **Step 1:** In `instantiate`, `NSDictionary* params = fb2k::unwrapNSObject(arg)` (nil-safe); set `controller.vancedMode = [params[@"vanced"] isEqualToString:@"1"]`. Log once to console what keys foobar passes for a normal layout instance (record the finding in the task report; remove the log after).
- [ ] **Step 2:** When `vancedMode`: double-click/Enter → `playPlaylistIntoNowPlaying(active, row)` (bypasses `kDoubleClickPreservesQueue` path); context menu prepends Play / Play Next / Add to Queue + separator and filters duplicates in the foobar tree; Q → `addToQueue(selection)`.
- [ ] **Step 3:** When not `vancedMode`: zero behaviour change (diff review).
- [ ] **Step 4:** `./Scripts/build.sh` → existing unit tests pass and `BUILD SUCCEEDED`.

### Task 5: PlayVanced Up Next popover (designer)

**Files:**
- Create: `extensions/foo_jl_playvanced_mac/src/UI/UpNextPopoverController.{h,mm}`
- Modify: `src/UI/NowPlayingView.{h,mm}` (button in `setupSubviews` ~`:112`, `layout` `:258-365`, delegate method), `src/UI/PlayVancedController.mm` (owns popover), `src/Integration/PlayVancedCallbacks.mm` (add `playlist_callback_static` + `playback_queue_callback` forwarding through `PlayVancedCallbackManager`).

**Consumes:** `upnext::buildSections`, `upnext::fb::getSourceLabel`, `upnext::fb::findOrCreateNowPlaying`, `upnext::isShuffleOrderName` (Task 1).

- [ ] **Step 1:** Button: SF Symbol `list.bullet`, between rating and shuffle, same size/tint rules as other transport buttons, tooltip "Up Next", highlighted while popover shown. Narrow widths: hide it after the rating when space runs out (follow existing layout priorities).
- [ ] **Step 2:** `NSPopover` (transient, ~360×480) with `NSTableView` sections: **Now playing**, **Queued** (foobar queue via `queue_get_contents`, only if non-empty), **Next from: <label>** using `buildSections` over the playing playlist (NP when stopped). Shuffle note "Shuffle is on — order may differ" when `isShuffleOrderName`. Empty state "Nothing up next". Rows: small art if cheaply available (else none), title, artist, duration.
- [ ] **Step 3:** Interactions on NP rows: double-click → `playlist_execute_default_action(np, idx)`; drag reorder → `playlist_reorder_items`; Delete key and context "Remove" → `playlist_remove_items`; "Clear" button removes items after the playing one. Rows from a non-NP playing playlist are read-only.
- [ ] **Step 4:** Refresh on new track/stop, NP item add/remove/reorder, playing-playlist change, queue change; coalesce to one reload per run-loop turn; only while popover is shown.
- [ ] **Step 5: Shortcuts** in new `src/Integration/PlayVancedShortcuts.mm` (local `NSEvent` key-down monitor installed once, removed at shutdown): Space play/pause (skip when first responder is an `NSText`/field editor or the event's window isn't the foobar main window), ⌘→/⌘← next/previous, ⌘↑/⌘↓ volume ±(use `playback_control::volume_up/volume_down`), ⌘S toggle shuffle (reuse the controller's shuffle toggle), ⌘R cycle repeat (reuse controller), ⌥⌘U toggle the Up Next popover (on the first registered controller). Consume handled events.
- [ ] **Step 6:** `./Scripts/build.sh --regenerate` → `BUILD SUCCEEDED`.

### Task 6: ShellVanced scaffold + hosting spike (hard gate)

**Files:** Create `extensions/foo_jl_shellvanced_mac/` mirroring `foo_jl_playvanced_mac` (Scripts/, `generate_xcode_project.rb`, Resources/, `src/Integration/Main.mm`, `src/UI/ShellVancedController.{h,mm}`, README stub, CHANGELOG stub). Modify `shared/version.h` (`SHELLVANCED_VERSION "0.1.0"`), `shared/sdk_config.rb`, `Scripts/package.sh`, `Scripts/release_component.sh` as `Scripts/new-component.sh` would. Do **not** run the steps that create a worktree or touch `~/.local/bin` / `~/.zsh` — replicate the repo-file edits manually.

**Produces:** ui_element "ShellVanced", fresh GUID, `match_name` for `ShellVanced`/`shellvanced`/`vanced_shell`; helper
```objc
// returns nil if the component isn't installed
NSViewController* SVInstantiateElement(const GUID& guid, NSDictionary<NSString*,NSString*>* params);
```
using `for (auto e : ui_element_mac::enumerate()) if (e->get_guid() == guid) …instantiate(fb2k::wrapNSObject(params))` + `fb2k::unwrapNSObject`.
GUIDs: AlbumViewVanced `{B4E8F3A2-9C5D-4E6B-AF7E-2D3C4B5A6E7F}`, SimPlaylist `{8FE5C4B4-619D-4D89-8567-1D96C32E2162}`.

- [ ] **Step 1:** Scaffold; `./Scripts/build.sh --regenerate` → `BUILD SUCCEEDED`.
- [ ] **Step 2:** Spike: controller view hosts AlbumViewVanced via `SVInstantiateElement` filling the view; placeholder label "Install AlbumViewVanced to use this section" when nil. Build → `BUILD SUCCEEDED`.
- [ ] **Step 2b:** On first instantiate, log every `NSApp.mainMenu` item with a key equivalent (recursively: menu path, modifiers, key) to the foobar console with prefix `[ShellVanced] key:`, on the next run-loop turn so dynamic menus exist. (Removed in Task 7.)
- [ ] **Step 3:** Report back for the orchestrator's in-app check (orchestrator installs ShellVanced, adds it to a test layout, confirms the grid renders and works; also checks that hosted controllers unregister from their singleton callback managers on teardown — read `PlayVancedCallbacks.mm:22`-style code in AlbumViewVanced). **Gate:** if hosting fails, stop Task 7 and apply the spec fallback.

### Task 7: ShellVanced sidebar, navigation, playlists (designer)

**Files:** Create `extensions/foo_jl_shellvanced_mac/src/Core/ShellCore.h` (pure), `Tests/ShellCoreTests.cpp` + `Tests/TestHarness.h`, `Scripts/run_tests.sh` (gate in build.sh like SimPlaylist), `src/UI/ShellSidebarController.{h,mm}`, `src/Integration/ShellPlaylistCallbacks.mm`; modify `ShellVancedController.mm`.

**Produces (`namespace shellcore`):**
```cpp
enum class DestKind { Albums, Playlist, Artist };
struct Destination { DestKind kind; std::string name; bool operator==(const Destination&) const; }; // name: playlist or artist
class NavHistory {
public:
    void push(const Destination& d);   // no-op if equal to current; truncates forward stack
    bool canGoBack() const; bool canGoForward() const;
    std::optional<Destination> back(); std::optional<Destination> forward();
    std::optional<Destination> current() const;
};
std::vector<size_t> sidebarPlaylists(const std::vector<std::string>& names); // excludes exact "Now Playing"
```

- [ ] **Step 1: Failing tests** `Tests/ShellCoreTests.cpp`: push A,B,C → back()==B, back()==A, canGoBack false; push D after back → canGoForward false; push same as current doesn't grow history; `sidebarPlaylists({"Now Playing","Hitech","Tek"}) == {1,2}`; `{"now playing"}` is kept (exact match only); empty → empty.
- [ ] **Step 2:** `Scripts/run_tests.sh` → FAIL; implement `ShellCore.h`; → PASS.
- [ ] **Step 3: Layout** — `NSSplitView`: source-list sidebar (min 180, default 220, collapsible) + content container with a top row: back/forward buttons + destination title.
- [ ] **Step 4: Sidebar** — fixed **Albums** row; **Your Library** header with + (creates "New Playlist" and starts inline rename) and filter chips **[Playlists] [Artists]** (none selected = both; persist selection). Playlists: `sidebarPlaylists` with item counts. Artists: rows from Task 9's `SVArtistLibrary` (32 px round photo from `SVArtistImageProvider`, name) — until Task 9 lands, stub the Artists section behind the chip. Select playlist → `set_active_playlist(idx)` + show hosted SimPlaylist (`{"vanced":"1"}`). Context menu: Play (`upnext::fb::playPlaylistIntoNowPlaying(idx,0)`), Rename, Delete. Drop targets: file URLs and `com.foobar2000.simplaylist.rows` (model: `extensions/foo_jl_plorg_mac/src/UI/PlaylistOrganizerController.mm:550`) → append to that playlist.
- [ ] **Step 5: Hosting/navigation** — lazy `SVInstantiateElement` per destination kind, keep alive, swap `hidden`; navigation goes through `NavHistory`; refresh sidebar via `playlist_callback` (created/removed/renamed/reordered/items count); if the shown playlist disappears, navigate to Albums. Persist last destination + sidebar width (cfg vars).
- [ ] **Step 6: Shortcuts** via `performKeyEquivalent:` on the shell's root view: ⌘F/⌘L focus the first visible `NSSearchField` in the current content (Albums home) — on a playlist or artist page, no-op; ⌘[ / ⌘] back/forward; ⌘1 Albums; ⌘N new playlist; ⌃⌘S toggle sidebar. Remove the Task 6 key-dump logging. If the orchestrator reports a collision from the key dump, use the replacement key it gives you.
- [ ] **Step 7:** `./Scripts/build.sh --regenerate` → tests pass, `BUILD SUCCEEDED`.
- [ ] **Step 8 (phase 3, after Task 9 lands): Artist page.** Destination `Artist(name)`: show Task 9's `SVArtistHeaderView` above the hosted AlbumViewVanced and call `setArtistFilter:name` (via `respondsToSelector:`); leaving the artist page calls `setArtistFilter:nil` and hides the header. Header Play/Shuffle → `upnext::fb::playNow(handles, 0, "Next from: <artist>")` with handles from `SVArtistLibrary` (shuffled copy for Shuffle). Build → `BUILD SUCCEEDED`.

### Task 9: Artist library + photos (fixer, own worktree)

**Files:** Create under `extensions/foo_jl_shellvanced_mac/`: `src/Artists/ArtistIndexCore.h` (pure), `src/Artists/DeezerMatchCore.h` (pure), `src/Artists/SVArtistLibrary.{h,mm}`, `src/Artists/SVArtistImageProvider.{h,mm}`, `src/Artists/SVDeezerClient.{h,mm}`, `src/Artists/SVArtistHeaderView.{h,mm}`, `Tests/ArtistIndexCoreTests.cpp`, `Tests/DeezerMatchCoreTests.cpp`.

**Consumes:** `artistnames::*` (Task 1).
**Produces:**
```cpp
namespace artistindex {
struct TrackRow { std::string albumArtist, artist, album, date; size_t trackIndex; }; // trackIndex = caller's handle index
struct ArtistEntry { std::string name; std::string key; std::vector<std::string> ownedAlbums, appearsOnAlbums; std::vector<size_t> trackIndices; std::string newestAlbum; };
std::vector<ArtistEntry> buildIndex(const std::vector<TrackRow>& rows); // sorted by key; VA excluded; album artist falls back to artist
}
namespace deezermatch {
struct Candidate { std::string id, name, pictureUrl; long fans; };
bool hasRealPicture(const std::string& url);                 // false if empty or contains "/images/artist//"
std::vector<size_t> exactCandidates(const std::string& artist, const std::vector<Candidate>&);
std::string normalizeTitle(const std::string& title);       // drop (..)/[..], EP/LP/VA/remaster noise, punctuation, case
bool titlesOverlap(const std::vector<std::string>& user, const std::vector<std::string>& remote); // equal, or ≥6-char containment
}
```
```objc
@interface SVArtistLibrary : NSObject   // singleton; rebuilds from library_manager (debounced 1 s) on library_callback
+ (instancetype)shared;
@property (readonly) NSArray<NSString *> *artistNames;     // display names, sorted
- (metadb_handle_list)handlesForArtist:(NSString *)name;   // owned + appears-on, album/track order
- (NSUInteger)albumCountForArtist:(NSString *)name; - (NSUInteger)trackCountForArtist:(NSString *)name;
- (NSArray<NSString *> *)userTitlesForArtist:(NSString *)name; // album + track titles, for disambiguation
extern NSNotificationName const SVArtistLibraryDidChangeNotification;
@end
@interface SVArtistImageProvider : NSObject
+ (instancetype)shared;
- (void)imageForArtist:(NSString *)name size:(CGFloat)points completion:(void (^)(NSImage *image))completion; // main thread; round-cropped; fallback = newest album cover; placeholder initials if neither
@end
@interface SVArtistHeaderView : NSView
@property (copy) NSString *artistName;      // loads photo + counts
@property (copy) void (^onPlay)(void); @property (copy) void (^onShuffle)(void);
@end
```

- [ ] **Step 1: Failing tests.** `ArtistIndexCoreTests.cpp`: rows {AA="Radice & Uyak", album "X"}, {AA="", artist="Armec", album "Replication EP"}, {AA="Various Artists", artist="Fele", album "Comp"} → artists `Armec` (owned {"Replication EP"}), `Fele` (owned {}, appearsOn {"Comp"}), `Radice` and `Uyak` (owned {"X"}); no "Various Artists" entry; sorted by key; `newestAlbum` picks max `date` (ties → first seen). `DeezerMatchCoreTests.cpp`: `hasRealPicture` false for `"https://e-cdns-images.dzcdn.net/images/artist//250x250-000000-80-0-0.jpg"` and "", true for a URL with a hash; `exactCandidates("Kaya", {Kaya, KAYA, Kayah})` → {0,1}; `exactCandidates("Alice D", {"Alice DJ"})` → {}; `titlesOverlap({normalizeTitle("Replication EP")}, {normalizeTitle("Replication (Remastered)")})` true; `titlesOverlap({"abc"}, {"abcd"})` false (under 6 chars).
- [ ] **Step 2:** Compile/run these tests with bare `clang++ -std=c++17 -I../../shared` (same flags as `shared/scripts/run_tests.sh`) → FAIL; implement the two cores → PASS. (Task 7 adds `Scripts/run_tests.sh`, which will pick these up.)
- [ ] **Step 3:** `SVDeezerClient`: `search/artist?q=&limit=5` and `artist/{id}/albums?limit=100`, NSURLSession, generic User-Agent, ≤ 8 req/s (adapt `shared/RateLimiter.*` by copying into `src/Artists/`), JSON → `deezermatch::Candidate`.
- [ ] **Step 4:** `SVArtistImageProvider` decision: one exact candidate with real picture → use it; several exact → accept only the candidate whose albums overlap `userTitlesForArtist:` (fetch albums lazily); otherwise fallback. Disk cache in `NSCachesDirectory/foo_jl_shellvanced/artists/<sha1(artistKey)>.jpg`; negative results in `.../negative.json` with 30-day TTL; in-memory NSCache. Fallback cover via `album_art_manager_v2` on a track of `newestAlbum`. Round crop at requested size, Retina-aware.
- [ ] **Step 5:** `SVArtistLibrary` + `SVArtistHeaderView` (128 pt round photo, name in large bold, "N albums · M tracks", Play and Shuffle buttons styled like `shared/UIStyles.h`).
- [ ] **Step 6:** In the worktree: `FB2K_SDK_PATH=… ./Scripts/build.sh --regenerate` → `BUILD SUCCEEDED`. Report the worktree path and branch.

### Task 8: Integration, docs, release prep (orchestrator)

- [ ] GUID fix: fresh GUIDs for `g_guid_playback_controls` (`foo_jl_playback_controls_ext/src/Integration/Main.mm:63-65`) and `g_guid_tidal_prefs` (`foo_jl_tidal_mac/src/Integration/Main.mm:99-100`); build both.
- [ ] Merge Task 9's worktree branch (fast-forward or cherry-pick; files are disjoint).
- [ ] Version bumps in `shared/version.h`: AlbumViewVanced, PlayVanced → 1.1.0; SimPlaylist → 1.6.0; Playback Controls → 0.1.1; Tidal → 0.3.2; ShellVanced 0.1.0.
- [ ] CHANGELOG per component + global CHANGELOG (compact style); README updates; `docs/shellvanced.md` (layout snippet from spec §5); `docs/hosting-ui-elements.md` (how to instantiate another component's ui_element_mac, gotchas found in Task 6).
- [ ] `./Scripts/build.sh --clean --install` for every changed component → each `BUILD SUCCEEDED`; `shared/scripts/run_tests.sh` passes.
- [ ] Hand the user a manual checklist (Review Focus items 1–5 + popover interactions) and offer to apply the new layout with a backup of `UI-Layout.txt`.
