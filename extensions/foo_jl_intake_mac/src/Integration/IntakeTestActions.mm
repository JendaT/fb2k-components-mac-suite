//
//  IntakeTestActions.mm
//  foo_jl_intake
//
//  Hidden one-shot helper for in-app acceptance runs against the mock CLI
//  (docs/hidden-options.md, foo_jl_intake.test_actions). Nobody clicks
//  through foobar2000 during those runs, so the steps in that string run
//  once, after the first successful load of the session, and the key is
//  reset to "" before the first step (foobar2000 writes it back at quit).
//
//  Steps (IntakeTestActionScript parses them; ";" between steps):
//    menu <id...>                   logs the items (title, enabled) the
//                                   context menu would show for a selection
//                                   of those roots' rows: the rows are the
//                                   roots' members from the snapshot (a
//                                   whole-folder root: its folder), mapped
//                                   through the same view lookup as a real
//                                   selection, then the same table
//    badge <id...>                  logs the group header badge for a group
//                                   made of those roots' rows (the same rows
//                                   as menu, at most 64 like the host, as
//                                   metadb handles): providerDecorateGroup,
//                                   the provider's own decorate_group code,
//                                   on the main thread. One line: the text
//                                   in quotes and "color #RRGGBBAA", plus
//                                   " (amber)" when the badge is amber
//                                   (whatever colour tint_review gives
//                                   it); or "no badge"
//    propose|approve|reject <id...> builds that table and dispatches the
//                                   item for the action through the same
//                                   path and lane as a click; dialogs are
//                                   skipped and reject uses reason=<text>
//    refresh                        the Refresh item
//    assign <id> collection=<name>  B7: dispatches the quick-assign item
//                                   "Assign to <name>" of that one root, as
//                                   a click does; without such an item it
//                                   logs the menu and runs nothing
//    assign-other <id...> collection=<name>
//                                   B7: the "Assign to other collection…"
//                                   flow without the sheet: runs
//                                   `collections`, then, when <name> is
//                                   listed, the assign through the same
//                                   code as the sheet's OK. One line:
//                                   "collections: N; "<name>" listed|not
//                                   listed; <what happened>"
//    picker <id...> close=<seconds> B7: the real flow and the real sheet;
//                                   one line when it is up (collection
//                                   count, preselected text, OK enabled or
//                                   not), then it is ended as Cancel after
//                                   <seconds> (at most 30): nothing is
//                                   assigned. The next step runs once the
//                                   sheet has closed
//    execute <id...>                B8: Execute placement… through the real
//                                   flow and the real dry run, without the
//                                   sheet: one line once the run was spawned
//                                   (or could not start): "dry run: N
//                                   placeable, M excluded: <the rows the
//                                   sheet would list>; confirmed; started:
//                                   pid P, run file execute-....run"
//    execute-sheet <id...> close=<seconds>
//                                   B8: the real dry run and the real sheet;
//                                   one line when it is up (title, rows,
//                                   buttons), then it is ended as Cancel
//                                   after <seconds> (at most 30): nothing is
//                                   executed. The next step runs once the
//                                   sheet has closed
//    resume <id...>                 B8: the Resume placement item; one line
//                                   once the run was spawned: "started: pid
//                                   P, run file execute-....run"
//    runs                           B8: the tracked runs (command, pid,
//                                   state, ids) and the lane
//    swap <id...>                   B9: selects, in the active playlist,
//                                   the rows that map to those roots by
//                                   income path, builds the menu for them
//                                   (the real per-row mapping) and runs its
//                                   Swap to library paths item as a click
//                                   does. One line once the swap ended:
//                                   "selected N row(s); swap: ..."
//    rows <id>                      B9: one line listing the active
//                                   playlist's rows of that root, by income
//                                   path or through the library index: the
//                                   index, income or library, the native
//                                   path and a handle tag (h1, h2, ...: the
//                                   same tag is the same metadb handle),
//                                   the counts of rows, distinct handles and
//                                   distinct paths, then the menu a
//                                   selection of those rows gets
//    delete <id...>                 B9: Delete local copy… through the real
//                                   flow (the sidecars read afresh, the
//                                   income rows counted), the confirmation
//                                   answered Delete without a sheet. One
//                                   line: what the sheet would list, then
//                                   "answered Delete; gc: started for N
//                                   root(s)" (or why nothing ran)
//    delete-swap <id...>            B9: the same, answered "Swap, then
//                                   delete": the swap's line, then gc or
//                                   "not run: N row(s) ... still point at
//                                   the income paths"
//    delete-sheet <id...> close=<seconds>
//                                   B9: the real confirmation sheet; one
//                                   line when it is up (title, paths,
//                                   buttons), then it is ended as Cancel
//                                   after <seconds> (at most 30): nothing is
//                                   deleted
//    show <id>                      B10, for screenshots: in the active
//                                   playlist, clears the selection, sets the
//                                   focus on that root's last row, then on
//                                   its first (SimPlaylist scrolls a row into
//                                   view when the focus moves from outside,
//                                   so the whole root ends up on screen when
//                                   it fits) and calls playlist_ensure_visible
//                                   on the first. One line: "N row(s), #A to
//                                   #B; selection cleared, focus on #A"
//    tint <slot> <value>            B10: writes tint_<slot> as the
//                                   preferences page does (0xRRGGBBAA, off:
//                                   0, default: the key deleted), then posts
//                                   IntakeSettingsDidChangeNotification like
//                                   the page. Returns at once: the re-tint
//                                   runs on the loader queue and logs its own
//                                   lines, so put a wait after it
//    sweep <rows> [delay=<ms>]      B10, temporary, for the provider-side
//                                   cache-hit gate (decor_stats): stands in
//                                   for scrolling the whole active playlist.
//                                   Clears the selection, then moves the
//                                   focus to 0, <rows>, 2*<rows>, ..., the
//                                   last row, then back to 0
//                                   (sweepPositions), one move every <ms>
//                                   (default 100) with dispatch_after on the
//                                   main queue; SimPlaylist scrolls each
//                                   focus change from outside into view. A
//                                   focus already on row 0 is first set to
//                                   row 1, so the move to 0 really moves.
//                                   Lines: "N moves over C rows, 0 to C-1,
//                                   then back to 0" at the start, "done in
//                                   T s" at the end, or "stopped at move M
//                                   of N: the playlist changed" when the
//                                   active playlist or its row count
//                                   changes. The next step runs after it
//    wait <seconds>                 at most 30
//  Every step logs one line starting "test_actions:" (Info, so log_level 0
//  hides them; log_file mirrors them). Ids that are not in the snapshot,
//  or whose rows map to other roots than the ones named, make the step log
//  and do nothing. Nothing runs after quit starts. assign-other, picker,
//  execute, execute-sheet, resume, swap, delete, delete-swap and
//  delete-sheet wait for their flow to end (a run: to be spawned; delete:
//  gc started or not run) before the next step; sweep for its last move.
//  The steps start after the first successful load and the leftover-run
//  scan.
//
//  Temporary: removed with the other acceptance aids (and
//  Core/IntakeTestActionScript plus its tests) before the merge to main.
//

