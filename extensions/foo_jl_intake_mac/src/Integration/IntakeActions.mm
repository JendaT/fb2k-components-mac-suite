//
//  IntakeActions.mm
//  foo_jl_intake
//
//  See IntakeActions.h. Threading: everything in ActionsState marked "main"
//  is touched on the main thread only; the private queue only builds and
//  starts CLI calls (and parses a `collections` reply) and hands every
//  result back to main with dispatch_async.
//

#import "../fb2k_sdk.h"

#import <AppKit/AppKit.h>

#include "IntakeActions.h"

#include "IntakeDecoratorProvider.h"
#include "IntakeNativePath.h"
#include "IntakeService.h"
#include "IntakeSwap.h"

#include "../Core/IntakeActionTable.h"
#include "../Core/IntakeCliRunner.h"
#include "../Core/IntakeCollections.h"
#include "../Core/IntakeErrorMap.h"
#include "../Core/IntakeExecutePlan.h"
#include "../Core/IntakeExecuteTracker.h"
#include "../Core/IntakeGcPlan.h"
#include "../Core/IntakeLog.h"
#include "../Core/IntakeMutationLane.h"
#include "../Core/IntakeMutationResult.h"
#include "../Core/IntakeSlowVolumeGuard.h"
#include "../Core/IntakeView.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <memory>
#include <unordered_map>
#include <unordered_set>

// The picker's combo box delegate (B7): "Assign" is enabled only while the
// text stands for one of the listed names (IntakeCollections
// listedCollectionFor). ObjC classes share one namespace in the process,
// hence the component prefix.
@interface JLIntakeCollectionPicker : NSObject <NSComboBoxDelegate>
@property(nonatomic, weak) NSComboBox *combo;
@property(nonatomic, weak) NSButton *okButton;
- (instancetype)initWithNames:(const std::vector<std::string> &)names;
- (BOOL)isListed:(NSString *)text;
- (void)update;
@end

@implementation JLIntakeCollectionPicker {
    std::vector<std::string> _names;
}

- (instancetype)initWithNames:(const std::vector<std::string> &)names {
    if ((self = [super init])) _names = names;
    return self;
}

- (BOOL)isListed:(NSString *)text {
    const char *bytes = text.UTF8String;
    return bytes != nullptr && intake::listedCollectionFor(_names, std::string(bytes)) != nullptr;
}

- (void)update {
    self.okButton.enabled = [self isListed:self.combo.stringValue];
}

// Again on the next main-queue turn: the text may still change after the
// notification (the type-ahead completion, a pick from the list).
- (void)updateSoon {
    __weak JLIntakeCollectionPicker *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf update];
    });
}

// Typing (the type-ahead completion is part of the value).
- (void)controlTextDidChange:(NSNotification *)notification {
    [self update];
    [self updateSoon];
}

// A pick from the list. stringValue still holds the old text when this
// arrives, so the selected item decides now and the text once it is set.
- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    id selected = self.combo.objectValueOfSelectedItem;
    if ([selected isKindOfClass:[NSString class]]) self.okButton.enabled = [self isListed:selected];
    [self updateSoon];
}

@end

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

struct PickerFlow;
struct ExecuteFlow;
struct DeleteFlow;

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
    // The picker flow in progress (`collections` running or the sheet
    // open), or null: at most one (B7).
    std::shared_ptr<PickerFlow> picker;
    uint64_t pickerSerial = 0;
    // B8: the Execute placement… flow in progress (dry run running or sheet
    // open), or null: at most one.
    std::shared_ptr<ExecuteFlow> executeFlow;
    uint64_t executeSerial = 0;
    // B8: the detached runs (own and adopted) and the lane token they hold
    // together (0: none); taken with the first run, released with the last.
    ExecuteTracker tracker;
    uint64_t runLaneToken = 0;
    std::unordered_map<std::string, std::shared_ptr<ProcessExitWatch>> exitWatches;  // adopted runs, by stem
    // B9: the Delete local copy… flow in progress (sidecars being read, the
    // sheet open, or its swap running), or null: at most one.
    std::shared_ptr<DeleteFlow> deleteFlow;
    uint64_t deleteSerial = 0;
    // B8: the leftover-run scan (actionsStartRunScan). No mutating call
    // starts before it is done.
    bool runScanStarted = false;
    bool runScanDone = false;

    // Set once above, then read on the queue.
    dispatch_queue_t queue = nil;
    std::string outputDirectory;
    // Mutating calls and detached runs. Never cancelled: destroying or
    // keeping it never signals a process (IntakeProcess), so calls outlive
    // on_quit.
    ProcessRunner runner;
    // The picker's read-only `collections` calls: killed at the 10 s budget
    // (KillAtBudget), and its read lane is closed on quit.
    ProcessRunner pickerRunner;
};

// One "Assign to other collection…" flow (main thread).
struct PickerFlow {
    uint64_t serial = 0;
    ActionEntry entry;  // as the menu captured it
    // The sheet's window, chosen at the click (sheetHostWindow): the sheet
    // comes up to 10 s later, when the pointer may be elsewhere.
    __weak NSWindow *hostWindow = nil;
    std::vector<std::string> names;  // the listed collections, once known
    // While the sheet is up (released on the next main-queue turn after it
    // ends, never inside its own completion handler).
    NSAlert *alert = nil;
    JLIntakeCollectionPicker *helper = nil;
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
    // Until the leftover-run scan is done nothing mutating may start (a
    // live run found there takes the lane).
    c.laneBusy = st.lane.busy() || !st.runScanDone;
    c.executeRunning = st.lane.executeRunning();
    c.liveRunIds = st.tracker.liveRunIds();
    c.confirmReject = info.confirmReject;
    c.confirmGc = info.confirmGc;
    return c;
}

// Why a mutating call cannot start now, or "" (main thread; the lane and
// the configuration, as runMutation checks them).
std::string whyNotStartable() {
    ActionsState &st = actionsState();
    if (st.stopped) return "intake is not running";
    const ServiceActionInfo info = serviceActionInfo();
    if (!info.running || !info.cliConfigured) return "intake is not running or has no CLI path";
    if (!st.runScanDone) return "intake is still checking for an execute run left by an earlier session";
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
    if (!st.runScanDone) {
        return notRun(entry.action, "intake is still checking for an execute run left by an earlier session");
    }
    const std::string name = cliCommandName(request.command);
    const uint64_t token = st.lane.acquire(laneHolderFor(request));
    if (token == 0) {
        return notRun(entry.action, st.lane.executeRunning() ? "another intake command is still running (execute)"
                                                             : "another intake command is still running");
    }
    auto roots = std::make_shared<std::vector<MutationRoot>>();
    const bool gc = request.command == CliCommand::Gc;
    for (const ActionRoot &r : entry.roots) {
        // Only the roots the request names (gc: the guard may have left
        // some out). gc's E_VERIFY names placed.target_path: rule 1c.
        if (std::find(request.ids.begin(), request.ids.end(), r.id) == request.ids.end()) continue;
        if (std::find_if(roots->begin(), roots->end(), [&r](const MutationRoot &m) { return m.id == r.id; }) !=
            roots->end()) {
            continue;
        }
        const std::string &target = gc && !r.placedTargetPath.empty() ? r.placedTargetPath : r.targetPath;
        roots->push_back({r.id, r.rootPath, r.status, target});
    }
    logInfo(name + ": starting for " + rootCountText(request.ids.size()) + ": " + idList(request.ids) +
            (request.collection.empty() ? std::string() : " to \"" + request.collection + "\"") +
            (request.reason.empty() ? std::string() : " (with a reason)"));
    auto sharedConfig = std::make_shared<const CliConfig>(std::move(config));
    auto sharedRequest = std::make_shared<const CliRequest>(request);
    std::shared_ptr<const std::vector<MutationRoot>> sharedRoots = roots;
    dispatch_async(st.queue, ^{
        startOnQueue(token, sharedConfig, sharedRequest, sharedRoots);
    });
    return "started for " + rootCountText(request.ids.size());
}

