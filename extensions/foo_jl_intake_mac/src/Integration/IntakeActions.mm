//
//  IntakeActions.mm
//  foo_jl_intake
//
//  See IntakeActions.h. Threading: everything in ActionsState marked "main"
//  is touched on the main thread only; the private queue only builds and
//  starts CLI calls and hands every result back to main with dispatch_async.
//

#import "../fb2k_sdk.h"

#import <AppKit/AppKit.h>

#include "IntakeActions.h"

#include "IntakeDecoratorProvider.h"
#include "IntakeNativePath.h"
#include "IntakeService.h"

#include "../Core/IntakeCliRunner.h"
#include "../Core/IntakeErrorMap.h"
#include "../Core/IntakeLog.h"
#include "../Core/IntakeMutationLane.h"
#include "../Core/IntakeMutationResult.h"
#include "../Core/IntakeSlowVolumeGuard.h"
#include "../Core/IntakeView.h"

#include <memory>
#include <unordered_map>

namespace intake {

namespace {

NSString *NSStr(const std::string &s) {
    NSString *out = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

std::string StdStr(NSString *s) {
    const char *c = s.UTF8String;
    return c ? std::string(c) : std::string();
}

std::string rootCountText(size_t n) {
    return std::to_string(n) + (n == 1 ? " root" : " roots");
}

std::string idList(const std::vector<std::string> &ids) {
    std::string out;
    for (const std::string &id : ids) out += (out.empty() ? "" : " ") + id;
    return out;
}

// Leaked on purpose (like the provider's state): a CLI completion may come
// back after on_quit, and static destructors run at exit.
struct ActionsState {
    ActionsState() {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        attr = dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_USER_INITIATED, 0);
        queue = dispatch_queue_create("com.foobar2000.intake.mutation", attr);
        outputDirectory = defaultCliOutputDirectory();
    }

    // main
    MutationLane lane;
    bool stopped = false;
    uint32_t menuSerial = 0;
    ActionTable menuTable;
    // The call whose 10 s report put E_CLI_TIMEOUT on its roots (0: none);
    // its finish replaces those errors.
    uint64_t timeoutReported = 0;

    // Set once above, then read on the queue.
    dispatch_queue_t queue = nil;
    std::string outputDirectory;
    // Mutating calls only. Never cancelled: destroying or keeping it never
    // signals a process (IntakeProcess), so calls outlive on_quit.
    ProcessRunner runner;
};

ActionsState &actionsState() {
    static ActionsState *state = new ActionsState();
    return *state;
}

ActionContext liveContext(const IntakeView *view) {
    const ServiceActionInfo info = serviceActionInfo();
    ActionsState &st = actionsState();
    ActionContext c;
    c.cliConfigured = info.running && info.cliConfigured && !st.stopped;
    c.inert = view != nullptr && view->isInert();
    c.cli = info.cli;
    c.laneBusy = st.lane.busy();
    c.executeRunning = st.lane.executeRunning();
    c.confirmReject = info.confirmReject;
    return c;
}

// Why a mutating call cannot start now, or "" (main thread; the lane and
// the configuration, as runMutation checks them).
std::string whyNotStartable() {
    ActionsState &st = actionsState();
    if (st.stopped) return "intake is not running";
    const ServiceActionInfo info = serviceActionInfo();
    if (!info.running || !info.cliConfigured) return "intake is not running or has no CLI path";
    if (st.lane.busy()) {
        return st.lane.executeRunning() ? "another intake command is still running (execute)"
                                        : "another intake command is still running";
    }
    return std::string();
}

// --- results (main) ---

void onBudget(uint64_t token, CliCommand command, const std::vector<MutationRoot> &roots, CliBudgetEvent event) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    const std::string name = cliCommandName(command);
    if (st.lane.reportBudget(token)) {
        logInfo(name + " dry run: no answer within 10 s; the lane is free again and its late result will be ignored");
    } else if (event == CliBudgetEvent::Timeout) {
        // doc 03 v1.2 "Timeouts": report E_CLI_TIMEOUT, keep it running.
        // Per command (doc 04 "Failure behavior"): a console line and a
        // tooltip on each of its roots until it exits; the refresh shows
        // the tooltips (status as of now, the call's writes so far).
        CliError timeout;
        timeout.code = "E_CLI_TIMEOUT";
        timeout.msg = "still running after 10 s; it is not stopped, and intake refreshes when it exits";
        const std::string text = name + ": " + renderError(timeout);
        RootErrorStore &errors = actionsErrorStore();
        for (const MutationRoot &r : roots) errors.set(r.id, text, r.status);
        st.timeoutReported = token;
        logError(text + " (" + rootCountText(roots.size()) + ")");
        serviceRefreshAfterCommand();
    }
}

void onFinished(uint64_t token, CliCommand command, const std::vector<MutationRoot> &roots, const CliResult &result) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    const std::string name = cliCommandName(command);
    logCliResult(result);
    if (!st.lane.finish(token)) {
        logInfo(name + ": a late dry-run result was ignored");
        return;
    }
    const MutationOutcome outcome = summarizeMutation(command, roots, result.envelope);
    RootErrorStore &errors = actionsErrorStore();
    if (st.timeoutReported == token) {
        // The 10 s report's E_CLI_TIMEOUT (which replaced any older error
        // of these roots) gives way to the result.
        st.timeoutReported = 0;
        for (const MutationRoot &r : roots) errors.clear(r.id);
    }
    std::unordered_map<std::string, IntakeStatus> menuStatus;
    for (const MutationRoot &r : roots) menuStatus.emplace(r.id, r.status);
    for (const std::string &id : outcome.succeeded) errors.clear(id);
    for (const auto &entry : outcome.rootErrors) {
        // Baseline: the status the menu showed, so a root the CLI changed
        // anyway, or one already past it (a stale menu), drops it at the
        // next load (IntakeRootErrors.h).
        auto status = menuStatus.find(entry.first);
        errors.set(entry.first, entry.second, status == menuStatus.end() ? IntakeStatus::Unknown : status->second);
        logDebug("tooltip " + entry.first + " until its status changes: " + entry.second);
    }
    if (outcome.isError) {
        logError(outcome.consoleLine);
    } else {
        logInfo(outcome.consoleLine);
    }
    serviceRefreshAfterCommand();
}

