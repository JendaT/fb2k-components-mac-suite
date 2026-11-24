//
//  IntakeFieldState.h
//  foo_jl_intake
//
//  What process_field reads, and which rows a field refresh must reach
//  (B13 item 4; doc 04 "Title-formatting fields"). SDK-free; Integration
//  (IntakeFieldProvider) owns the atomic pointer, the publication on the
//  main thread, the throttle and the playlist enumeration.
//
//  FieldState: one immutable bundle of the published IntakeView and the
//  VolumeTable. value() maps a row path the way decorate() does, with the
//  table in place of g_get_native_path:
//    "/..." and "file://..."     -> the view (IntakeView::recordFor:
//                                   normalisation, mount alias, snapshot)
//    "mac-volume://<UUID>/<rest>" -> table root + "/" + <rest> -> the view
//    another scheme, a volume the table does not know, an inert view or an
//    empty one, no record          -> no value
//  and then the record's precomputed value (IntakeRecord::fields; an empty
//  one is no value). No lock, no shared_ptr copy, no allocation for an
//  already-normal ASCII path once the caller's scratch buffers have grown;
//  O(path length) plus the snapshot's ancestor walk. A path with a
//  non-ASCII byte goes through CoreFoundation for NFC only when its ASCII
//  folder lies near a root (IntakeView::mayHaveRecord): rows elsewhere on an
//  SMB share with decomposed names cost about what ASCII rows do. The
//  scratch remembers the last row it mapped, by state and path bytes, so the
//  three fields of one row (one format_title, evaluated in turn on one
//  thread) map it once.
//
//  FieldDirtySet: the rows a refresh must reach. Requirement: every
//  playlist row whose value may differ from what a host last got since the
//  previous refresh is refreshed, including through states that came and
//  went inside the throttle window; a superset is fine, a missed row is
//  not. Each publish adds to the set:
//   - A new view (addViewChanges). Per root, by id: its old and its new
//     match key whenever the key, the member list or one of the three
//     values differs, or the root came or went. An inert or empty view
//     counts as one where nothing has a value. When the two views were
//     keyed with different mount alias tables (a mount or unmount), every
//     key of both: a row's own key may move under an unchanged root.
//   - A new volume table (addVolumeChanges). For every volume id whose root
//     came, went or moved, its old root is noted, and when the view of that
//     moment shows anything, all of its root keys are added. Volume changes
//     are rare (the seed at start, a mount event, a learned stale id) and
//     intake roots cover few rows.
//  Keys are directory prefixes: a row is dirty when its match key is a key
//  or lies under one (a member list lies under its root: sidecar paths have
//  no "." or ".." segment). Keys are kept per mount alias table, and a row
//  is tested against each group with that group's table, as recordFor()
//  would have keyed it then.
//
//  matches() tests a row by its path: a mac-volume row once for each root
//  its volume id had in the window (the current root and the noted ones),
//  other rows once. Why that is enough: a host's value came from some state
//  in the window. If the row's value changed since, some step in the window
//  changed it. A view step: the row's key, built with the volume root of
//  that moment (the current root, or one noted when the id moved later),
//  lies under a key the step added. A volume step: the row, with the old or
//  the new root, lies under a root of the view of that moment, all of whose
//  keys were added. Each window catches its own steps, so a row that no
//  window caught kept its value since its last refresh.
//
//  Thread-safety: a FieldState, and a FieldDirtySet nobody writes, may be
//  read from any number of threads at once. Writes need one owner (the main
//  thread in production).
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "IntakePathMap.h"
#include "IntakeView.h"
#include "IntakeVolumeTable.h"

namespace intake {

// Per-thread buffers for FieldState::value() and FieldDirtySet::matches();
// keep one per thread and reuse it.
struct FieldScratch {
    ViewScratch view;
    std::string native;
    // FieldState::recordFor's last answer: the state's serial (0: none),
    // the row path and its record. Keyed by serial, never by address, as a
    // retired state's memory may hold a later state.
    uint64_t lastSerial = 0;
    std::string lastPath;
    const IntakeRecord *lastRecord = nullptr;
};

class FieldState {
public:
    // A null view or table stands for the empty one.
    FieldState(std::shared_ptr<const IntakeView> view, std::shared_ptr<const VolumeTable> volumes);

    const std::shared_ptr<const IntakeView> &view() const { return view_; }
    const std::shared_ptr<const VolumeTable> &volumes() const { return volumes_; }
    // Some row can have a value (the view is neither inert nor empty).
    bool showsValues() const { return shows_; }
    // Unique per state in this process, starting at 1.
    uint64_t serial() const { return serial_; }

    // The record owning the row `itemPath` (foobar2000's path, see the top
    // of this file), or nullptr; always nullptr when !showsValues().
    const IntakeRecord *recordFor(std::string_view itemPath, FieldScratch &scratch) const;
    // Field `index` of that row: true with `out` viewing the record's value
    // (valid while this state lives). False when there is no record, the
    // index is past the end or the value is empty.
    bool value(uint32_t index, std::string_view itemPath, FieldScratch &scratch, std::string_view &out) const;

    FieldState(const FieldState &) = delete;
    FieldState &operator=(const FieldState &) = delete;

private:
    std::shared_ptr<const IntakeView> view_;
    std::shared_ptr<const VolumeTable> volumes_;
    bool shows_ = false;
    uint64_t serial_ = 0;
};

class FieldDirtySet {
public:
    // A normalized match key, as built with `aliases` (null: no aliases).
    void addKey(const std::shared_ptr<const MountAliases> &aliases, std::string_view key);
    // Every root key of `view`, in its alias group.
    void addAllKeys(const IntakeView &view);
    // `root` was the root of volume `uuid` at some point in this window.
    void noteVolumeRoot(std::string_view uuid, std::string_view root);

    // No key: nothing to refresh (noted roots alone dirty no row).
    bool empty() const { return keyCount_ == 0; }
    size_t keyCount() const { return keyCount_; }
    size_t groupCount() const { return groups_.size(); }

    // The row `itemPath` may have changed (see the top of this file).
    // `current` is the volume table at the refresh.
    bool matches(std::string_view itemPath, const VolumeTable &current, FieldScratch &scratch) const;

private:
    struct Group {
        std::shared_ptr<const MountAliases> aliases;
        PathMap<char> keys;
    };
    struct NotedVolume {
        std::string uuid;
        std::vector<std::string> roots;
    };
    Group &groupFor(const std::shared_ptr<const MountAliases> &aliases);
    bool keyMatches(std::string_view nativePath, FieldScratch &scratch) const;

    std::vector<Group> groups_;
    std::vector<NotedVolume> volumes_;
    size_t keyCount_ = 0;
};

// See the top of this file. Either view may be null (no view yet).
void addViewChanges(const IntakeView *before, const IntakeView *after, FieldDirtySet &out);

// See the top of this file. `view` is the view published at that moment
// (null: none yet).
void addVolumeChanges(const VolumeTable &before, const VolumeTable &after, const IntakeView *view,
                      FieldDirtySet &out);

} // namespace intake