bool usableSheetHost(NSWindow *w) {
    return w != nil && w.visible && !w.miniaturized && !w.sheet && w.attachedSheet == nil && w.canBecomeKeyWindow;
}

// foobar2000's own main window. The SDK hands it out as a bridged object
// that may be the window, a view or a view controller.
NSWindow *foobarMainWindow() {
    id object = (__bridge id)core_api::get_main_window();
    if ([object isKindOfClass:[NSWindow class]]) return (NSWindow *)object;
    if ([object isKindOfClass:[NSView class]]) return ((NSView *)object).window;
    if ([object isKindOfClass:[NSViewController class]]) {
        NSViewController *controller = (NSViewController *)object;
        return controller.isViewLoaded ? controller.view.window : nil;
    }
    return nil;
}

// The main window, else the key window, else foobar2000's main window, when
// one can take a sheet now. The last one covers an app that is running but
// was never activated (started with `open -g`): it has no main or key window.
NSWindow *activeSheetHost() {
    if (usableSheetHost(NSApp.mainWindow)) return NSApp.mainWindow;
    if (usableSheetHost(NSApp.keyWindow)) return NSApp.keyWindow;
    NSWindow *foobar = foobarMainWindow();
    if (usableSheetHost(foobar)) return foobar;
    return nil;
}

// The window for a sheet, called at the click: the one under the pointer
// (the menu was opened there, and right-clicking a window that is not key
// does not make it key), else activeSheetHost(); nil when none can take a
// sheet now (the alert then runs app-modal, for example while foobar2000's
// window is minimized).
NSWindow *sheetHostWindow() {
    const NSInteger number = [NSWindow windowNumberAtPoint:NSEvent.mouseLocation belowWindowWithWindowNumber:0];
    NSWindow *under = number > 0 ? [NSApp windowWithWindowNumber:number] : nil;  // nil: another app's
    if (usableSheetHost(under)) return under;
    return activeSheetHost();
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

// --- Assign to other collection… (B7, main unless noted) ---

// Ends the flow `flow` if it is still the current one. Its alert and helper
// are released on a later main-queue turn, never inside the alert's own
// completion handler. By value: callers pass st.picker itself, which the
// reset below empties, and the flow must outlive this call.
void endPicker(std::shared_ptr<PickerFlow> flow) {
    if (!flow) return;
    ActionsState &st = actionsState();
    if (st.picker == flow) st.picker.reset();
    dispatch_async(dispatch_get_main_queue(), ^{
        flow->alert = nil;
        flow->helper = nil;
    });
}

// No picker: one Error line naming the cause (doc 04 "Failure behavior":
// never modal, never inert). By value, as endPicker.
void pickerFailed(std::shared_ptr<PickerFlow> flow, const std::string &cause) {
    logError("assign-other: no picker shown: " + cause);
    endPicker(flow);
}

// The sheet's OK: the lane and the configuration again, then the assign on
// the captured roots.
std::string assignChosen(const ActionEntry &entry, const std::string &collection) {
    const std::string why = whyNotStartable();
    if (!why.empty()) return notRun(entry.action, why);
    ActionEntry chosen = entry;
    chosen.collection = collection;
    return runMutation(chosen, std::string());
}

void showPicker(const std::shared_ptr<PickerFlow> &flow) {
    const ActionEntry &entry = flow->entry;
    const size_t n = entry.roots.size();
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = n == 1 ? @"Assign to another collection"
                               : [NSString stringWithFormat:@"Assign %zu albums to another collection", n];
    std::string info = affectedAlbumsText(entry.roots);
    if (n == 1 && !entry.roots[0].targetCollection.empty()) {
        info += "\n\nNow: \xE2\x86\x92 " + entry.roots[0].targetCollection;  // U+2192
    }
    alert.informativeText = NSStr(info);
    NSButton *ok = [alert addButtonWithTitle:@"Assign"];
    [alert addButtonWithTitle:@"Cancel"];  // Escape (NSAlert's Cancel rule)

    NSMutableArray<NSString *> *items = [NSMutableArray arrayWithCapacity:flow->names.size()];
    for (const std::string &name : flow->names) [items addObject:NSStr(name)];
    NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 320, 26)];
    combo.usesDataSource = NO;
    [combo addItemsWithObjectValues:items];
    combo.completes = YES;  // type-ahead
    combo.numberOfVisibleItems = std::min<NSInteger>(15, std::max<NSInteger>(1, items.count));
    combo.placeholderString = @"Collection";
    combo.accessibilityLabel = @"Collection to assign to";

    JLIntakeCollectionPicker *helper = [[JLIntakeCollectionPicker alloc] initWithNames:flow->names];
    helper.combo = combo;
    helper.okButton = ok;
    combo.delegate = helper;
    alert.accessoryView = combo;
    [alert layout];
    alert.window.initialFirstResponder = combo;
    [helper update];  // empty text: Assign starts disabled
    flow->alert = alert;
    flow->helper = helper;

    std::shared_ptr<PickerFlow> current = flow;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        const std::string text = StdStr(combo.stringValue);
        endPicker(current);
        if (actionsState().stopped) return;  // quit started: drop it
        if (response != NSAlertFirstButtonReturn) {
            logDebug("assign-other: cancelled in the picker");
        } else if (const std::string *listed = listedCollectionFor(current->names, text)) {
            // The listed name's own bytes, never the typed text.
            logDebug("assign-other: " + assignChosen(current->entry, *listed));
        } else {
            // Assign is disabled for anything else; never pass an unlisted
            // name to --collection.
            notRun(current->entry.action, "\"" + text + "\" is not a listed collection");
        }
    };

    // The window chosen at the click; if it can no longer take a sheet, the
    // main or key window as they are now.
    NSWindow *host = flow->hostWindow;
    if (!usableSheetHost(host)) host = activeSheetHost();
    if (host != nil) {
        [alert beginSheetModalForWindow:host completionHandler:finish];
        return;
    }
    // App-modal, but not from here: this runs inside a main-queue block,
    // and libdispatch does not drain the main queue from a run loop nested
    // in one of its blocks, so every dispatch_async(main) in the process
    // (this component's results, the helper's updateSoon, the host's work)
    // would wait until the alert closes. From a run-loop callout the modal
    // loop drains it as usual.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        if (actionsState().stopped) {  // quit started meanwhile: no alert
            endPicker(current);
            return;
        }
        finish([alert runModal]);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void onCollectionsBudget(uint64_t serial) {
    ActionsState &st = actionsState();
    if (st.stopped || !st.picker || st.picker->serial != serial) return;
    // doc 03 v1.2 "Timeouts": read-only, reported at 10 s and killed (the
    // runner does that); its completion is then dropped.
    CliError timeout;
    timeout.code = kErrorCliTimeout;
    timeout.msg = "no answer within 10 s; stopped";
    pickerFailed(st.picker, "collections: " + renderError(timeout));
}

// A finished `collections` call; an Ok reply is parsed on the queue, so
// the main thread never walks it.
struct CollectionsReply {
    CliResult result;
    CollectionsParseResult parsed;   // Ok results only
    std::vector<std::string> names;  // collectionNames(parsed.collections)
};