void onRefused(uint64_t token, CliCommand command, const std::string &refusal) {
    ActionsState &st = actionsState();
    st.lane.finish(token);
    if (st.stopped) return;
    // The only console line for it (IntakeCliRunner logs it at Debug);
    // a caller bug, not a root's error, so no tooltip.
    logError(std::string(cliCommandName(command)) + ": not started (" + refusal + ")");
}

// --- start (queue) ---

void startOnQueue(uint64_t token, std::shared_ptr<const CliConfig> config, std::shared_ptr<const CliRequest> request,
                  std::shared_ptr<const std::vector<MutationRoot>> roots) {
    ActionsState &st = actionsState();
    CliRunOptions options;
    options.outputDirectory = st.outputDirectory;
    const CliCommand command = request->command;
    std::string refusal;
    const bool started = startCliCommand(
        st.runner, *config, *request, options, st.queue,
        [token, command, roots](CliBudgetEvent event) {
            dispatch_async(dispatch_get_main_queue(), ^{
                onBudget(token, command, *roots, event);
            });
        },
        [token, command, roots](CliResult &&result) {
            auto shared = std::make_shared<CliResult>(std::move(result));
            dispatch_async(dispatch_get_main_queue(), ^{
                onFinished(token, command, *roots, *shared);
            });
        },
        &refusal);
    if (!started) {
        dispatch_async(dispatch_get_main_queue(), ^{
            onRefused(token, command, refusal);
        });
    }
}

// --- dispatch (main) ---

// A click (or a confirmed Reject) that runs nothing gets one Error line:
// at the default log levels the user would otherwise see nothing happen.
std::string notRun(IntakeAction action, const std::string &why) {
    logError(std::string(actionName(action)) + ": not run: " + why);
    return "not run: " + why;
}