#import "../fb2k_sdk.h"

#include "IntakeActions.h"
#include "IntakeConfig.h"
#include "IntakeDecoratorProvider.h"
#include "IntakeService.h"
#include "IntakeSwap.h"

#include "../Core/IntakeLog.h"
#include "../Core/IntakeSettingsParse.h"
#include "../Core/IntakeSlowVolumeGuard.h"
#include "../Core/IntakeTestActionScript.h"
#include "../Core/IntakeView.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace intake {

namespace {

const char *const kKey = "test_actions";  // under foo_jl_intake.

// SimPlaylist passes at most this many members to decorate_group.
constexpr size_t kGroupMemberLimit = 64;

bool g_ran = false;  // main thread

std::string joinIds(const std::vector<std::string> &ids) {
    std::string out;
    for (const std::string &id : ids) out += (out.empty() ? "" : " ") + id;
    return out.empty() ? std::string("(none)") : out;
}

// The rows of those roots, through the view's lookup (see the top of this
// file). False with `error` when an id is not in the snapshot. `rowPaths`,
// when given, gets the rows' paths in order.
bool rootsForIds(const IntakeView &view, const std::vector<std::string> &ids,
                 std::vector<const IntakeRecord *> &roots, std::string &error,
                 std::vector<std::string> *rowPaths = nullptr) {
    const IntakeSnapshot &snapshot = view.snapshot();
    std::vector<const IntakeRecord *> rows;
    ViewScratch scratch;
    for (const std::string &id : ids) {
        const IntakeRecord *record = snapshot.recordForId(id);
        if (record == nullptr) {
            error = "not in the snapshot: " + id;
            return false;
        }
        std::vector<std::string> paths;
        auto members = snapshot.members().find(id);
        if (members != snapshot.members().end() && members->second.kind == MemberKind::Members) {
            for (const std::string &relative : members->second.relativePaths) {
                std::string path = record->rootPath;
                if (path.empty() || path.back() != '/') path += '/';
                paths.push_back(path + relative);
            }
        } else {
            paths.push_back(record->rootPath);
        }
        for (const std::string &path : paths) rows.push_back(view.recordFor(path, scratch));
        if (rowPaths != nullptr) rowPaths->insert(rowPaths->end(), paths.begin(), paths.end());
    }
    roots = selectionRoots(rows);
    // The lookup can land on another root (a root with no member list in a
    // folder another root covers, a file two virtual roots list): never
    // act on, or report the menu of, roots the step did not name.
    std::vector<std::string> named;
    for (const std::string &id : ids) {
        if (std::find(named.begin(), named.end(), id) == named.end()) named.push_back(id);
    }
    std::vector<std::string> resolved;
    for (const IntakeRecord *r : roots) resolved.push_back(r->id);
    std::vector<std::string> a = named, b = resolved;
    std::sort(a.begin(), a.end());
    std::sort(b.begin(), b.end());
    if (a != b) {
        error = "the rows map to " + joinIds(resolved) + ", not " + joinIds(named);
        return false;
    }
    return true;
}

std::string menuText(const ActionTable &table) {
    if (table.entries.empty()) return "(no items)";
    std::string out;
    for (const ActionEntry &e : table.entries) {
        if (!out.empty()) out += " | ";
        out += e.title + (e.enabled ? " [enabled]" : " [disabled]");
    }
    return out;
}

// The badge line: "\"<text>\" color #RRGGBBAA", plus " (amber)" when the
// badge is amber (IntakeBadge::amber, from providerDecorateGroup). Not
// decided by the colour: that is the configured tint_review at full alpha,
// any colour, or 0 (#00000000, the host's colour) with tint_review 0.
std::string badgeText(const jl_group_decoration &deco, bool amber) {
    char color[16];
    snprintf(color, sizeof(color), "#%08X", static_cast<unsigned>(deco.badge_color));
    std::string out = "\"" + std::string(deco.badge_text.c_str()) + "\" color " + color;
    if (amber) out += " (amber)";
    return out;
}

void runStep(std::shared_ptr<const std::vector<TestActionStep>> steps, size_t index);

// A report that logs once: a flow may end after its line was logged (a
// sheet's line comes when it is up).
std::function<void(const std::string &)> reportOnce(const std::string &prefix) {
    auto logged = std::make_shared<bool>(false);
    return [prefix, logged](const std::string &line) {
        if (*logged) return;
        *logged = true;
        logInfo(prefix + line);
    };
}

t_size activePlaylistIndex() {
    auto pm = playlist_manager::get();
    const t_size active = pm->get_active_playlist();
    return active < pm->get_playlist_count() ? active : SIZE_MAX;
}

// The `rows` line (see the top of this file).
std::string rowsText(const std::vector<PlaylistRootRow> &rows, const ActionTable &menu) {
    std::unordered_map<const metadb_handle *, size_t> tags;
    std::unordered_set<std::string> paths;
    size_t income = 0, library = 0;
    std::string list;
    for (const PlaylistRootRow &r : rows) {
        auto tag = tags.emplace(r.handle.get_ptr(), tags.size() + 1).first->second;
        paths.insert(r.native);
        (r.library ? library : income)++;
        if (!list.empty()) list += "; ";
        list += "#" + std::to_string(r.index) + " " + (r.library ? "library " : "income ") + r.native + " [h" +
                std::to_string(tag) + "]";
    }
    std::string out = std::to_string(rows.size()) + " row(s) (" + std::to_string(income) + " income, " +
                      std::to_string(library) + " library), " + std::to_string(tags.size()) +
                      " distinct handle(s) for " + std::to_string(paths.size()) + " distinct path(s)";
    if (!list.empty()) out += ": " + list;
    std::string items;
    for (const ActionEntry &e : menu.entries) {
        if (!items.empty()) items += " | ";
        items += e.title + (e.enabled ? " [enabled]" : " [disabled]");
    }
    out += "; menu: " + (items.empty() ? std::string("(no items)") : items);
    return out;
}

void next(std::shared_ptr<const std::vector<TestActionStep>> steps, size_t index) {
    dispatch_async(dispatch_get_main_queue(), ^{
        runStep(steps, index);
    });
}

// A sweep in progress (main thread only).
struct SweepRun {
    std::string label;
    t_size playlist = 0;
    t_size count = 0;
    std::vector<size_t> positions;
    size_t move = 0;  // the next move, an index into positions
    int delayMs = 0;
    std::chrono::steady_clock::time_point start;
};

void sweepAfterDelay(std::shared_ptr<SweepRun> run, std::shared_ptr<const std::vector<TestActionStep>> steps,
                     size_t index);

// One tick: stop when the playlist changed, end after the last move, else
// make the next move and schedule the next tick.
void sweepTick(std::shared_ptr<SweepRun> run, std::shared_ptr<const std::vector<TestActionStep>> steps,
               size_t index) {
    if (core_api::is_shutting_down()) return;
    if (run->move >= run->positions.size()) {
        const double seconds =
            std::chrono::duration<double>(std::chrono::steady_clock::now() - run->start).count();
        char done[48];
        snprintf(done, sizeof(done), "done in %.1f s", seconds);
        logInfo(run->label + done);
        next(steps, index + 1);
        return;
    }
    auto pm = playlist_manager::get();
    if (activePlaylistIndex() != run->playlist || pm->playlist_get_item_count(run->playlist) != run->count) {
        logInfo(run->label + "stopped at move " + std::to_string(run->move + 1) + " of " +
                std::to_string(run->positions.size()) + ": the playlist changed");
        next(steps, index + 1);
        return;
    }
    pm->playlist_set_focus_item(run->playlist, run->positions[run->move]);
    run->move++;
    sweepAfterDelay(run, steps, index);
}

void sweepAfterDelay(std::shared_ptr<SweepRun> run, std::shared_ptr<const std::vector<TestActionStep>> steps,
                     size_t index) {
    const int64_t delay = static_cast<int64_t>(run->delayMs) * static_cast<int64_t>(NSEC_PER_MSEC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
        sweepTick(run, steps, index);
    });
}

