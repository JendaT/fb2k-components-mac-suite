//
//  IntakeWatchFilter.h
//  foo_jl_intake
//
//  Which file system events matter to the component (PLAN.md B4, 3.5).
//
//  A sidecar name is exactly the CLI's isSidecarName rule
//  (feature/intake-cli tools/intake/src/util.ts):
//    name === ".intake.json" || /^\.intake\.[a-z0-9_]+\.json$/i
//  so ".intake.json" (whole-directory root) and ".intake.<id>.json" (virtual
//  root or single), the second ignoring case. Not sidecars: the CLI's temp
//  files ".intake-tmp-*", doc 05's ".intake-hint.json", ".INTAKE.JSON" (the
//  first form is case-sensitive), ".intake..json" (empty id) and anything
//  with a character outside [A-Za-z0-9_] in the id.
//
//  WatchBatchBuilder collects one debounce window of events into what the
//  loader needs: the directories that hold a changed sidecar (the parent of
//  each sidecar event path, spelled as the event reported it, each once),
//  the directories that were renamed, moved or removed (the event path
//  itself: a folder holding sidecars that moves reports no event for its
//  children, so its roots change without a sidecar event), and whether
//  everything has to be treated as changed (FSEvents dropped events or asks
//  for a subtree rescan). IntakeWatcher decides from the event flags which
//  method to call. Events for other names are ignored.
//
//  WatchEventId: an FSEvents event id, where a stream starts (IntakeWatcher
//  replays the events after it). IntakeLoader takes one just before each
//  `status` call and hands it over with the watch set built from that load.
//
//  Thread-safety: pure functions; a WatchBatchBuilder belongs to one thread
//  (the watcher's queue).
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

namespace intake {

// An FSEventStreamEventId. kWatchSinceNow (kFSEventStreamEventIdSinceNow,
// checked in IntakeWatcher.mm) starts a stream from its creation, with no
// history.
using WatchEventId = uint64_t;
constexpr WatchEventId kWatchSinceNow = ~WatchEventId(0);

// The CLI's isSidecarName, on a file name (no '/').
bool isSidecarFileName(std::string_view name);

// The last component of `path` ("" for a path ending in '/').
std::string_view pathFileName(std::string_view path);

// When the file name of `path` is a sidecar name: true, with `directory`
// set to the path without its last component ("/" for a file directly
// under the root). False otherwise, `directory` cleared.
bool sidecarEventDirectory(std::string_view path, std::string &directory);

// One debounce window's worth of relevant events.
struct WatchBatch {
    // Directories holding a changed sidecar, and directories renamed, moved
    // or removed, as the events spelled them, each once, in arrival order.
    std::vector<std::string> directories;
    // Events were dropped or a subtree needs a rescan: treat every
    // directory as changed.
    bool rescan = false;
    // Sidecar and directory events counted (duplicates included), for the log.
    size_t sidecarEvents = 0;
    size_t directoryEvents = 0;

    bool empty() const { return directories.empty() && !rescan; }
};

class WatchBatchBuilder {
public:
    // One event path. True when it was a sidecar event (and recorded).
    bool addPath(std::string_view path);
    // A directory renamed, moved or removed: records `path` itself. False
    // for an empty or relative path.
    bool addDirectory(std::string_view path);
    // Events were dropped, or a subtree must be rescanned.
    void addRescan() { batch_.rescan = true; }
    bool empty() const { return batch_.empty(); }
    // The batch so far; the builder starts over empty.
    WatchBatch take();

private:
    WatchBatch batch_;
    std::unordered_set<std::string> seen_;
};

} // namespace intake