std::string runMutation(const ActionEntry &entry, const std::string &reason) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    CliRequest request;
    std::string why;
    if (!requestForEntry(entry, reason, request, &why)) return notRun(entry.action, why);
    CliConfig config;
    if (!serviceMutationConfig(config)) return notRun(entry.action, "intake is not running or has no CLI path");
    const std::string name = cliCommandName(request.command);
    const uint64_t token = st.lane.acquire(laneHolderFor(request));
    if (token == 0) {
        return notRun(entry.action, st.lane.executeRunning() ? "another intake command is still running (execute)"
                                                             : "another intake command is still running");
    }
    auto roots = std::make_shared<std::vector<MutationRoot>>();
    for (const ActionRoot &r : entry.roots) roots->push_back({r.id, r.rootPath, r.status});
    logInfo(name + ": starting for " + rootCountText(request.ids.size()) + ": " + idList(request.ids) +
            (request.reason.empty() ? std::string() : " (with a reason)"));
    auto sharedConfig = std::make_shared<const CliConfig>(std::move(config));
    auto sharedRequest = std::make_shared<const CliRequest>(request);
    std::shared_ptr<const std::vector<MutationRoot>> sharedRoots = roots;
    dispatch_async(st.queue, ^{
        startOnQueue(token, sharedConfig, sharedRequest, sharedRoots);
    });
    return "started for " + rootCountText(request.ids.size());
}

// The window for the confirmation sheet: the one under the pointer (the
// menu was opened there, and right-clicking a window that is not key does
// not make it key), else the main window, else the key window; nil when
// none can take a sheet now (the alert then runs app-modal).
NSWindow *sheetHostWindow() {
    auto usable = [](NSWindow *w) {
        return w != nil && w.visible && !w.miniaturized && !w.sheet && w.attachedSheet == nil &&
               w.canBecomeKeyWindow;
    };
    const NSInteger number = [NSWindow windowNumberAtPoint:NSEvent.mouseLocation belowWindowWithWindowNumber:0];
    NSWindow *under = number > 0 ? [NSApp windowWithWindowNumber:number] : nil;  // nil: another app's
    if (usable(under)) return under;
    if (usable(NSApp.mainWindow)) return NSApp.mainWindow;
    if (usable(NSApp.keyWindow)) return NSApp.keyWindow;
    return nil;
}

// Reject…: the confirmation (doc 04 v1.2, confirm_reject).
void confirmReject(const ActionEntry &entry) {
    const size_t n = entry.roots.size();
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = n == 1 ? @"Reject this album?" : [NSString stringWithFormat:@"Reject %zu albums?", n];
    alert.informativeText = [NSString
        stringWithFormat:@"%@\n\nReject only changes the intake state. No files are deleted.",
                         NSStr(affectedAlbumsText(entry.roots))];
    [alert addButtonWithTitle:@"Reject"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *reasonField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 22)];
    reasonField.placeholderString = @"Reason (optional)";
    reasonField.accessibilityLabel = @"Reason for rejecting";
    reasonField.usesSingleLineMode = YES;
    alert.accessoryView = reasonField;
    [alert layout];
    alert.window.initialFirstResponder = reasonField;

    const ActionEntry captured = entry;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            logDebug("reject: cancelled in the confirmation");
            return;
        }
        NSString *text = [reasonField.stringValue
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // runMutation logs an Error line when it cannot start (the lane or
        // the CLI path changed while the alert was open).
        const std::string what = runMutation(captured, StdStr(text));
        logDebug("reject: " + what);
    };
    if (NSWindow *host = sheetHostWindow()) {
        [alert beginSheetModalForWindow:host completionHandler:finish];
    } else {
        finish([alert runModal]);
    }
}

} // anonymous namespace

RootErrorStore &actionsErrorStore() {
    static RootErrorStore *store = new RootErrorStore();  // leaked: read by the loader queue
    return *store;
}

