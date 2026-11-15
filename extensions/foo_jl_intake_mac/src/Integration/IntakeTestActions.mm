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
//    propose|approve|reject <id...> builds that table and dispatches the
//                                   item for the action through the same
//                                   path and lane as a click; dialogs are
//                                   skipped and reject uses reason=<text>
//    refresh                        the Refresh item
//    wait <seconds>                 at most 30
//  Every step logs one line starting "test_actions:" (Info, so log_level 0
//  hides them; log_file mirrors them). Ids that are not in the snapshot
//  make the step log and do nothing. Nothing runs after quit starts.
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

#include <memory>
#include <string>
#include <vector>

namespace intake {

namespace {

const char *const kKey = "test_actions";  // under foo_jl_intake.

bool g_ran = false;  // main thread

std::string joinIds(const std::vector<std::string> &ids) {
    std::string out;
    for (const std::string &id : ids) out += (out.empty() ? "" : " ") + id;
    return out.empty() ? std::string("(none)") : out;
}

// The rows of those roots, through the view's lookup (see the top of this
// file). False with `error` when an id is not in the snapshot.
bool rootsForIds(const IntakeView &view, const std::vector<std::string> &ids,
                 std::vector<const IntakeRecord *> &roots, std::string &error) {
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
    }
    roots = selectionRoots(rows);
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
            const ActionEntry *entry = findEntry(table, step.action);
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

} // anonymous namespace

void testActionsAfterLoad() {
    if (g_ran || core_api::is_shutting_down()) return;
    g_ran = true;
    const std::string script = trimmedSetting(config::getString(kKey, ""));
    if (script.empty()) return;
    config::setString(kKey, "");
    auto steps = std::make_shared<const std::vector<TestActionStep>>(parseTestActions(script));
    logInfo("test_actions: " + std::to_string(steps->size()) + " step(s), key reset");
    runStep(steps, 0);
}

} // namespace intake
