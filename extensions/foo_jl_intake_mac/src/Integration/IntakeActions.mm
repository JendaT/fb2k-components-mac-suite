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

#include "../Core/IntakeCliRunner.h"
#include "../Core/IntakeCollections.h"
#include "../Core/IntakeErrorMap.h"
#include "../Core/IntakeExecutePlan.h"
#include "../Core/IntakeExecuteTracker.h"
#include "../Core/IntakeLog.h"
#include "../Core/IntakeMutationLane.h"
#include "../Core/IntakeMutationResult.h"
#include "../Core/IntakeSlowVolumeGuard.h"
#include "../Core/IntakeView.h"

#include <algorithm>
#include <cstdio>
#include <memory>
#include <unordered_map>

// The picker's combo box delegate (B7): "Assign" is enabled only while the
// text stands for one of the listed names (IntakeCollections
// listedCollectionFor). ObjC classes share one namespace in the process,
// hence the component prefix.
@interface JLIntakeCollectionPicker : NSObject <NSComboBoxDelegate>
@property(nonatomic, weak) NSComboBox *combo;
@property(nonatomic, weak) NSButton *okButton;
@property(nonatomic, weak) NSButton *cancelButton;
@property(nonatomic) BOOL closed;  // the alert has ended
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

// A test_actions step waiting for a detached run's spawn (B8).
struct RunTestReport {
    std::shared_ptr<const ExecuteTestHooks> hooks;
    std::string prefix;  // the step's text so far (execute: the dry run's summary)
};

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
    std::unordered_map<std::string, RunTestReport> runReports;                        // by stem
    // B8: the leftover-run scan (actionsStartRunScan). No mutating call
    // starts before it is done.
    bool runScanStarted = false;
    bool runScanDone = false;
    std::vector<std::function<void()>> afterRunScan;

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
    std::shared_ptr<const PickerTestHooks> test;
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
    for (const ActionRoot &r : entry.roots) roots->push_back({r.id, r.rootPath, r.status, r.targetPath});
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

// The main window, else the key window, when one can take a sheet now.
NSWindow *activeSheetHost() {
    if (usableSheetHost(NSApp.mainWindow)) return NSApp.mainWindow;
    if (usableSheetHost(NSApp.keyWindow)) return NSApp.keyWindow;
    return nil;
}

// The window for a sheet, called at the click: the one under the pointer
// (the menu was opened there, and right-clicking a window that is not key
// does not make it key), else activeSheetHost(); nil when none can take a
// sheet now (the alert then runs app-modal).
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

void pickerReport(const std::shared_ptr<const PickerTestHooks> &test, const std::string &line) {
    if (test && test->report) test->report(line);
}

void pickerDone(const std::shared_ptr<const PickerTestHooks> &test) {
    if (test && test->done) test->done();
}

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
    pickerReport(flow->test, "no picker: " + cause + "; nothing assigned");
    pickerDone(flow->test);
}

// The sheet's OK, and the test aid's headless choice: the lane and the
// configuration again, then the assign on the captured roots.
std::string assignChosen(const ActionEntry &entry, const std::string &collection) {
    const std::string why = whyNotStartable();
    if (!why.empty()) return notRun(entry.action, why);
    ActionEntry chosen = entry;
    chosen.collection = collection;
    return runMutation(chosen, std::string());
}

std::string pickerSheetDescription(const PickerFlow &flow, NSComboBox *combo, NSButton *ok, bool sheet) {
    std::string line = sheet ? "sheet shown: " : "shown app-modal (no window could take a sheet): ";
    line += std::to_string(static_cast<long>(combo.numberOfItems)) + " collection(s), preselected \"" +
            StdStr(combo.stringValue) + "\", OK " + (ok.enabled ? "enabled" : "disabled");
    if (flow.test && flow.test->mode == PickerTestHooks::Mode::AutoClose) {
        char seconds[32];
        snprintf(seconds, sizeof seconds, "%g", flow.test->closeSeconds);
        line += std::string("; closing as Cancel in ") + seconds + " s";
    }
    return line;
}

