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
//                                   " (amber)" for the amber colour; or
//                                   "no badge"
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
//    wait <seconds>                 at most 30
//  Every step logs one line starting "test_actions:" (Info, so log_level 0
//  hides them; log_file mirrors them). Ids that are not in the snapshot,
//  or whose rows map to other roots than the ones named, make the step log
//  and do nothing. Nothing runs after quit starts. assign-other, picker,
//  execute, execute-sheet and resume wait for their flow to end (a run: to
//  be spawned) before the next step. The steps start after the first
//  successful load and the leftover-run scan.
//
//  Temporary: removed with the other acceptance aids (and
//  Core/IntakeTestActionScript plus its tests) before the merge to main.
//

#import "../fb2k_sdk.h"

#include "IntakeActions.h"
#include "IntakeConfig.h"
#include "IntakeDecoratorProvider.h"

#include "../Core/IntakeLog.h"
#include "../Core/IntakeSettingsParse.h"
#include "../Core/IntakeTestActionScript.h"
#include "../Core/IntakeView.h"

#include <algorithm>
#include <cstdio>
#include <memory>
#include <string>
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
// colour is IntakeGroupBadge's amber (the review tint at full alpha; the
// snapshot is built with the default palette, LoaderSettings::palette).
std::string badgeText(const jl_group_decoration &deco) {
    char color[16];
    snprintf(color, sizeof(color), "#%08X", static_cast<unsigned>(deco.badge_color));
    std::string out = "\"" + std::string(deco.badge_text.c_str()) + "\" color " + color;
    const IntakeRgba amber = opaqueColor(IntakePalette().tintReview);
    if (amber != 0 && deco.badge_color == amber) out += " (amber)";
    return out;
}

void runStep(std::shared_ptr<const std::vector<TestActionStep>> steps, size_t index);

void next(std::shared_ptr<const std::vector<TestActionStep>> steps, size_t index) {
    dispatch_async(dispatch_get_main_queue(), ^{
        runStep(steps, index);
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
            if (providerDecorateGroup(members, deco)) {
                logInfo(label + badgeText(deco));
            } else {
                logInfo(label + "no badge");
            }
            break;
        }
        case TestStepKind::Runs:
            logInfo(label + actionsRunsDescription());
            break;
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