void onCollections(uint64_t serial, CollectionsReply &reply) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    const CliResult &result = reply.result;
    logCliResult(result);
    if (!st.picker || st.picker->serial != serial) {
        logDebug("assign-other: a late collections result was ignored");
        return;
    }
    std::shared_ptr<PickerFlow> flow = st.picker;
    if (result.envelope.outcome != CliOutcome::Ok) {
        pickerFailed(flow, "collections: " + collectionsFailureText(result.envelope));
        return;
    }
    const CollectionsParseResult &parsed = reply.parsed;
    if (!parsed.ok) {
        pickerFailed(flow, "collections: unusable reply (" + parsed.error + ")");
        return;
    }
    if (parsed.skipped > 0 || parsed.duplicates > 0) {
        logDebug("collections: " + std::to_string(parsed.skipped) + " entr" + (parsed.skipped == 1 ? "y" : "ies") +
                 " without a usable name skipped, " + std::to_string(parsed.duplicates) +
                 " repeated name(s) dropped");
    }
    flow->names = std::move(reply.names);
    if (flow->names.empty()) {
        pickerFailed(flow, parsed.skipped > 0 ? "the CLI lists no usable collection" : "the CLI lists no collections");
        return;
    }
    showPicker(flow);
}

// Queue: builds and starts `collections --json` (building stats the CLI and
// bun paths).
void startCollectionsOnQueue(uint64_t serial, std::shared_ptr<const CliConfig> config) {
    ActionsState &st = actionsState();
    CliRequest request;
    request.command = CliCommand::Collections;
    CliRunOptions options;  // read-only: pipes, killed at the 10 s budget
    std::string refusal;
    const bool started = startCliCommand(
        st.pickerRunner, *config, request, options, st.queue,
        [serial](CliBudgetEvent) {
            dispatch_async(dispatch_get_main_queue(), ^{
                onCollectionsBudget(serial);
            });
        },
        [serial](CliResult &&result) {
            auto reply = std::make_shared<CollectionsReply>();
            reply->result = std::move(result);
            if (reply->result.envelope.outcome == CliOutcome::Ok) {
                reply->parsed = parseCollections(reply->result.envelope.data);
                reply->names = collectionNames(reply->parsed.collections);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                onCollections(serial, *reply);
            });
        },
        &refusal);
    if (!started) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ActionsState &main = actionsState();
            if (main.stopped || !main.picker || main.picker->serial != serial) return;
            pickerFailed(main.picker, "collections: not started (" + refusal + ")");
        });
    }
}

// --- Execute placement… and Resume placement (B8, main unless noted) ---

// One Execute placement… flow (main thread).
struct ExecuteFlow {
    uint64_t serial = 0;
    ActionEntry entry;  // as the menu captured it
    // The sheet's window, chosen at the click (as for the picker).
    __weak NSWindow *hostWindow = nil;
    uint64_t laneToken = 0;  // the dry run's
    ExecutePlan plan;
    // While the sheet is up (released on a later main-queue turn).
    NSAlert *alert = nil;
};

// Ends `flow` if it is still the current one; its alert is released on a
// later main-queue turn. By value, as endPicker.
void endExecuteFlow(std::shared_ptr<ExecuteFlow> flow) {
    if (!flow) return;
    ActionsState &st = actionsState();
    if (st.executeFlow == flow) st.executeFlow.reset();
    dispatch_async(dispatch_get_main_queue(), ^{
        flow->alert = nil;
    });
}

// The lane token every run holds together.
bool holdRunLane() {
    ActionsState &st = actionsState();
    if (st.runLaneToken != 0) return true;
    st.runLaneToken = st.lane.acquire(LaneHolder::Execute);
    return st.runLaneToken != 0;
}

void releaseRunLaneIfIdle() {
    ActionsState &st = actionsState();
    if (!st.tracker.empty() || st.runLaneToken == 0) return;
    st.lane.finish(st.runLaneToken);
    st.runLaneToken = 0;
}

std::string runFileText(const std::string &stem) {
    return runFileName(stem);
}

// The roots of a run as MutationRoots: the root paths it was started with,
// else the ones the current snapshot has, and the target paths the
// snapshot has (errors that name the target, IntakeMutationResult rule 1c);
// no menu status (the run took minutes, so the first load after it decides
// the baseline).
std::vector<MutationRoot> runRoots(const std::vector<std::string> &ids, const std::vector<std::string> &rootPaths) {
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    std::vector<MutationRoot> out;
    for (size_t i = 0; i < ids.size(); i++) {
        MutationRoot r;
        r.id = ids[i];
        if (i < rootPaths.size()) r.rootPath = rootPaths[i];
        if (const IntakeRecord *record = view ? view->snapshot().recordForId(r.id) : nullptr) {
            if (r.rootPath.empty()) r.rootPath = record->rootPath;
            if (record->hasProposal && record->proposal.targetPathState == TargetPathState::Set) {
                r.targetPath = record->proposal.targetPath;
            }
        }
        out.push_back(std::move(r));
    }
    return out;
}

// A finished run's result: per-root errors, one console line, a refresh.
void applyRunResult(CliCommand command, const std::vector<MutationRoot> &roots, const EnvelopeResult &envelope) {
    const RunSummary summary = summarizeRun(command, roots, envelope);
    RootErrorStore &errors = actionsErrorStore();
    for (const std::string &id : summary.outcome.succeeded) errors.clear(id);
    for (const auto &entry : summary.outcome.rootErrors) {
        const bool reverted =
            std::find(summary.reverted.begin(), summary.reverted.end(), entry.first) != summary.reverted.end();
        // Baseline: a reverted resume root ended approved; any other failed
        // root takes the status of the next load (approved again, still
        // placing, ...), and the tooltip stays until it leaves it.
        errors.set(entry.first, entry.second, reverted ? IntakeStatus::Approved : IntakeStatus::Unknown);
        logDebug("tooltip " + entry.first + " until its status changes: " + entry.second);
    }
    if (summary.outcome.isError) {
        logError(summary.outcome.consoleLine);
    } else {
        logInfo(summary.outcome.consoleLine);
    }
    serviceRefreshAfterCommand();
}

// Queue: deletes a finished run's files.
void deleteRunFilesLater(const std::string &stem) {
    ActionsState &st = actionsState();
    const std::string dir = st.outputDirectory;
    const std::string name = stem;
    dispatch_async(st.queue, ^{
        const size_t n = deleteRunFiles(dir, name);
        logDebug("execute: deleted " + std::to_string(n) + " file(s) of " + name);
    });
}

// A tracked run has ended (own or adopted) with `envelope`: apply it,
// forget the run, release the lane when it was the last, delete its files.
void finishRun(const std::string &stem, const EnvelopeResult &envelope) {
    ActionsState &st = actionsState();
    if (st.stopped) return;  // the files stay: the next session finishes it
    const TrackedRun *found = st.tracker.find(stem);
    if (found == nullptr) return;
    const TrackedRun run = *found;
    st.exitWatches.erase(stem);
    applyRunResult(run.command, runRoots(run.ids, run.rootPaths), envelope);
    st.tracker.remove(stem);
    releaseRunLaneIfIdle();
    deleteRunFilesLater(stem);
}

void onRunSpawned(const std::string &stem, pid_t pid, bool startKnown, const ProcessStartTime &start,
                  bool runFileWritten, const std::string &runFileError) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    if (!st.tracker.spawned(stem, pid, start)) return;
    const TrackedRun *run = st.tracker.find(stem);
    const std::string name = cliCommandName(run->command);
    std::string where;
    if (runFileWritten) {
        where = "run file " + runFileText(stem);
    } else if (!startKnown) {
        where = "run file " + runFileText(stem) + " without its pid: it had already exited";
    } else {
        where = "run file " + runFileText(stem) + " without its pid";
        logError(name + ": the pid could not be added to the run file " + runFileText(stem) + " (" + runFileError +
                 "); if foobar2000 quits before the run ends, the next start finds it by its output file");
    }
    logInfo(name + ": started for " + rootCountText(run->ids.size()) + ": " + idList(run->ids) + " (pid " +
            std::to_string(pid) + ", " + where + ")");
}

void onOwnRunEnded(const std::string &stem, const CliResult &result) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    logCliResult(result);
    st.tracker.exited(stem);
    finishRun(stem, result.envelope);
}