void runStep(std::shared_ptr<const std::vector<TestActionStep>> steps, size_t index) {
    if (core_api::is_shutting_down()) return;
    if (index >= steps->size()) {
        logInfo("test_actions: done");
        return;
    }
    const TestActionStep &step = (*steps)[index];
    const std::string label = "test_actions: " + step.text + ": ";

    switch (step.kind) {
        case TestStepKind::Invalid:
            logInfo(label + "ignored (" + step.error + ")");
            break;
        case TestStepKind::Wait: {
            logInfo(label + "waiting");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(step.seconds * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               runStep(steps, index + 1);
                           });
            return;
        }
        case TestStepKind::Badge: {
            const std::shared_ptr<const IntakeView> view = providerCurrentView();
            std::vector<const IntakeRecord *> roots;
            std::vector<std::string> paths;
            std::string error;
            if (!view) {
                logInfo(label + "skipped (no intake data yet)");
                break;
            }
            if (!rootsForIds(*view, step.ids, roots, error, &paths)) {
                logInfo(label + "skipped (" + error + ")");
                break;
            }
            auto db = metadb::get();
            metadb_handle_list members;
            for (size_t i = 0; i < paths.size() && i < kGroupMemberLimit; i++) {
                members.add_item(db->handle_create(("file://" + paths[i]).c_str(), 0));
            }
            jl_group_decoration deco;
            bool amber = false;
            if (providerDecorateGroup(members, deco, &amber)) {
                logInfo(label + badgeText(deco, amber));
            } else {
                logInfo(label + "no badge");
            }
            break;
        }
        case TestStepKind::Runs:
            logInfo(label + actionsRunsDescription());
            break;
        case TestStepKind::Rows:
        case TestStepKind::Show: {
            const std::shared_ptr<const IntakeView> view = providerCurrentView();
            if (!view) {
                logInfo(label + "skipped (no intake data yet)");
                break;
            }
            if (view->snapshot().recordForId(step.ids[0]) == nullptr) {
                logInfo(label + "skipped (not in the snapshot: " + step.ids[0] + ")");
                break;
            }
            const t_size playlist = activePlaylistIndex();
            if (playlist == SIZE_MAX) {
                logInfo(label + "skipped (no active playlist)");
                break;
            }
            const std::vector<PlaylistRootRow> rows = playlistRowsOfRoot(playlist, step.ids[0], *view);
            if (step.kind == TestStepKind::Rows) {
                metadb_handle_list handles;
                for (const PlaylistRootRow &r : rows) handles.add_item(r.handle);
                logInfo(label + rowsText(rows, actionsTableForHandles(handles)));
                break;
            }
            if (rows.empty()) {
                logInfo(label + "skipped (no row of " + step.ids[0] + " in the active playlist)");
                break;
            }
            // Rows come in playlist order. No selection, so its highlight does
            // not cover the tints; the focus moves last then first, because
            // SimPlaylist scrolls each focus change from outside into view.
            const t_size first = rows.front().index;
            const t_size last = rows.back().index;
            auto pm = playlist_manager::get();
            pm->playlist_clear_selection(playlist);
            pm->playlist_set_focus_item(playlist, last);
            pm->playlist_set_focus_item(playlist, first);
            pm->playlist_ensure_visible(playlist, first);
            logInfo(label + std::to_string(rows.size()) + " row(s), #" + std::to_string(first) + " to #" +
                    std::to_string(last) + "; selection cleared, focus on #" + std::to_string(first));
            break;
        }
        case TestStepKind::Tint: {
            const char *key = tintKey(step.tintSlot);
            std::string what;
            switch (step.tintValue) {
                case TestTintValue::Colour:
                    config::setInt(key, static_cast<int64_t>(step.tintRgba));
                    what = "written";
                    break;
                case TestTintValue::Off:
                    config::setInt(key, 0);
                    what = "wrote 0";
                    break;
                case TestTintValue::Default:
                    config::deleteInt(key);
                    what = "key deleted";
                    break;
            }
            // As the preferences page does after a write (main thread):
            // IntakeService::applySettings re-reads the keys and re-tints.
            [[NSNotificationCenter defaultCenter] postNotificationName:IntakeSettingsDidChangeNotification object:nil];
            logInfo(label + what + "; settings change posted");
            break;
        }
        case TestStepKind::Sweep: {
            const t_size playlist = activePlaylistIndex();
            if (playlist == SIZE_MAX) {
                logInfo(label + "skipped (no active playlist)");
                break;
            }
            auto pm = playlist_manager::get();
            const t_size count = pm->playlist_get_item_count(playlist);
            if (count == 0) {
                logInfo(label + "skipped (the active playlist is empty)");
                break;
            }
            auto run = std::make_shared<SweepRun>();
            run->label = label;
            run->playlist = playlist;
            run->count = count;
            run->positions = sweepPositions(count, static_cast<size_t>(step.sweepRows));
            run->delayMs = step.sweepDelayMs;
            pm->playlist_clear_selection(playlist);
            // Setting the focus to the index it already has does nothing, so
            // from a focus on row 0 the first move would not scroll the view
            // to the top.
            const bool premove = count > 1 && pm->playlist_get_focus_item(playlist) == 0;
            if (premove) pm->playlist_set_focus_item(playlist, 1);
            logInfo(label + std::to_string(run->positions.size()) + " moves over " + std::to_string(count) +
                    " rows, 0 to " + std::to_string(count - 1) + ", then back to 0");
            run->start = std::chrono::steady_clock::now();
            if (premove) {
                sweepAfterDelay(run, steps, index);  // row 1 first, then row 0
            } else {
                sweepTick(run, steps, index);
            }
            return;  // the ticks log the end and go on
        }
        case TestStepKind::Swap: {
            const std::shared_ptr<const IntakeView> view = providerCurrentView();
            std::vector<const IntakeRecord *> roots;
            std::string error;
            if (!view) {
                logInfo(label + "skipped (no intake data yet)");
                break;
            }
            if (!rootsForIds(*view, step.ids, roots, error)) {
                logInfo(label + "skipped (" + error + ")");
                break;
            }
            const t_size playlist = activePlaylistIndex();
            if (playlist == SIZE_MAX) {
                logInfo(label + "skipped (no active playlist)");
                break;
            }
            std::unordered_set<std::string> ids(step.ids.begin(), step.ids.end());
            NativePathMenuBudget budget;
            std::vector<t_size> indices;
            const std::vector<SwapRow> rows = swapIncomeRows(playlist, ids, *view, &budget, &indices);
            if (indices.empty()) {
                logInfo(label + "skipped (no row of " + joinIds(step.ids) +
                        " in the active playlist points at an income path)");
                break;
            }
            // Select exactly those rows, as a user would before the click.
            auto pm = playlist_manager::get();
            pfc::bit_array_bittable mask(pm->playlist_get_item_count(playlist));
            for (t_size i : indices) mask.set(i, true);
            pm->playlist_set_selection(playlist, pfc::bit_array_true(), mask);
            metadb_handle_list handles;
            pm->playlist_get_selected_items(playlist, handles);
            const ActionTable table = actionsTableForHandles(handles);
            const ActionEntry *entry = findEntry(table, IntakeAction::Swap);
            if (entry == nullptr) {
                logInfo(label + "no swap item in the menu (" + menuText(table) + ")");
                break;
            }
            auto hooks = std::make_shared<SwapTestHooks>();
            hooks->report = reportOnce(label + entry->title + " (" + joinIds(step.ids) + "): selected " +
                                       std::to_string(indices.size()) + " row(s); ");
            hooks->done = [steps, index]() { next(steps, index + 1); };
            actionsSwap(*entry, handles, hooks);
            return;  // the hooks log the line and go on
        }
        case TestStepKind::Delete:
        case TestStepKind::DeleteSwap:
        case TestStepKind::DeleteSheet: {
            const std::shared_ptr<const IntakeView> view = providerCurrentView();
            std::vector<const IntakeRecord *> roots;
            std::string error;
            if (!view) {
                logInfo(label + "skipped (no intake data yet)");
                break;
            }
            if (!rootsForIds(*view, step.ids, roots, error)) {
                logInfo(label + "skipped (" + error + ")");
                break;
            }
            const ActionTable table = actionsTableFor(roots, view.get());
            const ActionEntry *entry = findEntry(table, IntakeAction::DeleteLocal);
            if (entry == nullptr) {
                logInfo(label + "no delete-local item in the menu (" + menuText(table) + ")");
                break;
            }
            auto hooks = std::make_shared<DeleteTestHooks>();
            hooks->mode = step.kind == TestStepKind::Delete       ? DeleteTestHooks::Mode::Delete
                          : step.kind == TestStepKind::DeleteSwap ? DeleteTestHooks::Mode::SwapThenDelete
                                                                  : DeleteTestHooks::Mode::AutoClose;
            hooks->closeSeconds = step.closeSeconds;
            hooks->report = reportOnce(label + entry->title + " (" + joinIds(step.ids) + "): ");
            hooks->done = [steps, index]() { next(steps, index + 1); };
            actionsDeleteLocal(*entry, hooks);
            return;  // the hooks log the line and go on
        }
        case TestStepKind::Execute:
        case TestStepKind::ExecuteSheet:
        case TestStepKind::Resume: {
            const std::shared_ptr<const IntakeView> view = providerCurrentView();
            std::vector<const IntakeRecord *> roots;
            std::string error;
            if (!view) {
                logInfo(label + "skipped (no intake data yet)");
                break;
            }
            if (!rootsForIds(*view, step.ids, roots, error)) {
                logInfo(label + "skipped (" + error + ")");
                break;
            }
            const ActionTable table = actionsTableFor(roots, view.get());
            const ActionEntry *entry = findEntry(table, step.action);
            if (entry == nullptr) {
                logInfo(label + "no " + actionName(step.action) + " item in the menu (" + menuText(table) + ")");
                break;
            }
            auto hooks = std::make_shared<ExecuteTestHooks>();
            hooks->mode = step.kind == TestStepKind::ExecuteSheet ? ExecuteTestHooks::Mode::AutoClose
                                                                  : ExecuteTestHooks::Mode::Headless;
            hooks->closeSeconds = step.closeSeconds;
            const std::string prefix = label + entry->title + " (" + joinIds(step.ids) + "): ";
            hooks->report = [prefix](const std::string &line) { logInfo(prefix + line); };
            hooks->done = [steps, index]() { next(steps, index + 1); };
            if (step.kind == TestStepKind::Resume) {
                actionsResume(*entry, hooks);
            } else {
                actionsExecutePlacement(*entry, hooks);
            }
            return;  // the hooks log the line and go on
        }
        case TestStepKind::AssignOther:
        case TestStepKind::Picker: {
            const std::shared_ptr<const IntakeView> view = providerCurrentView();
            std::vector<const IntakeRecord *> roots;
            std::string error;
            if (!view) {
                logInfo(label + "skipped (no intake data yet)");
                break;
            }
            if (!rootsForIds(*view, step.ids, roots, error)) {
                logInfo(label + "skipped (" + error + ")");
                break;
            }
            const ActionTable table = actionsTableFor(roots, view.get());
            const ActionEntry *entry = findEntry(table, IntakeAction::AssignOther);
            if (entry == nullptr) {
                logInfo(label + "no assign-other item in the menu (" + menuText(table) + ")");
                break;
            }
            auto hooks = std::make_shared<PickerTestHooks>();
            hooks->mode = step.kind == TestStepKind::AssignOther ? PickerTestHooks::Mode::Headless
                                                                 : PickerTestHooks::Mode::AutoClose;
            hooks->collection = step.collection;
            hooks->closeSeconds = step.closeSeconds;
            const std::string prefix = label + entry->title + " (" + joinIds(step.ids) + "): ";
            hooks->report = [prefix](const std::string &line) { logInfo(prefix + line); };
            hooks->done = [steps, index]() { next(steps, index + 1); };
            actionsAssignOther(*entry, hooks);
            return;  // the hooks log the line and go on
        }
        case TestStepKind::Menu:
        case TestStepKind::Dispatch: {
            const std::shared_ptr<const IntakeView> view = providerCurrentView();
            std::vector<const IntakeRecord *> roots;
            std::string error;
            if (!view) {
                logInfo(label + "skipped (no intake data yet)");
                break;
            }
            if (!rootsForIds(*view, step.ids, roots, error)) {
                logInfo(label + "skipped (" + error + ")");
                break;
            }
            const ActionTable table = actionsTableFor(roots, view.get());
            if (step.kind == TestStepKind::Menu) {
                logInfo(label + menuText(table));
                break;
            }
            const ActionEntry *entry = nullptr;
            if (step.action == IntakeAction::AssignTo) {
                // The quick-assign entry for that collection (exact name).
                for (const ActionEntry &e : table.entries) {
                    if (e.action == IntakeAction::AssignTo && e.collection == step.collection) {
                        entry = &e;
                        break;
                    }
                }
                if (entry == nullptr) {
                    logInfo(label + "no \"" + actionBaseTitle(IntakeAction::AssignTo, step.collection) +
                            "\" item in the menu (" + menuText(table) + ")");
                    break;
                }
            } else {
                entry = findEntry(table, step.action);
            }
            if (entry == nullptr) {
                logInfo(label + "no " + actionName(step.action) + " item in the menu (" + menuText(table) + ")");
                break;
            }
            const std::string what = actionsDispatch(*entry, true, step.reason);
            logInfo(label + entry->title + " (" + joinIds(step.ids) + "): " + what);
            break;
        }
    }
    next(steps, index + 1);
}

void runTestActions() {
    if (core_api::is_shutting_down()) return;
    const std::string script = trimmedSetting(config::getString(kKey, ""));
    if (script.empty()) return;
    config::setString(kKey, "");
    auto steps = std::make_shared<const std::vector<TestActionStep>>(parseTestActions(script));
    logInfo("test_actions: " + std::to_string(steps->size()) + " step(s), key reset");
    runStep(steps, 0);
}

} // anonymous namespace

void testActionsAfterLoad() {
    if (g_ran || core_api::is_shutting_down()) return;
    g_ran = true;
    // B8: after the leftover-run scan, so `runs` and the lane see adopted runs.
    actionsAfterRunScan([] { runTestActions(); });
}

} // namespace intake