// The test aid's AutoClose: Cancel after `seconds`. Common modes include
// the modal panel mode, so this also fires while the app-modal fallback
// runs.
void scheduleAutoCancel(JLIntakeCollectionPicker *helper, double seconds) {
    __weak JLIntakeCollectionPicker *weakHelper = helper;
    NSTimer *timer = [NSTimer timerWithTimeInterval:seconds
                                            repeats:NO
                                              block:^(NSTimer *) {
                                                  JLIntakeCollectionPicker *h = weakHelper;
                                                  if (h != nil && !h.closed) [h.cancelButton performClick:nil];
                                              }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
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
    NSButton *cancel = [alert addButtonWithTitle:@"Cancel"];  // Escape (NSAlert's Cancel rule)

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
    helper.cancelButton = cancel;
    combo.delegate = helper;
    alert.accessoryView = combo;
    [alert layout];
    alert.window.initialFirstResponder = combo;
    [helper update];  // empty text: Assign starts disabled
    flow->alert = alert;
    flow->helper = helper;

    std::shared_ptr<PickerFlow> current = flow;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        JLIntakeCollectionPicker *h = current->helper;
        h.closed = YES;
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
        pickerDone(current->test);
    };

    const bool autoClose = flow->test && flow->test->mode == PickerTestHooks::Mode::AutoClose;
    // The window chosen at the click; if it can no longer take a sheet, the
    // main or key window as they are now.
    NSWindow *host = flow->hostWindow;
    if (!usableSheetHost(host)) host = activeSheetHost();
    if (host != nil) {
        [alert beginSheetModalForWindow:host completionHandler:finish];
        if (autoClose) {
            pickerReport(flow->test, pickerSheetDescription(*flow, combo, ok, true));
            scheduleAutoCancel(helper, flow->test->closeSeconds);
        }
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
        if (autoClose) {
            pickerReport(current->test, pickerSheetDescription(*current, combo, ok, false));
            scheduleAutoCancel(helper, current->test->closeSeconds);
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
    if (flow->test && flow->test->mode == PickerTestHooks::Mode::Headless) {
        const std::string &name = flow->test->collection;
        const std::string *listed = listedCollectionFor(flow->names, name);
        std::string line = "collections: " + std::to_string(flow->names.size()) + "; \"" + name + "\" " +
                           (listed ? "listed" : "not listed");
        endPicker(flow);
        line += "; " + (listed ? assignChosen(flow->entry, *listed) : std::string("nothing assigned"));
        pickerReport(flow->test, line);
        pickerDone(flow->test);
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
    std::shared_ptr<const ExecuteTestHooks> test;
    // The sheet's window, chosen at the click (as for the picker).
    __weak NSWindow *hostWindow = nil;
    uint64_t laneToken = 0;  // the dry run's
    ExecutePlan plan;
    // While the sheet is up (released on a later main-queue turn).
    NSAlert *alert = nil;
    bool closed = false;
};

void execReport(const std::shared_ptr<const ExecuteTestHooks> &test, const std::string &line) {
    if (test && test->report) test->report(line);
}

void execDone(const std::shared_ptr<const ExecuteTestHooks> &test) {
    if (test && test->done) test->done();
}

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

// Ends `flow` early with the test aid's line.
void endExecuteFlowWith(std::shared_ptr<ExecuteFlow> flow, const std::string &line) {
    endExecuteFlow(flow);
    execReport(flow->test, line);
    execDone(flow->test);
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
// Returns the console line.
std::string applyRunResult(CliCommand command, const std::vector<MutationRoot> &roots, const EnvelopeResult &envelope) {
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
    return summary.outcome.consoleLine;
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

RunTestReport takeRunReport(const std::string &stem) {
    ActionsState &st = actionsState();
    RunTestReport report;
    auto it = st.runReports.find(stem);
    if (it != st.runReports.end()) {
        report = std::move(it->second);
        st.runReports.erase(it);
    }
    return report;
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
    RunTestReport report = takeRunReport(stem);
    const std::string line = applyRunResult(run.command, runRoots(run.ids, run.rootPaths), envelope);
    st.tracker.remove(stem);
    releaseRunLaneIfIdle();
    deleteRunFilesLater(stem);
    if (report.hooks) {
        // Never spawned (a configuration that cannot run, a spawn failure).
        execReport(report.hooks, report.prefix + "not started: " + line);
        execDone(report.hooks);
    }
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
    RunTestReport report = takeRunReport(stem);
    if (report.hooks) {
        execReport(report.hooks, report.prefix + "started: pid " + std::to_string(pid) + ", " + where);
        execDone(report.hooks);
    }
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
    RunTestReport report = takeRunReport(stem);
    if (st.stopped) return;
    // A caller bug, not a root's error: no tooltip (as onRefused).
    logError(name + ": not started (" + refusal + ")");
    if (report.hooks) {
        execReport(report.hooks, report.prefix + "not started: " + refusal);
        execDone(report.hooks);
    }
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
// lane and the configuration first. `hooks` (the test aid) get the spawn
// line, after `prefix`.
std::string startDetachedRun(CliCommand command, const std::vector<ActionRoot> &roots,
                             std::shared_ptr<const ExecuteTestHooks> hooks, const std::string &prefix) {
    ActionsState &st = actionsState();
    const IntakeAction action = command == CliCommand::Resume ? IntakeAction::Resume : IntakeAction::Execute;
    auto refuse = [&](const std::string &why) {
        const std::string what = notRun(action, why);
        execReport(hooks, prefix + what);
        execDone(hooks);
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
    if (hooks) st.runReports[stem] = RunTestReport{hooks, prefix};
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

// The sheet's Execute, and the test aid's headless confirmation. The lane
// was free while the sheet was up, so roots that changed meanwhile (no
// longer approved, another target) are left out first, one Error line each
// (IntakeExecutePlan recheckPlaceable); then the lane and the configuration
// again (startDetachedRun).
void confirmExecute(const std::shared_ptr<ExecuteFlow> &flow, std::shared_ptr<const ExecuteTestHooks> hooks,
                    const std::string &prefix) {
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    const ExecuteRecheck recheck =
        recheckPlaceable(flow->plan, [&view](const std::string &id) -> const IntakeRecord * {
            return view ? view->snapshot().recordForId(id) : nullptr;
        });
    std::string pre = prefix;
    for (const auto &dropped : recheck.dropped) {
        logError("execute: " + dropped.first + " left out: " + dropped.second);
        pre += dropped.first + " left out: " + dropped.second + "; ";
    }
    if (recheck.keep.empty()) {
        const std::string what = notRun(IntakeAction::Execute, "every root changed while the sheet was open");
        execReport(hooks, pre + what);
        execDone(hooks);
        logDebug("execute: " + what);
        return;
    }
    const std::string what = startDetachedRun(CliCommand::Execute, recheck.keep, hooks, pre);
    logDebug("execute: " + what);
}

std::string executeSheetDescription(const ExecuteFlow &flow, bool sheet) {
    std::string line = sheet ? "sheet shown: " : "shown app-modal (no window could take a sheet): ";
    line += "\"" + executeSheetTitle(flow.plan) + "\"; " + executeSheetSummary(flow.plan) +
            "; buttons Execute, Cancel";
    if (flow.test && flow.test->mode == ExecuteTestHooks::Mode::AutoClose) {
        char seconds[32];
        snprintf(seconds, sizeof seconds, "%g", flow.test->closeSeconds);
        line += std::string("; closing as Cancel in ") + seconds + " s";
    }
    return line;
}

// The test aid's AutoClose: Cancel after `seconds` (common modes include
// the modal panel mode, so this also fires while the app-modal fallback
// runs).
void scheduleExecuteCancel(std::shared_ptr<ExecuteFlow> flow, NSButton *cancel, double seconds) {
    __weak NSButton *weakCancel = cancel;
    NSTimer *timer = [NSTimer timerWithTimeInterval:seconds
                                            repeats:NO
                                              block:^(NSTimer *) {
                                                  NSButton *button = weakCancel;
                                                  if (button != nil && !flow->closed) [button performClick:nil];
                                              }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

void showExecuteSheet(const std::shared_ptr<ExecuteFlow> &flow) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSStr(executeSheetTitle(flow->plan));
    alert.informativeText = NSStr(executeSheetText(flow->plan));
    [alert addButtonWithTitle:@"Execute"];
    NSButton *cancel = [alert addButtonWithTitle:@"Cancel"];  // Escape (NSAlert's Cancel rule)
    flow->alert = alert;

    std::shared_ptr<ExecuteFlow> current = flow;
    const bool autoClose = flow->test && flow->test->mode == ExecuteTestHooks::Mode::AutoClose;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        current->closed = true;
        endExecuteFlow(current);
        if (actionsState().stopped) return;  // quit started: drop it
        if (response != NSAlertFirstButtonReturn) {
            logDebug("execute: cancelled in the sheet");
        } else {
            // The lane and the configuration again (startDetachedRun).
            confirmExecute(current, nullptr, std::string());
        }
        execDone(current->test);
    };
    // The window chosen at the click; if it can no longer take a sheet, the
    // main or key window as they are now.
    NSWindow *host = flow->hostWindow;
    if (!usableSheetHost(host)) host = activeSheetHost();
    if (host != nil) {
        [alert beginSheetModalForWindow:host completionHandler:finish];
        if (autoClose) {
            execReport(flow->test, executeSheetDescription(*flow, true));
            scheduleExecuteCancel(flow, cancel, flow->test->closeSeconds);
        }
        return;
    }
    // App-modal from a run-loop callout, never inside this main-queue block
    // (see showPicker: the main queue must keep draining while it is up).
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        if (actionsState().stopped) {
            endExecuteFlow(current);
            return;
        }
        if (autoClose) {
            execReport(current->test, executeSheetDescription(*current, false));
            scheduleExecuteCancel(current, cancel, current->test->closeSeconds);
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
    if (flow->test && flow->test->mode == ExecuteTestHooks::Mode::Headless) {
        endExecuteFlow(flow);
        confirmExecute(flow, flow->test, "dry run: " + executeSheetSummary(flow->plan) + "; confirmed; ");
        return;
    }
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
        endExecuteFlowWith(flow, "dry run: " + executeSheetSummary(plan) + "; no sheet, nothing executed");
        return;
    }
    logDebug(std::string(kExecuteDryRunName) + ": " + executeSheetSummary(plan));
    if (flow->test && flow->test->mode == ExecuteTestHooks::Mode::Headless) {
        // The test aid: what the sheet would list, then Execute.
        endExecuteFlow(flow);
        confirmExecute(flow, flow->test, "dry run: " + executeSheetSummary(plan) + "; confirmed; ");
        return;
    }
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
                endExecuteFlowWith(main.executeFlow, "not started: " + refusal);
            }
        });
    }
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
    std::vector<std::function<void()>> waiting = std::move(st.afterRunScan);
    st.afterRunScan.clear();
    for (std::function<void()> &fn : waiting) fn();
}

} // anonymous namespace

std::string actionsAssignOther(const ActionEntry &entry, std::shared_ptr<const PickerTestHooks> test) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    auto endNow = [&test](const std::string &what) {
        pickerReport(test, what);
        pickerDone(test);
        return what;
    };
    if (!entry.enabled) return endNow("not run: the item is disabled");
    if (entry.roots.empty()) return endNow("not run: no qualifying root");
    if (st.picker) {
        logInfo("assign-other: the collection picker is already open or loading; this request is ignored");
        return endNow("ignored: the collection picker is already open or loading");
    }
    // No collections call (and no sheet) for an assign that could not start.
    const std::string why = whyNotStartable();
    if (!why.empty()) return endNow(notRun(entry.action, why));
    CliConfig config;
    if (!serviceMutationConfig(config)) {
        return endNow(notRun(entry.action, "intake is not running or has no CLI path"));
    }
    auto flow = std::make_shared<PickerFlow>();
    flow->serial = ++st.pickerSerial;
    flow->entry = entry;
    flow->test = std::move(test);
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

std::string actionsExecutePlacement(const ActionEntry &entry, std::shared_ptr<const ExecuteTestHooks> test) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    auto endNow = [&test](const std::string &what) {
        execReport(test, what);
        execDone(test);
        return what;
    };
    if (!entry.enabled) return endNow("not run: the item is disabled");
    if (entry.roots.empty()) return endNow("not run: no qualifying root");
    if (st.executeFlow) {
        logInfo("execute: the execute sheet is already open or its dry run is running; this request is ignored");
        return endNow("ignored: the execute sheet is already open or its dry run is running");
    }
    // No dry run (and no sheet) for a run that could not start.
    const std::string why = whyNotStartable();
    if (!why.empty()) return endNow(notRun(entry.action, why));
    CliRequest request;
    std::string refusal;
    if (!requestForEntry(entry, std::string(), request, &refusal)) return endNow(notRun(entry.action, refusal));
    request.dryRun = true;
    CliConfig config;
    if (!serviceMutationConfig(config)) {
        return endNow(notRun(entry.action, "intake is not running or has no CLI path"));
    }
    const uint64_t token = st.lane.acquire(laneHolderFor(request));
    if (token == 0) return endNow(notRun(entry.action, "another intake command is still running"));
    auto flow = std::make_shared<ExecuteFlow>();
    flow->serial = ++st.executeSerial;
    flow->entry = entry;
    flow->test = std::move(test);
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

std::string actionsResume(const ActionEntry &entry, std::shared_ptr<const ExecuteTestHooks> test) {
    ActionsState &st = actionsState();
    if (st.stopped) return "not run: intake is not running";
    if (!entry.enabled || entry.roots.empty()) {
        const std::string what = !entry.enabled ? "not run: the item is disabled" : "not run: no qualifying root";
        execReport(test, what);
        execDone(test);
        return what;
    }
    return startDetachedRun(CliCommand::Resume, entry.roots, std::move(test), std::string());
}

std::string actionsRunsDescription() {
    ActionsState &st = actionsState();
    std::string lane = st.lane.busy() ? std::string("busy (") + laneHolderName(st.lane.holder()) + ")" : "free";
    if (!st.runScanDone) return "the check for leftover runs has not finished; lane " + lane;
    std::string runs = st.tracker.empty() ? std::string("none")
                                          : std::to_string(st.tracker.size()) + " live: " + st.tracker.describe();
    return runs + "; lane " + lane;
}

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

void actionsAfterRunScan(std::function<void()> fn) {
    if (!fn) return;
    ActionsState &st = actionsState();
    if (st.stopped) return;
    if (st.runScanDone) {
        fn();
        return;
    }
    st.afterRunScan.push_back(std::move(fn));
}

RootErrorStore &actionsErrorStore() {
    static RootErrorStore *store = new RootErrorStore();  // leaked: read by the loader queue
    return *store;
}

bool actionsLaneBusy() {
    return actionsState().lane.busy();
}

ActionTable actionsTableFor(const std::vector<const IntakeRecord *> &roots, const IntakeView *view) {
    return buildActionTable(roots, liveContext(view), menuActions());
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
    ActionContext context = liveContext(view.get());
    // Rows left out may be other roots: no one-root quick assign.
    context.selectionIncomplete = budget.skipped() > 0;
    st.menuTable = buildActionTable(roots, context, menuActions());
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
    if (entry.action == IntakeAction::AssignOther) return actionsAssignOther(entry, nullptr);
    if (entry.action == IntakeAction::Execute) return actionsExecutePlacement(entry, nullptr);
    if (entry.action == IntakeAction::Resume) return actionsResume(entry, nullptr);
    // Propose, Approve, Assign to X (its collection is in the entry).
    return runMutation(entry, std::string());
}

void actionsShutdown() {
    ActionsState &st = actionsState();
    st.stopped = true;
    st.menuTable = ActionTable();
    // A running `collections` is killed; one not yet spawned never starts.
    st.pickerRunner.closeReadLane();
    // Detached runs keep running and keep their files (the next session
    // adopts or finishes them); only the watching stops.
    for (auto &watch : st.exitWatches) watch.second->cancel();
    st.exitWatches.clear();
    st.afterRunScan.clear();
}

} // namespace intake