bool actionsLaneBusy() {
    return actionsState().lane.busy();
}

ActionTable actionsTableFor(const std::vector<const IntakeRecord *> &roots, const IntakeView *view) {
    return buildActionTable(roots, liveContext(view), b6Actions());
}

void actionsBuildMenu(metadb_handle_list_cref sel, pfc::list_t<jl_context_action> &out) {
    out.remove_all();
    ActionsState &st = actionsState();
    st.menuTable = ActionTable();
    if (st.stopped) return;

    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    std::vector<const IntakeRecord *> rows;
    // Main thread: at most one slow mac-volume conversion per menu
    // (IntakeSlowVolumeGuard.h, NativePathMenuBudget).
    NativePathMenuBudget budget;
    if (view && !view->rendersNothing()) {
        const t_size count = sel.get_count();
        rows.reserve(count);
        pfc::string8 native;
        ViewScratch scratch;
        for (t_size i = 0; i < count; i++) {
            @autoreleasepool {
                const metadb_handle_ptr handle = sel[i];
                const char *path =
                    handle.is_valid() ? intakeNativePath(handle->get_path(), native, &budget) : nullptr;
                rows.push_back(path != nullptr ? view->recordFor(path, scratch) : nullptr);
            }
        }
    }
    if (budget.spent()) {
        logInfo("menu: a mac-volume path conversion took over " + std::to_string(kSlowNativePathMicros / 1000) +
                " ms; " + std::to_string(budget.skipped()) +
                " row(s) on volumes not yet converted in this menu were left out");
    }
    const std::vector<const IntakeRecord *> roots = selectionRoots(rows);
    st.menuTable = actionsTableFor(roots, view.get());
    st.menuSerial = nextMenuSerial(st.menuSerial);
    for (size_t i = 0; i < st.menuTable.entries.size(); i++) {
        const ActionEntry &e = st.menuTable.entries[i];
        jl_context_action action;
        action.title.set_string(e.title.data(), e.title.size());
        action.action_id = encodeActionId(st.menuSerial, i);
        action.enabled = e.enabled;
        out.add_item(action);
    }
    if (isLogEnabled(LogLevel::Debug)) {
        logDebug("menu: " + std::to_string(st.menuTable.entries.size()) + " item(s) for " +
                 rootCountText(roots.size()) + " in " + std::to_string(sel.get_count()) + " row(s)");
    }
}

void actionsExecute(uint32_t actionId) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    uint32_t serial = 0;
    size_t index = 0;
    if (!decodeActionId(actionId, serial, index) || serial != st.menuSerial || index >= st.menuTable.entries.size()) {
        logInfo("context action " + std::to_string(actionId) + " ignored: not from the latest intake menu");
        return;
    }
    // A copy: the table may be replaced while a confirmation is open.
    const ActionEntry entry = st.menuTable.entries[index];
    const std::string what = actionsDispatch(entry, false, std::string());
    logDebug("menu: " + entry.title + ": " + what);
}

std::string actionsDispatch(const ActionEntry &entry, bool skipDialog, const std::string &reason) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    if (entry.action == IntakeAction::Refresh) {
        logInfo("refresh requested");
        serviceReload(true);
        return "refresh requested";
    }
    if (!entry.enabled) return "not run: the item is disabled";
    if (entry.roots.empty()) return "not run: no qualifying root";
    if (entry.action == IntakeAction::Reject) {
        if (!skipDialog && serviceActionInfo().confirmReject) {
            // No confirmation for a call that could not start anyway.
            const std::string why = whyNotStartable();
            if (!why.empty()) return notRun(entry.action, why);
            confirmReject(entry);
            return "asking for confirmation";
        }
        // confirm_reject 0: no dialog, no reason; the test aid passes one.
        return runMutation(entry, skipDialog ? reason : std::string());
    }
    return runMutation(entry, std::string());
}

void actionsShutdown() {
    ActionsState &st = actionsState();
    st.stopped = true;
    st.menuTable = ActionTable();
}

} // namespace intake
