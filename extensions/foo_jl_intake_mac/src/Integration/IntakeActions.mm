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

    // Set once above, then read on the queue.
    dispatch_queue_t queue = nil;
    std::string outputDirectory;
    // Mutating calls only. Never cancelled: destroying or keeping it never
    // signals a process (IntakeProcess), so calls outlive on_quit.
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
    // Propose, Approve, Assign to X (its collection is in the entry).
    return runMutation(entry, std::string());
}

void actionsShutdown() {
    ActionsState &st = actionsState();
    st.stopped = true;
    st.menuTable = ActionTable();
    // A running `collections` is killed; one not yet spawned never starts.
    st.pickerRunner.closeReadLane();
}

} // namespace intake