void onRunRefused(const std::string &stem, const std::string &refusal) {
    ActionsState &st = actionsState();
    const TrackedRun *run = st.tracker.find(stem);
    const std::string name = run != nullptr ? cliCommandName(run->command) : "execute";
    st.tracker.remove(stem);
    releaseRunLaneIfIdle();
    if (st.stopped) return;
    // A caller bug, not a root's error: no tooltip (as onRefused).
    logError(name + ": not started (" + refusal + ")");
}

// Queue: writes the provisional run file (no pid yet), builds and spawns the
// detached run, and rewrites the run file with the pid and start time as
// soon as the child exists. Nothing is spawned when the run file cannot be
// written: a run the next session could not find must not start.
void startRunOnQueue(const std::string &stem, std::shared_ptr<const CliConfig> config,
                     std::shared_ptr<const CliRequest> request,
                     std::shared_ptr<const std::vector<std::string>> rootPaths) {
    ActionsState &st = actionsState();
    const std::string dir = st.outputDirectory;
    CliRunOptions options;
    options.outputDirectory = dir;
    options.stdoutFileName = runOutputName(stem);
    options.stderrToDevNull = true;  // PLAN.md 3.7 step 3: nothing reads it, and it could grow unbounded
    const CliCommand command = request->command;
    const std::vector<std::string> ids = request->ids;
    RunFile provisional;
    provisional.command = command;
    provisional.provisional = true;
    provisional.ids = ids;
    provisional.rootPaths = *rootPaths;
    provisional.output = runOutputName(stem);
    std::string provisionalError;
    if (!writeRunFile(dir, stem, provisional, provisionalError)) {
        const std::string refusal = "the run file could not be written: " + provisionalError;
        dispatch_async(dispatch_get_main_queue(), ^{
            onRunRefused(stem, refusal);
        });
        return;
    }
    options.onSpawn = [stem, dir, provisional](const ProcessSpawnInfo &info) {
        // st.queue, before the completion.
        std::string error;
        bool written = false;
        if (info.startTimeKnown) {
            RunFile file = provisional;
            file.provisional = false;
            file.pid = info.pid;
            file.start = info.startTime;
            written = writeRunFile(dir, stem, file, error);
        }
        const pid_t pid = info.pid;
        const bool startKnown = info.startTimeKnown;
        const ProcessStartTime start = info.startTime;
        dispatch_async(dispatch_get_main_queue(), ^{
            onRunSpawned(stem, pid, startKnown, start, written, error);
        });
    };
    std::string refusal;
    const bool started = startCliCommand(
        st.runner, *config, *request, options, st.queue, nullptr,
        [stem](CliResult &&result) {
            auto shared = std::make_shared<CliResult>(std::move(result));
            dispatch_async(dispatch_get_main_queue(), ^{
                onOwnRunEnded(stem, *shared);
            });
        },
        &refusal);
    if (!started) {
        deleteRunFiles(dir, stem);  // the provisional run file; nothing ran
        dispatch_async(dispatch_get_main_queue(), ^{
            onRunRefused(stem, refusal);
        });
    }
}

// Starts `command` (Execute or Resume) on `roots` as a detached run: the
// lane and the configuration first.
std::string startDetachedRun(CliCommand command, const std::vector<ActionRoot> &roots) {
    ActionsState &st = actionsState();
    const IntakeAction action = command == CliCommand::Resume ? IntakeAction::Resume : IntakeAction::Execute;
    auto refuse = [&](const std::string &why) {
        const std::string what = notRun(action, why);
        logDebug(std::string(cliCommandName(command)) + ": " + what);
        return what;
    };
    if (st.stopped) return refuse("intake is not running");
    const std::string why = whyNotStartable();
    if (!why.empty()) return refuse(why);
    auto request = std::make_shared<CliRequest>();
    request->command = command;
    auto rootPaths = std::make_shared<std::vector<std::string>>();
    for (const ActionRoot &r : roots) {
        if (std::find(request->ids.begin(), request->ids.end(), r.id) != request->ids.end()) continue;
        request->ids.push_back(r.id);
        rootPaths->push_back(r.rootPath);
    }
    if (request->ids.empty()) return refuse("no qualifying root");
    auto config = std::make_shared<CliConfig>();
    if (!serviceMutationConfig(*config)) return refuse("intake is not running or has no CLI path");
    if (!holdRunLane()) return refuse("another intake command is still running");
    const std::string stem = uniqueRunStem(st.outputDirectory, std::chrono::system_clock::now());
    st.tracker.begin(stem, command, request->ids, *rootPaths);
    logInfo(std::string(cliCommandName(command)) + ": starting for " + rootCountText(request->ids.size()) + ": " +
            idList(request->ids));
    std::shared_ptr<const CliConfig> sharedConfig = config;
    std::shared_ptr<const CliRequest> sharedRequest = request;
    std::shared_ptr<const std::vector<std::string>> sharedPaths = rootPaths;
    dispatch_async(st.queue, ^{
        startRunOnQueue(stem, sharedConfig, sharedRequest, sharedPaths);
    });
    return "starting for " + rootCountText(request->ids.size());
}

// The sheet's Execute. The lane was free while the sheet was up, so roots
// that changed meanwhile (no longer approved, another target) are left out
// first, one Error line each (IntakeExecutePlan recheckPlaceable); then the
// lane and the configuration again (startDetachedRun).
void confirmExecute(const std::shared_ptr<ExecuteFlow> &flow) {
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    const ExecuteRecheck recheck =
        recheckPlaceable(flow->plan, [&view](const std::string &id) -> const IntakeRecord * {
            return view ? view->snapshot().recordForId(id) : nullptr;
        });
    for (const auto &dropped : recheck.dropped) {
        logError("execute: " + dropped.first + " left out: " + dropped.second);
    }
    if (recheck.keep.empty()) {
        const std::string what = notRun(IntakeAction::Execute, "every root changed while the sheet was open");
        logDebug("execute: " + what);
        return;
    }
    startDetachedRun(CliCommand::Execute, recheck.keep);  // logs its start or refusal
}

void showExecuteSheet(const std::shared_ptr<ExecuteFlow> &flow) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSStr(executeSheetTitle(flow->plan));
    alert.informativeText = NSStr(executeSheetText(flow->plan));
    [alert addButtonWithTitle:@"Execute"];
    [alert addButtonWithTitle:@"Cancel"];  // Escape (NSAlert's Cancel rule)
    flow->alert = alert;

    std::shared_ptr<ExecuteFlow> current = flow;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        endExecuteFlow(current);
        if (actionsState().stopped) return;  // quit started: drop it
        if (response != NSAlertFirstButtonReturn) {
            logDebug("execute: cancelled in the sheet");
        } else {
            // The lane and the configuration again (startDetachedRun).
            confirmExecute(current);
        }
    };
    // The window chosen at the click; if it can no longer take a sheet, the
    // main or key window as they are now.
    NSWindow *host = flow->hostWindow;
    if (!usableSheetHost(host)) host = activeSheetHost();
    if (host != nil) {
        [alert beginSheetModalForWindow:host completionHandler:finish];
        return;
    }
    // App-modal from a run-loop callout, never inside this main-queue block
    // (see showPicker: the main queue must keep draining while it is up).
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        if (actionsState().stopped) {
            endExecuteFlow(current);
            return;
        }
        finish([alert runModal]);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void onExecuteDryRunBudget(uint64_t serial, uint64_t token, const std::vector<MutationRoot> &roots,
                           CliBudgetEvent event) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    // The lane release and its Info line (no E_CLI_TIMEOUT: doc 03 excepts
    // execute); the late result is dropped. The confirmation still comes and
    // says the check did not finish in 10 s (doc 04 v1.2 "Mutation lane"):
    // every captured root, unchecked; execute checks each again.
    onBudget(token, CliCommand::Execute, roots, event);
    if (!st.executeFlow || st.executeFlow->serial != serial) return;
    std::shared_ptr<ExecuteFlow> flow = st.executeFlow;
    flow->plan = planUnchecked(flow->entry.roots);
    logDebug(std::string(kExecuteDryRunName) + ": " + executeSheetSummary(flow->plan));
    showExecuteSheet(flow);
}

