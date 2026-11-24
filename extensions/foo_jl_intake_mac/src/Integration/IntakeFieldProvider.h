//
//  IntakeFieldProvider.h
//  foo_jl_intake
//
//  The title-formatting fields %intake_status%, %intake_target% and
//  %intake_collection% (B13 item 4; doc 04 "Title-formatting fields"): a
//  metadb_display_field_provider_v2 (IntakeFieldProvider.mm) and the
//  refreshes it owes the hosts. These are the entry points IntakeService and
//  the decorator provider drive it with.
//
//  process_field (any thread, many at once, inside a metadb lock it must
//  not take itself): reads one immutable FieldState (IntakeFieldState: the
//  view and the volume table) through an atomic pointer, with no lock, no
//  shared_ptr copy and no foobar2000 call but the handle's get_path(), and
//  thread-local scratch buffers. process_field and process_field_v2 answer
//  alike.
//
//  Publication (main thread only): a new FieldState is swapped in for every
//  view the loader publishes (it arrives on the loader queue and hops to
//  main) and for every volume table change. The state it replaces is
//  deleted on main 10 s later, so no process_field still running can hold
//  it; after on_quit nothing is deleted any more (leaked at quit, like the
//  decorator provider's state).
//
//  "Used": an atomic flag set by the first process_field call. Until then
//  no host holds a value, so nothing is diffed and nothing is refreshed:
//  users who never use the fields pay for one FieldState per publish, the
//  volume seed, and the learn check on decorated mac-volume rows (below)
//  only. The flag and the state pointer are both
//  sequentially consistent, so a publish either sees the flag (and diffs)
//  or the first call reads the new state.
//
//  Refresh (main thread): each publish after first use adds the rows that
//  may have changed to a FieldDirtySet. At most once per second (and 0.25 s
//  after the first change, to coalesce a burst), when that set holds
//  something, every playlist's items are read once (playlist_manager), the
//  set is moved out with the volume table of that moment, the rows are
//  tested on a background queue, and metadb_io::dispatch_refresh gets the
//  matching handles (each once) back on main. No call when nothing matched.
//  One Debug line per refresh: "fields: refreshed N of M playlist rows in X
//  ms (main thread Y ms)". Items in no playlist (a library viewer, the
//  Properties dialog) are not refreshed: they show the new values only
//  when their host formats them again for another reason.
//
//  Volume table (IntakeVolumeTable): seeded on a background serial queue,
//  so a share that does not answer cannot block the main thread: for each
//  mount under /Volumes (IntakeMounts readMountTable, MNT_NOWAIT),
//  filesystem::g_get_canonical_path("<mount>/") and g_get_native_path of
//  the "mac-volume://<UUID>/" it returns, each call timed (one Info line
//  for a call over 20 ms). The table is published on main. Re-seeded on
//  every mount or unmount notification and on Refresh, coalesced with a
//  seed still running. Also learned from the decorate path
//  (fieldsNoteNativePath), from the start: SimPlaylist keeps the
//  decorations of rows it drew and does not decorate them again when a
//  field is first used, so learning only after first use would leave a
//  stale volume id of rows already on screen unknown.
//
//  Thread-safety: as noted per function.
//

#pragma once

#include <memory>

namespace intake {

class IntakeView;

// Main thread, on_init: starts the first volume seed.
void fieldsStart();

// Any thread (the loader queue): the view the loader just published.
// Swapped in on the main thread, in publish order.
void fieldsPublishView(std::shared_ptr<const IntakeView> view);

// Main thread: re-reads the mount table and re-seeds the volume table on
// the seed queue (a no-op before fieldsStart and after fieldsShutdown).
// `why` ("mount change", "refresh") is for the Debug line.
void fieldsReseedVolumes(const char *why);

// Any thread (decorate): `itemPath` was converted to `native` by
// g_get_native_path (IntakeNativePath). A mac-volume row of a volume id the
// table does not know teaches it the volume's root (published on main, and
// refreshed once the fields are used), whether or not a field was used yet.
// For a row of a known volume: the id split, an atomic load and an id
// lookup in a short table. For an id already on its way or refused: that
// plus a short lock.
void fieldsNoteNativePath(const char *itemPath, const char *native);

// Main thread, on_quit: no publication, refresh, seed or deletion after
// this; process_field keeps answering from the last state.
void fieldsShutdown();

} // namespace intake