void onExecuteDryRun(uint64_t serial, uint64_t token, const CliResult &result) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    logCliResult(result);
    if (!st.lane.finish(token)) {
        logInfo("execute: a late dry-run result was ignored");
        return;
    }
    if (!st.executeFlow || st.executeFlow->serial != serial) return;
    std::shared_ptr<ExecuteFlow> flow = st.executeFlow;
    flow->plan = planExecute(flow->entry.roots, result.envelope);
    const ExecutePlan &plan = flow->plan;

    // Roots the dry run refused: their error as a tooltip (doc 04 "Failure
    // behavior"), baseline the menu's status, and a refresh to show it.
    if (!plan.outcome.rootErrors.empty()) {
        std::unordered_map<std::string, IntakeStatus> menuStatus;
        for (const ActionRoot &r : flow->entry.roots) menuStatus.emplace(r.id, r.status);
        RootErrorStore &errors = actionsErrorStore();
        for (const auto &entry : plan.outcome.rootErrors) {
            auto status = menuStatus.find(entry.first);
            errors.set(entry.first, entry.second, status == menuStatus.end() ? IntakeStatus::Unknown : status->second);
            logDebug("tooltip " + entry.first + " until its status changes: " + entry.second);
        }
        serviceRefreshAfterCommand();
    }
    const bool reported = !plan.outcome.rootErrors.empty() || plan.outcome.isError;
    if (reported) logError(plan.outcome.consoleLine);
    if (plan.placeable.empty()) {
        if (!reported) {
            logError(std::string(kExecuteDryRunName) + ": no root can be placed (the dry run listed none of them)");
        }
        endExecuteFlow(flow);
        return;
    }
    logDebug(std::string(kExecuteDryRunName) + ": " + executeSheetSummary(plan));
    showExecuteSheet(flow);
}

// Queue: builds and starts `execute <ids> --dry-run --json`.
void startExecuteDryRunOnQueue(uint64_t serial, uint64_t token, std::shared_ptr<const CliConfig> config,
                               std::shared_ptr<const CliRequest> request,
                               std::shared_ptr<const std::vector<MutationRoot>> roots) {
    ActionsState &st = actionsState();
    CliRunOptions options;  // ExecuteDryRun: output files, a lane release at the budget, never killed
    options.outputDirectory = st.outputDirectory;
    std::string refusal;
    const bool started = startCliCommand(
        st.runner, *config, *request, options, st.queue,
        [serial, token, roots](CliBudgetEvent event) {
            dispatch_async(dispatch_get_main_queue(), ^{
                onExecuteDryRunBudget(serial, token, *roots, event);
            });
        },
        [serial, token](CliResult &&result) {
            auto shared = std::make_shared<CliResult>(std::move(result));
            dispatch_async(dispatch_get_main_queue(), ^{
                onExecuteDryRun(serial, token, *shared);
            });
        },
        &refusal);
    if (!started) {
        dispatch_async(dispatch_get_main_queue(), ^{
            onRefused(token, CliCommand::Execute, refusal);
            ActionsState &main = actionsState();
            if (!main.stopped && main.executeFlow && main.executeFlow->serial == serial) {
                endExecuteFlow(main.executeFlow);
            }
        });
    }
}

// --- Swap to library paths and Delete local copy… (B9, main unless noted) ---

std::unordered_set<std::string> rootIdSet(const std::vector<ActionRoot> &roots) {
    std::unordered_set<std::string> ids;
    for (const ActionRoot &r : roots) ids.insert(r.id);
    return ids;
}

t_size activePlaylist() {
    auto pm = playlist_manager::get();
    const t_size active = pm->get_active_playlist();
    return active < pm->get_playlist_count() ? active : SIZE_MAX;
}

// How long the Delete confirmation waits for the sidecar reads (as the
// execute dry run's 10 s report).
constexpr double kDeleteReadSeconds = 10.0;

// The entries of every playlist that still point at an income path of
// `ids` (IntakeSwap incomeRowCensus: fail closed, `first` first), and of
// them the entries Swap never moves, judged by each root's files[] in
// `files` (a shadow, a file files[] does not list, no target; a root
// missing from `files` counts as movable: Swap decides). `census`
// (optional) gets the census itself.
GcIncomeRows countIncomeRows(const IntakeView &view, const std::unordered_set<std::string> &ids,
                             const PlaylistRef &first,
                             const std::unordered_map<std::string, PlacedRootFiles> *files,
                             IncomeRowCensus *census = nullptr) {
    const auto started = std::chrono::steady_clock::now();
    IncomeRowCensus c = incomeRowCensus(ids, view, first);
    {
        // Main thread over every playlist: its cost on a large profile is
        // what the in-app run measures.
        const long long micros = std::chrono::duration_cast<std::chrono::microseconds>(
                                     std::chrono::steady_clock::now() - started)
                                     .count();
        char line[200];
        snprintf(line, sizeof line,
                 "delete: income-row census over %zu playlist(s): %zu income entries in %zu, %zu unchecked, %lld.%03lld ms",
                 static_cast<size_t>(playlist_manager::get()->get_playlist_count()), c.total, c.playlists.size(),
                 c.unchecked, micros / 1000, micros % 1000);
        logDebug(line);
    }
    GcIncomeRows out;
    out.rows = c.total;
    out.inFirst = c.inFirst;
    out.playlists = c.playlists.size();
    out.unchecked = c.unchecked;
    if (files != nullptr && !c.rows.empty()) {
        const LibraryPrefix prefix = serviceActionInfo().libraryPrefix;
        ViewScratch scratch;
        std::string key;
        for (size_t i = 0; i < c.rows.size(); i++) {
            auto f = files->find(c.rows[i].rootId);
            if (f == files->end()) continue;
            SwapSkip skip = SwapSkip::NotInSidecar;
            if (view.matchKey(c.rows[i].native, scratch, key)) skip = planSwap(f->second, key, prefix).skip;
            if (skip == SwapSkip::Shadow || skip == SwapSkip::NotInSidecar || skip == SwapSkip::NoTarget) {
                out.noLibraryCopy += c.entries[i];
            }
        }
    }
    if (census != nullptr) *census = std::move(c);
    return out;
}

// One Delete local copy… flow (main thread).
struct DeleteFlow {
    uint64_t serial = 0;
    ActionEntry entry;  // its roots: gcEligibleRoots of the menu's
    // The sheet's window, chosen at the click (as for the picker).
    __weak NSWindow *hostWindow = nil;
    // The playlist the click came from (the active one then): counted first
    // and swapped first; every other playlist is counted and swapped too.
    PlaylistRef playlist;
    bool filesRead = false;  // the sidecar reads came back (the 10 s limit no longer applies)
    std::unordered_map<std::string, PlacedRootFiles> files;  // by root id, the roots that were read
    std::vector<GcConfirmRoot> confirm;
    GcIncomeRows income;
    // While the sheet is up (released on a later main-queue turn).
    NSAlert *alert = nil;
};

// Ends `flow` if it is still the current one; its alert is released on a
// later main-queue turn. By value, as endPicker.
void endDeleteFlow(std::shared_ptr<DeleteFlow> flow) {
    if (!flow) return;
    ActionsState &st = actionsState();
    if (st.deleteFlow == flow) st.deleteFlow.reset();
    dispatch_async(dispatch_get_main_queue(), ^{
        flow->alert = nil;
    });
}

// Delete confirmed: the captured roots against the current snapshot
// (IntakeGcPlan recheckGcRoots, one Error line per root dropped), then the
// lane and the configuration, then gc.
void deleteConfirmed(std::shared_ptr<DeleteFlow> flow) {
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    // An inert view keeps the last snapshot: nothing goes to a CLI the
    // version gate (or a failed load) has set aside.
    if (view && view->isInert()) {
        notRun(IntakeAction::DeleteLocal, "intake is inert: " + view->inertReason());
        endDeleteFlow(flow);
        return;
    }
    const GcRecheck recheck = recheckGcRoots(flow->entry.roots, [&view](const std::string &id) -> const IntakeRecord * {
        return view ? view->snapshot().recordForId(id) : nullptr;
    });
    for (const auto &dropped : recheck.dropped) {
        logError("delete-local: " + dropped.first + " left out: " + dropped.second);
    }
    if (recheck.keep.empty()) {
        notRun(IntakeAction::DeleteLocal, "every root changed while the confirmation was open");
        endDeleteFlow(flow);
        return;
    }
    const std::string why = whyNotStartable();
    if (!why.empty()) {
        notRun(IntakeAction::DeleteLocal, why);
        endDeleteFlow(flow);
        return;
    }
    ActionEntry kept = flow->entry;
    kept.roots = recheck.keep;
    const std::string what = runMutation(kept, std::string());
    logDebug("delete-local: " + what);
    endDeleteFlow(flow);
}

// "Swap, then delete", the end: gc only when no entry of any playlist still
// points at an income path of these roots and none was left unchecked
// (deleting files that rows still point at would leave dead entries).
void deleteAfterSwapCheck(std::shared_ptr<DeleteFlow> flow) {
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    if (!view) {
        notRun(IntakeAction::DeleteLocal, "no intake data to check the playlists; nothing deleted");
        endDeleteFlow(flow);
        return;
    }
    const GcIncomeRows left = countIncomeRows(*view, rootIdSet(flow->entry.roots), flow->playlist, nullptr);
    if (!left.clear()) {
        std::string why;
        if (left.rows > 0) {
            why = std::to_string(left.rows) + " row(s) in " + std::to_string(left.playlists) +
                  " playlist(s) still point at the income paths of these roots";
        }
        if (left.unchecked > 0) {
            why += (why.empty() ? "" : "; ") + std::to_string(left.unchecked) +
                   " playlist row(s) on a slow volume could not be checked";
        }
        notRun(IntakeAction::DeleteLocal, why + "; nothing deleted");
        endDeleteFlow(flow);
        return;
    }
    deleteConfirmed(flow);
}

// "Swap, then delete", one step: swaps the income rows of the next playlist
// in `pending` (found again; gone or without such rows: skipped), then the
// next; at the end, deleteAfterSwapCheck.
void deleteSwapNext(std::shared_ptr<DeleteFlow> flow, std::shared_ptr<std::vector<PlaylistRef>> pending,
                    size_t next) {
    if (actionsState().stopped) return;
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    const std::unordered_set<std::string> ids = rootIdSet(flow->entry.roots);
    while (view && next < pending->size()) {
        const t_size playlist = findPlaylist((*pending)[next++]);
        if (playlist == SIZE_MAX) continue;
        NativePathMenuBudget budget;
        std::vector<SwapRow> rows = swapIncomeRows(playlist, ids, *view, &budget);
        if (rows.empty()) continue;
        std::string why;
        const bool started = swapStart(
            playlist, std::move(rows), view, serviceActionInfo().libraryPrefix,
            [flow, pending, next](const SwapResult &) {
                if (actionsState().stopped) return;
                deleteSwapNext(flow, pending, next);
            },
            why);
        if (!started) {
            notRun(IntakeAction::DeleteLocal, "the swap did not start: " + why);
            endDeleteFlow(flow);
        }
        return;
    }
    deleteAfterSwapCheck(flow);
}

// "Swap, then delete": the rows of these roots that still point at income
// paths are swapped, in the playlist the click came from first, then in
// every other playlist that holds such rows (a locked one keeps them); gc
// runs only when none is left anywhere afterwards and none was unchecked.
void deleteAfterSwap(std::shared_ptr<DeleteFlow> flow) {
    if (!flow->income.offerSwap()) {
        notRun(IntakeAction::DeleteLocal, "\"Swap, then delete\" was not offered; nothing deleted");
        endDeleteFlow(flow);
        return;
    }
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    auto pending = std::make_shared<std::vector<PlaylistRef>>();
    if (view) {
        IncomeRowCensus census;
        countIncomeRows(*view, rootIdSet(flow->entry.roots), flow->playlist, nullptr, &census);
        *pending = std::move(census.playlists);
    }
    deleteSwapNext(flow, pending, 0);
}

void showDeleteSheet(const std::shared_ptr<DeleteFlow> &flow) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = NSStr(gcConfirmTitle(flow->entry.roots.size()));
    alert.informativeText = NSStr(gcConfirmText(flow->confirm, flow->income));
    NSButton *deleteButton = [alert addButtonWithTitle:@"Delete"];
    if ([deleteButton respondsToSelector:@selector(setHasDestructiveAction:)]) deleteButton.hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"Cancel"];  // Escape (NSAlert's Cancel rule)
    if (flow->income.offerSwap()) [alert addButtonWithTitle:@"Swap, then delete"];
    flow->alert = alert;

    std::shared_ptr<DeleteFlow> current = flow;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        if (actionsState().stopped) {  // quit started: drop it
            endDeleteFlow(current);
            return;
        }
        if (response == NSAlertFirstButtonReturn) {
            deleteConfirmed(current);
        } else if (response == NSAlertThirdButtonReturn && current->income.offerSwap()) {
            deleteAfterSwap(current);
        } else {
            logDebug("delete-local: cancelled in the confirmation");
            endDeleteFlow(current);
        }
    };
    // The window chosen at the click; if it can no longer take a sheet, the
    // main or key window as they are now.
    NSWindow *host = flow->hostWindow;
    if (!usableSheetHost(host)) host = activeSheetHost();
    if (host != nil) {
        [alert beginSheetModalForWindow:host completionHandler:finish];
        return;
    }
    // App-modal from a run-loop callout, never inside this main-queue block
    // (see showPicker: the main queue must keep draining while it is up).
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        if (actionsState().stopped) {
            endDeleteFlow(current);
            return;
        }
        finish([alert runModal]);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void onDeleteFilesRead(uint64_t serial, std::vector<PlacedFilesReply> &replies) {
    ActionsState &st = actionsState();
    if (st.stopped || !st.deleteFlow || st.deleteFlow->serial != serial) return;
    std::shared_ptr<DeleteFlow> flow = st.deleteFlow;
    flow->filesRead = true;
    flow->confirm.clear();
    flow->files.clear();
    for (const ActionRoot &root : flow->entry.roots) {
        const PlacedFilesReply *reply = nullptr;
        for (const PlacedFilesReply &r : replies) {
            if (r.id == root.id) reply = &r;
        }
        if (reply != nullptr && reply->ok) {
            flow->confirm.push_back(gcConfirmRoot(root, &reply->files, std::string()));
            flow->files[root.id] = reply->files;
        } else {
            const std::string error = reply != nullptr ? reply->error : std::string("no longer listed by intake status");
            logDebug("delete-local: no file list for " + root.id + ": " + error);
            flow->confirm.push_back(gcConfirmRoot(root, nullptr, error));
        }
    }
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    flow->income = view ? countIncomeRows(*view, rootIdSet(flow->entry.roots), flow->playlist, &flow->files)
                        : GcIncomeRows();
    logDebug("delete-local: confirmation: " + gcConfirmSummary(flow->confirm, flow->income));
    showDeleteSheet(flow);
}

// --- leftover runs (B8) ---

// Queue -> main: an adopted run's process has ended.
void onAdoptedRunEnded(const std::string &stem, const EnvelopeResult &envelope) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    const TrackedRun *run = st.tracker.find(stem);
    if (run == nullptr) return;
    logInfo(std::string(cliCommandName(run->command)) + ": the run adopted from an earlier session (pid " +
            std::to_string(run->pid) + ") has ended");
    st.tracker.exited(stem);
    finishRun(stem, envelope);
}

void watchAdoptedRun(const TrackedRun &run) {
    ActionsState &st = actionsState();
    const std::string stem = run.stem;
    const std::string dir = st.outputDirectory;
    st.exitWatches[stem] = std::make_shared<ProcessExitWatch>(run.pid, run.start, st.queue, [stem, dir]() {
        // st.queue: the output is complete now.
        std::string text, error;
        if (!readRunOutput(dir, runOutputName(stem), text, error)) text.clear();
        auto envelope = std::make_shared<EnvelopeResult>(parseDetachedOutput(text, error));
        dispatch_async(dispatch_get_main_queue(), ^{
            onAdoptedRunEnded(stem, *envelope);
        });
    });
}

struct RunScanResult {
    LeftoverScan scan;
    std::vector<EnvelopeResult> finished;  // aligned with scan.finish
};

void onRunScan(const std::shared_ptr<RunScanResult> &result) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    const LeftoverScan &scan = result->scan;
    if (!scan.error.empty()) logError("execute: cannot check for leftover runs: " + scan.error);
    for (const std::string &note : scan.notes) logDebug("execute: removed " + note);
    if (!scan.swept.empty()) {
        logInfo("execute: removed " + std::to_string(scan.swept.size()) + " leftover file(s) from " +
                st.outputDirectory + " that belonged to no run");
    }
    for (const LeftoverRun &run : scan.adopt) {
        if (!st.tracker.adopt(run.stem, run.file)) continue;
        if (!holdRunLane()) logDebug("execute: the lane was busy while adopting " + run.stem);
        const std::string name = cliCommandName(run.file.command);
        if (run.byOutput) {
            logDebug(name + ": the run file " + runFileText(run.stem) +
                     " has no pid (written before its start); pid " + std::to_string(run.file.pid) +
                     " still has its output open");
        }
        logInfo(name + ": adopted a run from an earlier session: pid " + std::to_string(run.file.pid) + ", " +
                rootCountText(run.file.ids.size()) + ": " + idList(run.file.ids) + " (run file " +
                runFileText(run.stem) + "); intake commands wait until it ends");
        watchAdoptedRun(*st.tracker.find(run.stem));
    }
    for (size_t i = 0; i < scan.finish.size(); i++) {
        const LeftoverRun &run = scan.finish[i];
        const std::string name = cliCommandName(run.file.command);
        const std::string pid = run.file.provisional ? std::string("no pid recorded")
                                                     : "pid " + std::to_string(run.file.pid);
        logInfo(name + ": a run from an earlier session has ended (" + pid + ", " +
                rootCountText(run.file.ids.size()) + ": " + idList(run.file.ids) + ", run file " +
                runFileText(run.stem) + "); applying its result");
        applyRunResult(run.file.command, runRoots(run.file.ids, run.file.rootPaths), result->finished[i]);
        deleteRunFilesLater(run.stem);
    }
    st.runScanDone = true;
}

// Main thread: the "Assign to other collection…" flow for `entry` (see the
// top of IntakeActions.h). Returns what happened so far, for a log line.
std::string actionsAssignOther(const ActionEntry &entry) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    if (!entry.enabled) return "not run: the item is disabled";
    if (entry.roots.empty()) return "not run: no qualifying root";
    if (st.picker) {
        logInfo("assign-other: the collection picker is already open or loading; this request is ignored");
        return "ignored: the collection picker is already open or loading";
    }
    // No collections call (and no sheet) for an assign that could not start.
    const std::string why = whyNotStartable();
    if (!why.empty()) return notRun(entry.action, why);
    CliConfig config;
    if (!serviceMutationConfig(config)) {
        return notRun(entry.action, "intake is not running or has no CLI path");
    }
    auto flow = std::make_shared<PickerFlow>();
    flow->serial = ++st.pickerSerial;
    flow->entry = entry;
    flow->hostWindow = sheetHostWindow();  // now, while the pointer is where the menu was
    st.picker = flow;
    logDebug("assign-other: loading the collections for " + rootCountText(entry.roots.size()));
    const uint64_t serial = flow->serial;
    auto sharedConfig = std::make_shared<const CliConfig>(std::move(config));
    dispatch_async(st.queue, ^{
        startCollectionsOnQueue(serial, sharedConfig);
    });
    return "loading the collections";
}

// Main thread: Execute placement… for `entry` (see the top of
// IntakeActions.h). Returns what happened so far.
std::string actionsExecutePlacement(const ActionEntry &entry) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    if (!entry.enabled) return "not run: the item is disabled";
    if (entry.roots.empty()) return "not run: no qualifying root";
    if (st.executeFlow) {
        logInfo("execute: the execute sheet is already open or its dry run is running; this request is ignored");
        return "ignored: the execute sheet is already open or its dry run is running";
    }
    // No dry run (and no sheet) for a run that could not start.
    const std::string why = whyNotStartable();
    if (!why.empty()) return notRun(entry.action, why);
    CliRequest request;
    std::string refusal;
    if (!requestForEntry(entry, std::string(), request, &refusal)) return notRun(entry.action, refusal);
    request.dryRun = true;
    CliConfig config;
    if (!serviceMutationConfig(config)) {
        return notRun(entry.action, "intake is not running or has no CLI path");
    }
    const uint64_t token = st.lane.acquire(laneHolderFor(request));
    if (token == 0) return notRun(entry.action, "another intake command is still running");
    auto flow = std::make_shared<ExecuteFlow>();
    flow->serial = ++st.executeSerial;
    flow->entry = entry;
    flow->hostWindow = sheetHostWindow();  // now, while the pointer is where the menu was
    flow->laneToken = token;
    st.executeFlow = flow;
    logInfo(std::string(kExecuteDryRunName) + ": starting for " + rootCountText(request.ids.size()) + ": " +
            idList(request.ids));
    auto roots = std::make_shared<std::vector<MutationRoot>>();
    for (const ActionRoot &r : entry.roots) roots->push_back({r.id, r.rootPath, r.status, r.targetPath});
    const uint64_t serial = flow->serial;
    auto sharedConfig = std::make_shared<const CliConfig>(std::move(config));
    auto sharedRequest = std::make_shared<const CliRequest>(request);
    std::shared_ptr<const std::vector<MutationRoot>> sharedRoots = roots;
    dispatch_async(st.queue, ^{
        startExecuteDryRunOnQueue(serial, token, sharedConfig, sharedRequest, sharedRoots);
    });
    return "checking " + rootCountText(request.ids.size()) + " with a dry run";
}

// Main thread: Resume placement for `entry`. Returns what happened so far.
std::string actionsResume(const ActionEntry &entry) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    if (!entry.enabled || entry.roots.empty()) {
        const std::string what = !entry.enabled ? "not run: the item is disabled" : "not run: no qualifying root";
        return what;
    }
    return startDetachedRun(CliCommand::Resume, entry.roots);
}

// Main thread: Swap to library paths for `entry` on the rows of `handles`
// (see the top of IntakeActions.h). Returns what happened so far.
std::string actionsSwap(const ActionEntry &entry, metadb_handle_list_cref handles) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    if (!entry.enabled) return "not run: the item is disabled";
    if (entry.roots.empty()) return "not run: no qualifying root";
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    if (!view) return notRun(entry.action, "no intake data yet");
    // The host frees `handles` when this returns: the rows are copied now.
    NativePathMenuBudget budget;
    size_t unchecked = 0;
    std::vector<SwapRow> rows = swapRowsFromHandles(handles, rootIdSet(entry.roots), *view, &budget, &unchecked);
    if (unchecked > 0) {
        logInfo("swap: " + std::to_string(unchecked) +
                " selected row(s) on a slow volume could not be checked and are left as they are");
    }
    if (rows.empty()) {
        return notRun(entry.action, "none of the selected rows points at an income path of these roots");
    }
    std::string why;
    const size_t count = rows.size();
    const bool started = swapStart(
        activePlaylist(), std::move(rows), view, serviceActionInfo().libraryPrefix,
        [](const SwapResult &) {},
        why);
    if (!started) return notRun(entry.action, why);
    return "swapping " + std::to_string(count) + " row(s)";
}

// Main thread: Delete local copy… for `entry`. Returns what happened so far.
std::string actionsDeleteLocal(const ActionEntry &entry) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    if (!entry.enabled) return "not run: the item is disabled";
    if (entry.roots.empty()) return "not run: no qualifying root";
    // The permanent guard first: placed, verified roots only
    // (requestForEntry applies it again to whatever finally runs).
    ActionEntry eligible = entry;
    eligible.roots = gcEligibleRoots(entry.roots);
    if (eligible.roots.empty()) return notRun(entry.action, "no placed root with placed.verified");
    if (st.deleteFlow) {
        logInfo("delete-local: the confirmation is already open or being prepared; this request is ignored");
        return "ignored: the delete confirmation is already open or being prepared";
    }
    // No confirmation for a call that could not start anyway.
    const std::string why = whyNotStartable();
    if (!why.empty()) return notRun(entry.action, why);
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    if (view && view->isInert()) return notRun(entry.action, "intake is inert: " + view->inertReason());
    if (!serviceActionInfo().confirmGc) {
        const std::string what = runMutation(eligible, std::string());
        return "no confirmation (confirm_gc 0); gc: " + what;
    }
    std::vector<IntakeRecord> records;
    for (const ActionRoot &r : eligible.roots) {
        if (const IntakeRecord *record = view ? view->snapshot().recordForId(r.id) : nullptr) {
            records.push_back(*record);
        }
    }
    auto flow = std::make_shared<DeleteFlow>();
    flow->serial = ++st.deleteSerial;
    flow->entry = eligible;
    flow->hostWindow = sheetHostWindow();  // now, while the pointer is where the menu was
    flow->playlist = playlistRefFor(activePlaylist());
    st.deleteFlow = flow;
    const uint64_t serial = flow->serial;
    swapReadPlacedFiles(std::move(records), [serial](std::vector<PlacedFilesReply> replies) {
        onDeleteFilesRead(serial, replies);
    });
    // A share that stops answering must not hold the flow (and every later
    // click) forever: after 10 s the flow ends, and the late reply finds no
    // flow with its serial.
    std::weak_ptr<DeleteFlow> weakFlow = flow;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(kDeleteReadSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       std::shared_ptr<DeleteFlow> late = weakFlow.lock();
                       ActionsState &now = actionsState();
                       if (!late || now.stopped || now.deleteFlow != late || late->filesRead) return;
                       notRun(IntakeAction::DeleteLocal,
                              "the sidecars could not be read within 10 s (the share is "
                              "not answering); no confirmation, nothing deleted");
                       endDeleteFlow(late);
                   });
    return "reading the file lists of " + rootCountText(eligible.roots.size());
}

// Main thread: runs `entry` as a click on its menu item does. Returns what
// happened, for a log line.
std::string actionsDispatch(const ActionEntry &entry) {
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
        if (serviceActionInfo().confirmReject) {
            // No confirmation for a call that could not start anyway.
            const std::string why = whyNotStartable();
            if (!why.empty()) return notRun(entry.action, why);
            confirmReject(entry);
            return "asking for confirmation";
        }
        // confirm_reject 0: no dialog, no reason.
        return runMutation(entry, std::string());
    }
    if (entry.action == IntakeAction::AssignOther) return actionsAssignOther(entry);
    if (entry.action == IntakeAction::Execute) return actionsExecutePlacement(entry);
    if (entry.action == IntakeAction::Resume) return actionsResume(entry);
    if (entry.action == IntakeAction::DeleteLocal) return actionsDeleteLocal(entry);
    if (entry.action == IntakeAction::Swap) return "not run: Swap needs the selected rows (actionsSwap)";
    // Propose, Approve, Assign to X (its collection is in the entry).
    return runMutation(entry, std::string());
}

} // anonymous namespace

void actionsStartRunScan() {
    ActionsState &st = actionsState();
    if (st.stopped || st.runScanStarted) return;
    st.runScanStarted = true;
    const std::string dir = st.outputDirectory;
    if (dir.empty()) {
        st.runScanDone = true;
        return;
    }
    dispatch_async(st.queue, ^{
        auto result = std::make_shared<RunScanResult>();
        result->scan = scanLeftoverRuns(dir, processIsLive);
        for (const LeftoverRun &run : result->scan.finish) {
            result->finished.push_back(parseDetachedOutput(run.output, run.outputError));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            onRunScan(result);
        });
    });
}

RootErrorStore &actionsErrorStore() {
    static RootErrorStore *store = new RootErrorStore();  // leaked: read by the loader queue
    return *store;
}

bool actionsLaneBusy() {
    return actionsState().lane.busy();
}

// The menu's table for `sel` (main thread): each row by its income path,
// else (B9) through the library index; `rootCount` gets the number of roots.
static ActionTable menuTableFor(metadb_handle_list_cref sel, size_t &rootCount) {
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    std::vector<const IntakeRecord *> rows;
    std::vector<const IntakeRecord *> libraryRows;
    // Main thread: at most 3 slow mac-volume conversions per volume in this
    // menu (IntakeSlowVolumeGuard.h, NativePathMenuBudget).
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
                const IntakeRecord *record = path != nullptr ? view->recordFor(path, scratch) : nullptr;
                rows.push_back(record);
                // A row already swapped to its library copy: Delete only.
                if (record == nullptr && path != nullptr) libraryRows.push_back(view->libraryRecordFor(path, scratch));
            }
        }
    }
    if (budget.spent()) {
        logInfo("menu: " + std::to_string(kSlowCallsToMark) + " mac-volume path conversions took over " +
                std::to_string(kSlowNativePathMicros / 1000) + " ms on one volume; " + std::to_string(budget.skipped()) +
                " row(s) on that volume were left out");
    }
    const std::vector<const IntakeRecord *> roots = selectionRoots(rows);
    const std::vector<const IntakeRecord *> libraryRoots = libraryOnlyRoots(roots, libraryRows);
    ActionContext context = liveContext(view.get());
    // Rows left out may be other roots: no one-root quick assign.
    context.selectionIncomplete = budget.skipped() > 0;
    rootCount = roots.size() + libraryRoots.size();
    return buildActionTable(roots, context, menuActions(), libraryRoots);
}

void actionsBuildMenu(metadb_handle_list_cref sel, pfc::list_t<jl_context_action> &out) {
    out.remove_all();
    ActionsState &st = actionsState();
    st.menuTable = ActionTable();
    if (st.stopped) return;

    size_t rootCount = 0;
    st.menuTable = menuTableFor(sel, rootCount);
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
                 rootCountText(rootCount) + " in " + std::to_string(sel.get_count()) + " row(s)");
    }
}

void actionsExecute(uint32_t actionId, metadb_handle_list_cref sel) {
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
    // Swap is the one action that works on rows: they are copied now (the
    // host frees `sel` when this returns).
    const std::string what = entry.action == IntakeAction::Swap ? actionsSwap(entry, sel) : actionsDispatch(entry);
    logDebug("menu: " + entry.title + ": " + what);
}

void actionsShutdown() {
    ActionsState &st = actionsState();
    st.stopped = true;
    st.menuTable = ActionTable();
    // A running `collections` is killed; one not yet spawned never starts.
    st.pickerRunner.closeReadLane();
    // A swap's result is dropped (the playlist stays as it is).
    swapShutdown();
    st.deleteFlow.reset();
    // Detached runs keep running and keep their files (the next session
    // adopts or finishes them); only the watching stops.
    for (auto &watch : st.exitWatches) watch.second->cancel();
    st.exitWatches.clear();
}

} // namespace intake
