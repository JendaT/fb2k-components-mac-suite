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

#include "IntakeActivityHub.h"
#include "IntakeAutoScanDriver.h"
#include "IntakeConfig.h"
#include "IntakeDecoratorProvider.h"
#include "IntakeNativePath.h"
#include "IntakeService.h"
#include "IntakeSwap.h"

#include "../Core/IntakeActionTable.h"
#include "../Core/IntakeActivity.h"
#include "../Core/IntakeAssignPropose.h"
#include "../Core/IntakeAutoScanResult.h"
#include "../Core/IntakeCliRunner.h"
#include "../Core/IntakeCollectionSearch.h"
#include "../Core/IntakeCollections.h"
#include "../Core/IntakeErrorMap.h"
#include "../Core/IntakeExecuteFollowUp.h"
#include "../Core/IntakeExecutePlan.h"
#include "../Core/IntakeExecuteTracker.h"
#include "../Core/IntakeGcPlan.h"
#include "../Core/IntakeLog.h"
#include "../Core/IntakeMutationLane.h"
#include "../Core/IntakeMutationResult.h"
#include "../Core/IntakeRejectReason.h"
#include "../Core/IntakeSlowVolumeGuard.h"
#include "../Core/IntakeView.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <deque>
#include <memory>
#include <optional>
#include <unordered_map>
#include <unordered_set>

// The picker's search field and list (B7; search, sections and Recent since
// B13-lite). The list is visible from the start: "Suggested" (the selected
// roots' ranked[0]), "Recent" and "All collections" (IntakeCollectionSearch
// pickerRows); nothing is highlighted then, so no choice is made for the
// user. Typing filters it live into one ranked list and highlights the
// first match (pickerHighlight); the field keeps the typed text. Up and Down
// (keys stay in the field: the table never takes focus) or a click
// highlight a row and show its name in the field, selected, so typing
// replaces it. The highlighted row is the choice: Return or a double-click
// assigns it. "Assign" is enabled while a name row is highlighted, or the
// field holds a listed name (IntakeCollections listedCollectionFor);
// Escape cancels. ObjC classes share one namespace in the process, hence
// the component prefix.
static NSString *JLIntakeNSString(const std::string &s) {
    NSString *out = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

@interface JLIntakeCollectionPicker : NSObject <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, weak) NSTextField *field;
@property(nonatomic, weak) NSTableView *table;
@property(nonatomic, weak) NSButton *okButton;
@property(nonatomic, weak) NSButton *cancelButton;
- (instancetype)initWithNames:(const std::vector<std::string> &)names
                    suggested:(const std::vector<std::string> &)suggested
                       recent:(const std::vector<std::string> &)recent;
// Rebuilds the list for the field's text, highlights, updates Assign.
- (void)refresh;
// The choice: the highlighted name, else the listed name the field holds,
// else "".
- (std::string)chosenName;
- (void)rowDoubleClicked:(id)sender;
@end

@implementation JLIntakeCollectionPicker {
    std::vector<std::string> _names;
    std::vector<std::string> _suggested;
    std::vector<std::string> _recent;
    std::vector<intake::PickerRow> _rows;
    BOOL _selecting;  // the highlight is being moved from code, not by a click
}

- (instancetype)initWithNames:(const std::vector<std::string> &)names
                    suggested:(const std::vector<std::string> &)suggested
                       recent:(const std::vector<std::string> &)recent {
    if ((self = [super init])) {
        _names = names;
        _suggested = suggested;
        _recent = recent;
    }
    return self;
}

- (std::string)fieldText {
    const char *bytes = self.field.stringValue.UTF8String;
    return bytes ? std::string(bytes) : std::string();
}

- (BOOL)isNameRow:(NSInteger)row {
    return row >= 0 && static_cast<size_t>(row) < _rows.size() && !_rows[static_cast<size_t>(row)].header;
}

- (std::string)chosenName {
    const NSInteger row = self.table.selectedRow;
    if ([self isNameRow:row]) return _rows[static_cast<size_t>(row)].text;
    const std::string *exact = intake::listedCollectionFor(_names, [self fieldText]);
    return exact ? *exact : std::string();
}

- (void)updateOk {
    self.okButton.enabled = !self.chosenName.empty();
}

// Highlights `row` (none when it is not a name row). `showName`: the
// field shows the name, selected, so typing replaces it (a click, the
// arrows); a text change keeps the typed text.
- (void)highlightRow:(NSInteger)row showName:(BOOL)showName {
    _selecting = YES;
    if ([self isNameRow:row]) {
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:static_cast<NSUInteger>(row)]
                byExtendingSelection:NO];
        [self.table scrollRowToVisible:row];
    } else {
        [self.table deselectAll:nil];
    }
    _selecting = NO;
    if (showName && [self isNameRow:row]) {
        self.field.stringValue = JLIntakeNSString(_rows[static_cast<size_t>(row)].text);
        if (NSText *editor = [self.field currentEditor]) {
            editor.selectedRange = NSMakeRange(0, self.field.stringValue.length);
        }
    }
    [self updateOk];
}

- (void)refresh {
    const std::string text = [self fieldText];
    _rows = intake::pickerRows(_suggested, _recent, _names, text);
    _selecting = YES;
    [self.table reloadData];
    _selecting = NO;
    [self highlightRow:intake::pickerHighlight(_rows, _names, text) showName:NO];
}

- (void)moveHighlightBy:(NSInteger)step {
    const NSInteger count = static_cast<NSInteger>(_rows.size());
    const NSInteger row = self.table.selectedRow;
    for (NSInteger next = (row < 0 ? (step > 0 ? -1 : count) : row) + step; next >= 0 && next < count;
         next += step) {
        if ([self isNameRow:next]) {
            [self highlightRow:next showName:YES];
            return;
        }
    }
}

// --- the field ---

- (void)controlTextDidChange:(NSNotification *)notification {
    [self refresh];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command {
    if (command == @selector(moveDown:)) {
        [self moveHighlightBy:1];
        return YES;
    }
    if (command == @selector(moveUp:)) {
        [self moveHighlightBy:-1];
        return YES;
    }
    if (command == @selector(insertNewline:)) {
        if (self.okButton.enabled) [self.okButton performClick:nil];
        return YES;  // nothing chosen: Return does nothing
    }
    if (command == @selector(cancelOperation:)) {
        [self.cancelButton performClick:nil];
        return YES;
    }
    return NO;
}

// --- the list ---

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return static_cast<NSInteger>(_rows.size());
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    return row >= 0 && static_cast<size_t>(row) < _rows.size() && _rows[static_cast<size_t>(row)].header;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return [self isNameRow:row];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (row < 0 || static_cast<size_t>(row) >= _rows.size()) return nil;
    const intake::PickerRow &r = _rows[static_cast<size_t>(row)];
    NSString *identifier = r.header ? @"JLIntakePickerHeader" : @"JLIntakePickerName";
    NSTextField *label = [tableView makeViewWithIdentifier:identifier owner:self];
    if (label == nil) {
        label = [NSTextField labelWithString:@""];
        label.identifier = identifier;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        if (r.header) {
            label.font = [NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]];
            label.textColor = [NSColor secondaryLabelColor];
        }
    }
    label.stringValue = JLIntakeNSString(r.text);
    return label;
}

// A click (the table never has focus and the code's own moves are flagged,
// so nothing else reaches here): its row is the choice.
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_selecting) return;
    [self highlightRow:self.table.selectedRow showName:YES];
}

// A double-click on a name row assigns it.
- (void)rowDoubleClicked:(id)sender {
    const NSInteger row = self.table.clickedRow;
    if (![self isNameRow:row]) return;
    [self highlightRow:row showName:YES];
    if (self.okButton.enabled) [self.okButton performClick:nil];
}

@end

// The Reject… sheet's reason (IntakeRejectReason): a pop-up of presets
// above the free-text field. A preset shows its text in the field, which is
// disabled; "Other…" enables the field (and gives it the focus) for any
// text, keeping what was typed there in this sheet across preset switches.
@interface JLIntakeRejectReason : NSObject
@property(nonatomic, weak) NSPopUpButton *popup;
@property(nonatomic, weak) NSTextField *field;
// The field for the pop-up's current choice; call once both are set.
- (void)start;
- (void)choiceChanged:(id)sender;
- (size_t)choice;
// The reason to send: the preset's text, or the free text trimmed.
- (std::string)reason;
@end

@implementation JLIntakeRejectReason {
    std::string _otherText;  // typed under Other… in this sheet
    size_t _shown;           // the choice the field shows
}

- (size_t)choice {
    const NSInteger index = self.popup.indexOfSelectedItem;
    return index < 0 ? intake::rejectReasonOtherIndex() : static_cast<size_t>(index);
}

- (std::string)fieldText {
    const char *bytes = self.field.stringValue.UTF8String;
    return bytes ? std::string(bytes) : std::string();
}

- (void)showChoice:(BOOL)focus {
    _shown = [self choice];
    if (intake::rejectChoiceIsOther(_shown)) {
        self.field.enabled = YES;
        self.field.stringValue = JLIntakeNSString(_otherText);
        if (focus && self.field.window != nil) [self.field.window makeFirstResponder:self.field];
    } else {
        self.field.enabled = NO;
        self.field.stringValue = JLIntakeNSString(intake::rejectReasonChoices()[_shown]);
    }
}

- (void)start {
    [self showChoice:NO];
}

- (void)choiceChanged:(id)sender {
    if (intake::rejectChoiceIsOther(_shown)) _otherText = [self fieldText];
    [self showChoice:YES];
}

- (std::string)reason {
    const size_t c = [self choice];
    return intake::rejectReasonFor(c, intake::rejectChoiceIsOther(c) ? [self fieldText] : std::string());
}

@end

// The Execute sheet's follow-ups (IntakeExecuteFollowUp), its accessory
// view: "Swap playlist rows to the library copies when done" and, indented
// under it, "Then delete the local copies", enabled only while the first is
// ticked and shown unticked while disabled (followUpCheckboxes); ticking
// the first again brings back the second's tick. The second always starts
// unticked (never saved).
@interface JLIntakeExecuteFollowUps : NSObject
@property(nonatomic, strong, readonly) NSView *view;
- (instancetype)initWithSwap:(BOOL)swap;
- (void)swapChanged:(id)sender;
- (void)deleteChanged:(id)sender;
// The choice the run records (chosenFollowUps).
- (intake::RunFollowUps)choice;
@end

@implementation JLIntakeExecuteFollowUps {
    NSButton *_swapBox;
    NSButton *_deleteBox;
    BOOL _deleteWanted;  // the delete tick, kept while swap is unticked
}

- (instancetype)initWithSwap:(BOOL)swap {
    if ((self = [super init])) {
        _deleteWanted = NO;
        _swapBox = [NSButton checkboxWithTitle:@"Swap playlist rows to the library copies when done"
                                        target:self
                                        action:@selector(swapChanged:)];
        _deleteBox = [NSButton checkboxWithTitle:@"Then delete the local copies"
                                          target:self
                                          action:@selector(deleteChanged:)];
        [_swapBox sizeToFit];
        [_deleteBox sizeToFit];
        const CGFloat indent = 18, gap = 6;
        const CGFloat swapHeight = NSHeight(_swapBox.frame), deleteHeight = NSHeight(_deleteBox.frame);
        const CGFloat width = MAX(NSWidth(_swapBox.frame), indent + NSWidth(_deleteBox.frame));
        _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, swapHeight + gap + deleteHeight)];
        [_swapBox setFrameOrigin:NSMakePoint(0, deleteHeight + gap)];
        [_deleteBox setFrameOrigin:NSMakePoint(indent, 0)];
        [_view addSubview:_swapBox];
        [_view addSubview:_deleteBox];
        _swapBox.state = swap ? NSControlStateValueOn : NSControlStateValueOff;
        [self show];
    }
    return self;
}

- (void)show {
    const intake::FollowUpCheckboxes boxes =
        intake::followUpCheckboxes(_swapBox.state == NSControlStateValueOn, _deleteWanted);
    _deleteBox.enabled = boxes.deleteEnabled;
    _deleteBox.state = boxes.deleteOn ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)swapChanged:(id)sender {
    [self show];
}

- (void)deleteChanged:(id)sender {
    _deleteWanted = _deleteBox.state == NSControlStateValueOn;
}

- (intake::RunFollowUps)choice {
    return intake::chosenFollowUps(_swapBox.state == NSControlStateValueOn,
                                   _deleteBox.enabled && _deleteBox.state == NSControlStateValueOn);
}

@end

namespace intake {

namespace {

NSString *NSStr(const std::string &s) {
    NSString *out = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

std::string rootCountText(size_t n) {
    return std::to_string(n) + (n == 1 ? " root" : " roots");
}

std::string idList(const std::vector<std::string> &ids) {
    std::string out;
    for (const std::string &id : ids) out += (out.empty() ? "" : " ") + id;
    return out;
}

// B14: the status-bar result of an operation that did not start (a caller
// bug or a run file that could not be written; the console line says more).
ActivityResult activityNotStarted(const std::string &why) {
    ActivityResult r;
    r.succeeded = false;
    r.reason = "not started";
    r.detail = why;
    return r;
}

struct PickerFlow;
struct ExecuteFlow;
struct DeleteFlow;

// One ended run's follow-ups (IntakeExecuteFollowUp; main thread).
struct FollowUpJob {
    std::string stem;
    std::vector<std::string> ids;      // the run's roots
    RunFollowUps choice;               // from its run file
    bool earlierSession = false;       // adopted, or finished by the leftover scan
    std::vector<std::string> swapped;  // the roots the swap step took
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
    // B14: the status-bar result of the assign whose propose runs on
    // assignToken (0: none); that propose's end folds it in
    // (activityAfterAssign), so a partly failed assign never ends with the
    // check icon.
    uint64_t assignToken = 0;
    ActivityResult assignResult;
    // B12: the auto-scan holding the lane on autoScanToken (0: none), its
    // income's name for the lines and path for the auto-propose, and the
    // driver's `done`, called once when its run ends (endAutoScanRun).
    uint64_t autoScanToken = 0;
    std::string autoScanIncome;
    std::string autoScanIncomePath;
    std::function<void(AutoScanExit)> autoScanDone;
    // B12: the scan's status-bar result while the propose after it runs on
    // autoScanToken; that propose's end folds it in (activityAfterScan), so
    // a scan with errors never ends with the check icon.
    ActivityResult autoScanResult;
    // B12: the auto-scan mute (IntakeAutoScanDriver autoScanMuteGc) of the
    // gc holding the lane on gcMuteToken (0: none); gc's exit or refusal
    // ends it (endGcMute).
    uint64_t gcMuteToken = 0;
    uint64_t gcMute = 0;
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
    std::vector<std::function<void()>> afterRunScan;  // the test aid, B12's startup check (actionsAfterRunScan)
    // The Execute follow-ups of ended runs, queued once their reload is
    // back: one chain at a time (swap, then the delete census and gc), the
    // running one in followUpActive (null: none). The chain's gc holds the
    // lane with followUpGcToken (0: none); its end ends the chain and
    // starts the next.
    std::deque<std::shared_ptr<FollowUpJob>> followUps;
    std::shared_ptr<FollowUpJob> followUpActive;
    uint64_t followUpGcToken = 0;
    // Every follow-up job not finished yet, in the order the runs ended:
    // from followUpsAfterReload until its chain ends (endFollowUp) or its
    // reload failed (queueFollowUp). Their run files are already gone, so
    // actionsShutdown logs one Info line for each.
    std::vector<std::shared_ptr<FollowUpJob>> followUpsUnfinished;

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
    c.scanRunning = st.lane.scanRunning();
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
        if (st.lane.executeRunning()) return "another intake command is still running (execute)";
        if (st.lane.scanRunning()) return "a background scan is running";
        return "another intake command is still running";
    }
    return std::string();
}

// --- results (main) ---

// Where a call stands in its lane run. An assign from "Assign to X" or the
// picker is followed by `propose` for the roots that were resolved
// (IntakeAssignPropose), on the same lane token: the lane is held from the
// assign's start to the propose's end, and released on every other path.
// B12: an auto-scan is followed the same way by `propose` for the resolved
// roots it wrote (IntakeAutoScanResult proposeAfterScan); the scan itself
// runs outside startOnQueue (startAutoScanOnQueue), so only its propose is
// a LaneRun here.
enum class LaneRun {
    Single,             // one call: its finish releases the lane and refreshes
    AssignThenPropose,  // an assign; its finish may start the propose
    ProposeAfterAssign, // that propose; its finish (or refusal) ends the run
    ProposeAfterScan,   // B12: the propose after an auto-scan; its finish (or refusal) ends the run (endAutoScanRun)
};

void startOnQueue(uint64_t token, std::shared_ptr<const CliConfig> config, std::shared_ptr<const CliRequest> request,
                  std::shared_ptr<const std::vector<MutationRoot>> roots, LaneRun run = LaneRun::Single);

// The Execute follow-up's gc on `token` has ended (or never started): its
// chain ends (see the Execute follow-ups below).
void followUpGcEnded(uint64_t token);

// B14: the status-bar result of the propose after the assign on `token`,
// with the assign's result folded in (activityAfterAssign); `propose` alone
// when no assign result is kept for `token`.
ActivityResult afterAssignResult(uint64_t token, const ActivityResult &propose) {
    ActionsState &st = actionsState();
    if (st.assignToken != token) return propose;
    const ActivityResult assign = st.assignResult;
    st.assignToken = 0;
    st.assignResult = ActivityResult();
    return activityAfterAssign(assign, propose);
}

// B12: the status-bar result of the propose after the auto-scan on `token`,
// with the scan's result folded in (activityAfterScan); `propose` alone
// when `token` is not the auto-scan's.
ActivityResult afterScanResult(uint64_t token, const ActivityResult &propose) {
    ActionsState &st = actionsState();
    if (token == 0 || st.autoScanToken != token) return propose;
    return activityAfterScan(st.autoScanResult, propose);
}

// B12: every path that lets go of the auto-scan's lane token (see the
// auto-scan section below).
void endAutoScanRun(uint64_t token, const ActivityResult &activity, std::optional<size_t> count, AutoScanExit how,
                    bool refresh);

// The assign of an AssignThenPropose run finished (its errors and console
// line are already out): starts the propose on `token`, or releases the
// lane and refreshes once when there is nothing to propose or it cannot
// start. `assignResult`: the assign's status-bar result, the entry's end
// when no propose follows; a propose that follows renames the entry
// (AssignThenPropose), and its own finish or refusal ends it with the
// assign's result folded in (afterAssignResult).
void proposeAfterAssignOrEnd(uint64_t token, const std::vector<MutationRoot> &assigned, const CliResult &result,
                             const MutationOutcome &outcome, const ActivityResult &assignResult) {
    ActionsState &st = actionsState();
    const AssignFollowUp next =
        proposeAfterAssign(assigned, result.envelope.outcome, outcome, result.envelope.errors);
    if (!next.skippedLine.empty()) logDebug(next.skippedLine);
    auto endRun = [&st, token](const ActivityResult &activity) {
        st.lane.finish(token);
        activityEnd(activityLaneKey(token), activity);
        serviceRefreshAfterCommand();
    };
    if (next.propose.empty()) {
        endRun(assignResult);
        return;
    }
    CliConfig config;
    if (!serviceMutationConfig(config)) {
        logError("propose: not run after assign: intake is not running or has no CLI path");
        ActivityResult notStarted;
        notStarted.succeeded = false;
        notStarted.reason = "propose not started";
        notStarted.detail = "propose: not run after assign: intake is not running or has no CLI path";
        endRun(activityAfterAssign(assignResult, notStarted));
        return;
    }
    st.assignToken = token;
    st.assignResult = assignResult;
    CliRequest request;
    request.command = CliCommand::Propose;
    request.ids = next.propose;
    logInfo("propose: starting after assign for " + rootCountText(request.ids.size()) + ": " + idList(request.ids));
    activityRename(activityLaneKey(token), ActivityKind::AssignThenPropose, request.ids.size(),
                   next.roots.empty() ? activityLabelFor(request.ids.front())
                                      : activityLabelFor(next.roots.front().id, next.roots.front().rootPath));
    auto sharedConfig = std::make_shared<const CliConfig>(std::move(config));
    auto sharedRequest = std::make_shared<const CliRequest>(std::move(request));
    auto sharedRoots = std::make_shared<const std::vector<MutationRoot>>(next.roots);
    dispatch_async(st.queue, ^{
        startOnQueue(token, sharedConfig, sharedRequest, sharedRoots, LaneRun::ProposeAfterAssign);
    });
}

// B12: the gc on `token` has exited or was refused: its auto-scan mute
// ends. Any other token does nothing.
void endGcMute(uint64_t token) {
    ActionsState &st = actionsState();
    if (token == 0 || token != st.gcMuteToken) return;
    const uint64_t mute = st.gcMute;
    st.gcMuteToken = 0;
    st.gcMute = 0;
    autoScanUnmuteGc(mute);
}

void onBudget(uint64_t token, CliCommand command, const std::vector<MutationRoot> &roots, CliBudgetEvent event,
              LaneRun run = LaneRun::Single) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    if (run == LaneRun::ProposeAfterScan) {
        // B12: like the scan's own 10 s report: one Info line, no tooltip
        // and no refresh (the auto-scan's run reloads once, at its end);
        // its status-bar entry stays until it exits.
        if (token == st.autoScanToken) logInfo(autoScanProposeBudgetLine(st.autoScanIncome));
        return;
    }
    const std::string name = cliCommandName(command);
    // B14: the lane is released here for a dry run, but its status-bar entry
    // stays until the answer arrives (onExecuteDryRun, Q2); a real call
    // keeps running and keeps its entry.
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

void onFinished(uint64_t token, CliCommand command, const std::vector<MutationRoot> &roots, const CliResult &result,
                LaneRun run = LaneRun::Single) {
    ActionsState &st = actionsState();
    endGcMute(token);
    if (st.stopped) {
        // B12: only releases the lane after quit.
        if (run == LaneRun::ProposeAfterScan) {
            endAutoScanRun(token, ActivityResult(), std::nullopt, AutoScanExit::Finished, false);
            return;
        }
        // A run of two calls lets go of the lane here: no propose after quit.
        if (run != LaneRun::Single) st.lane.finish(token);
        return;
    }
    const std::string name = cliCommandName(command);
    logCliResult(result);
    // The assign of a two-call run keeps the lane for its propose (a real
    // assign is never released early: only dry runs are).
    const bool proposeNext = run == LaneRun::AssignThenPropose && command == CliCommand::Assign;
    const MutationOutcome outcome = summarizeMutation(command, roots, result.envelope);
    // B14: the status-bar result of this call (the entry of its lane token);
    // the propose after an assign folds in the assign's, the one after an
    // auto-scan the scan's.
    const ActivityResult own = activityResultFor(outcome, roots.size(), name);
    const ActivityResult activity = run == LaneRun::ProposeAfterAssign ? afterAssignResult(token, own)
                                    : run == LaneRun::ProposeAfterScan ? afterScanResult(token, own)
                                                                       : own;
    if (!proposeNext && !st.lane.finish(token)) {
        activityEnd(activityLaneKey(token), activity);
        logInfo(name + ": a late dry-run result was ignored");
        return;
    }
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
    // B12: everything the auto-scan's run logs is Info (its errors also
    // show as tooltips and in the status bar).
    if (outcome.isError && run != LaneRun::ProposeAfterScan) {
        logError(outcome.consoleLine);
    } else {
        logInfo(outcome.consoleLine);
    }
    if (proposeNext) {
        proposeAfterAssignOrEnd(token, roots, result, outcome, activity);  // one refresh, after the propose
        return;
    }
    if (run == LaneRun::ProposeAfterScan) {
        // The end of the auto-scan's run: its entry (the count stays the
        // propose's), one refresh, then the driver's exit.
        endAutoScanRun(token, activity, std::nullopt, AutoScanExit::Finished, true);
        return;
    }
    activityEnd(activityLaneKey(token), activity);
    serviceRefreshAfterCommand();
    followUpGcEnded(token);
}

void onRefused(uint64_t token, CliCommand command, const std::string &refusal, LaneRun run = LaneRun::Single) {
    ActionsState &st = actionsState();
    if (run == LaneRun::ProposeAfterScan) {
        // B12: Info, like the rest of the auto-scan's run (a caller bug, so
        // no tooltip); the scan before it did run, so the run still
        // refreshes once (after on_quit endAutoScanRun only frees the lane).
        if (!st.stopped && token != 0 && token == st.autoScanToken) {
            logInfo("propose: not started after auto-scan of " + st.autoScanIncome + " (" + refusal + ")");
        }
        endAutoScanRun(token, afterScanResult(token, activityNotStarted(refusal)), std::nullopt,
                       AutoScanExit::Finished, true);
        return;
    }
    endGcMute(token);
    st.lane.finish(token);
    const ActivityResult notStarted = activityNotStarted(refusal);
    activityEnd(activityLaneKey(token),
                run == LaneRun::ProposeAfterAssign ? afterAssignResult(token, notStarted) : notStarted);
    if (st.stopped) return;
    // The only console line for it (IntakeCliRunner logs it at Debug);
    // a caller bug, not a root's error, so no tooltip.
    logError(std::string(cliCommandName(command)) + ": not started (" + refusal + ")");
    // The assign before it did run: show what it changed.
    if (run == LaneRun::ProposeAfterAssign) serviceRefreshAfterCommand();
    followUpGcEnded(token);
}

// --- start (queue) ---

void startOnQueue(uint64_t token, std::shared_ptr<const CliConfig> config, std::shared_ptr<const CliRequest> request,
                  std::shared_ptr<const std::vector<MutationRoot>> roots, LaneRun run) {
    ActionsState &st = actionsState();
    CliRunOptions options;
    options.outputDirectory = st.outputDirectory;
    const CliCommand command = request->command;
    std::string refusal;
    const bool started = startCliCommand(
        st.runner, *config, *request, options, st.queue,
        [token, command, roots, run](CliBudgetEvent event) {
            dispatch_async(dispatch_get_main_queue(), ^{
                onBudget(token, command, *roots, event, run);
            });
        },
        [token, command, roots, run](CliResult &&result) {
            auto shared = std::make_shared<CliResult>(std::move(result));
            dispatch_async(dispatch_get_main_queue(), ^{
                onFinished(token, command, *roots, *shared, run);
            });
        },
        &refusal);
    if (!started) {
        dispatch_async(dispatch_get_main_queue(), ^{
            onRefused(token, command, refusal, run);
        });
    }
}

// --- auto-scan (B12, main unless noted) ---

// Every path that lets go of the auto-scan's lane token: releases the lane,
// ends its status-bar entry (`count`: the roots it wrote, for the result
// text), asks for the refresh when a process ran (`refresh`), then hands
// the exit to the driver (its scheduler's exit and next wakeup). After
// on_quit only the lane is released.
void endAutoScanRun(uint64_t token, const ActivityResult &activity, std::optional<size_t> count, AutoScanExit how,
                    bool refresh) {
    ActionsState &st = actionsState();
    st.lane.finish(token);
    if (token == 0 || token != st.autoScanToken) return;
    std::function<void(AutoScanExit)> done = std::move(st.autoScanDone);
    st.autoScanToken = 0;
    st.autoScanIncome.clear();
    st.autoScanIncomePath.clear();
    st.autoScanDone = nullptr;
    st.autoScanResult = ActivityResult();
    activityEnd(activityLaneKey(token), activity, count);
    if (st.stopped) return;
    if (refresh) serviceRefreshAfterCommand();
    if (done) done(how);
}

// The scan on `token` finished (exit Finished: any envelope outcome but
// E_NO_CLI and the cap kill) and its line is out. PLAN-B12 scope addition
// 1: `propose` for the resolved roots it wrote (proposeAfterScan) on the
// same token, like the propose after an assign (proposeAfterAssignOrEnd):
// the lane (still LaneHolder::Scan, so the menu keeps " (scan running)")
// and the status-bar entry (renamed ScanThenPropose) are kept until that
// propose's finish or refusal ends the run with the scan's result folded
// in (afterScanResult). When there is nothing to propose, or it cannot
// start, the run ends here. Either way one refresh, at the end.
void proposeAfterScanOrEnd(uint64_t token, const AutoScanOutcome &outcome, CliOutcome scanOutcome) {
    ActionsState &st = actionsState();
    const ScanFollowUp next = proposeAfterScan(st.autoScanIncome, st.autoScanIncomePath, scanOutcome, outcome.reply);
    if (!next.skippedLine.empty()) logDebug(next.skippedLine);
    if (next.propose.empty()) {
        endAutoScanRun(token, outcome.activity, outcome.newRoots, outcome.exit, true);
        return;
    }
    // Like a user's propose: nothing mutating goes to the CLI when the
    // provider went inert while the scan ran.
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    CliConfig config;
    std::string why;
    if (view && view->isInert()) {
        why = "intake is inert: " + view->inertReason();
    } else if (!serviceMutationConfig(config)) {
        why = "intake is not running or has no CLI path";
    }
    if (!why.empty()) {
        const std::string line = "propose: not run after auto-scan of " + st.autoScanIncome + ": " + why;
        logInfo(line);
        ActivityResult notStarted = activityNotStarted(line);
        notStarted.kind = ActivityKind::Propose;  // the entry is still the scan's
        endAutoScanRun(token, activityAfterScan(outcome.activity, notStarted), outcome.newRoots, outcome.exit, true);
        return;
    }
    st.autoScanResult = outcome.activity;
    CliRequest request;
    request.command = CliCommand::Propose;
    request.ids = next.propose;
    logInfo(autoScanProposeStartLine(st.autoScanIncome, request.ids));
    activityRename(activityLaneKey(token), ActivityKind::ScanThenPropose, request.ids.size(), st.autoScanIncome);
    auto sharedConfig = std::make_shared<const CliConfig>(std::move(config));
    auto sharedRequest = std::make_shared<const CliRequest>(std::move(request));
    auto sharedRoots = std::make_shared<const std::vector<MutationRoot>>(next.roots);
    dispatch_async(st.queue, ^{
        startOnQueue(token, sharedConfig, sharedRequest, sharedRoots, LaneRun::ProposeAfterScan);
    });
}

void onAutoScanBudget(uint64_t token) {
    ActionsState &st = actionsState();
    if (st.stopped || token == 0 || token != st.autoScanToken) return;
    // doc 03 "Timeouts": E_CLI_TIMEOUT is reported and the scan goes on.
    // No tooltip (a scan names no roots), no refresh, no Error line; its
    // status-bar entry stays until it exits.
    logInfo(autoScanBudgetLine(st.autoScanIncome));
}

void onAutoScanFinished(uint64_t token, const CliResult &result) {
    ActionsState &st = actionsState();
    if (st.stopped || token == 0 || token != st.autoScanToken) {
        // After on_quit the result is dropped (the lane is still released).
        endAutoScanRun(token, ActivityResult(), std::nullopt, AutoScanExit::Finished, false);
        return;
    }
    logCliResult(result);
    const AutoScanOutcome outcome = autoScanOutcome(st.autoScanIncome, result);
    logInfo(outcome.line);
    if (outcome.exit != AutoScanExit::Finished) {
        // E_NO_CLI or the cap kill: nothing to propose.
        endAutoScanRun(token, outcome.activity, outcome.newRoots, outcome.exit, true);
        return;
    }
    proposeAfterScanOrEnd(token, outcome, result.envelope.outcome);
}

// startCliCommand refused the request (nothing ran: no refresh).
void onAutoScanRefused(uint64_t token, const std::string &refusal) {
    ActionsState &st = actionsState();
    if (!st.stopped && token != 0 && token == st.autoScanToken) {
        logInfo("auto-scan: " + st.autoScanIncome + " not started (" + refusal + ")");
    }
    endAutoScanRun(token, activityNotStarted(refusal), std::nullopt, AutoScanExit::Refused, false);
}

// Queue: starts the scan like startOnQueue, with the auto-scan's own budget
// handler and completion.
void startAutoScanOnQueue(uint64_t token, std::shared_ptr<const CliConfig> config,
                          std::shared_ptr<const CliRequest> request) {
    ActionsState &st = actionsState();
    CliRunOptions options;
    options.outputDirectory = st.outputDirectory;
    std::string refusal;
    const bool started = startCliCommand(
        st.runner, *config, *request, options, st.queue,
        [token](CliBudgetEvent) {
            dispatch_async(dispatch_get_main_queue(), ^{
                onAutoScanBudget(token);
            });
        },
        [token](CliResult &&result) {
            auto shared = std::make_shared<CliResult>(std::move(result));
            dispatch_async(dispatch_get_main_queue(), ^{
                onAutoScanFinished(token, *shared);
            });
        },
        &refusal);
    if (!started) {
        dispatch_async(dispatch_get_main_queue(), ^{
            onAutoScanRefused(token, refusal);
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

// `heldToken` (the Execute follow-up's gc): a lane token the caller already
// holds, used instead of taking one; it is released on every path that
// starts nothing.
std::string runMutation(const ActionEntry &entry, const std::string &reason, uint64_t heldToken = 0) {
    ActionsState &st = actionsState();
    auto refuse = [&](const std::string &why) {
        if (heldToken != 0) st.lane.finish(heldToken);
        return notRun(entry.action, why);
    };
    if (st.stopped) {
        if (heldToken != 0) st.lane.finish(heldToken);
        return "not run: intake is not running";
    }
    CliRequest request;
    std::string why;
    if (!requestForEntry(entry, reason, request, &why)) return refuse(why);
    CliConfig config;
    if (!serviceMutationConfig(config)) return refuse("intake is not running or has no CLI path");
    if (!st.runScanDone) {
        return refuse("intake is still checking for an execute run left by an earlier session");
    }
    const std::string name = cliCommandName(request.command);
    const uint64_t token = heldToken != 0 ? heldToken : st.lane.acquire(laneHolderFor(request));
    if (token == 0) {
        if (st.lane.scanRunning()) return notRun(entry.action, "a background scan is running");
        return notRun(entry.action, st.lane.executeRunning() ? "another intake command is still running (execute)"
                                                             : "another intake command is still running");
    }
    auto roots = std::make_shared<std::vector<MutationRoot>>();
    const bool gc = request.command == CliCommand::Gc;
    std::string firstLabel;  // the status bar's album for one root
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
        if (firstLabel.empty()) firstLabel = albumLabel(r);
    }
    logInfo(name + ": starting for " + rootCountText(request.ids.size()) + ": " + idList(request.ids) +
            (request.collection.empty() ? std::string() : " to \"" + request.collection + "\"") +
            (request.reason.empty() ? std::string() : " (with a reason)"));
    // B14: the status bar's entry for this lane token, from here to every
    // path that releases it (onFinished, onRefused, proposeAfterAssignOrEnd).
    ActivityKind kind = ActivityKind::Propose;
    if (activityKindFor(request.command, request.dryRun, kind)) {
        activityBegin(activityLaneKey(token), kind, request.ids.size(), firstLabel);
    }
    if (gc) {
        // B12: gc's renames in income folders are no arrivals for the
        // auto-scan: muted from before it is dispatched until it exits or
        // is refused (onFinished, onRefused). The Execute follow-up's gc
        // (heldToken) comes through here too.
        std::vector<std::string> rootPaths;
        for (const MutationRoot &r : *roots) rootPaths.push_back(r.rootPath);
        const uint64_t mute = autoScanMuteGc(rootPaths);
        if (mute != 0) {
            st.gcMuteToken = token;
            st.gcMute = mute;
        }
    }
    auto sharedConfig = std::make_shared<const CliConfig>(std::move(config));
    auto sharedRequest = std::make_shared<const CliRequest>(request);
    std::shared_ptr<const std::vector<MutationRoot>> sharedRoots = roots;
    // Assign to X and the picker's Assign: propose follows for resolved roots.
    const LaneRun run = request.command == CliCommand::Assign ? LaneRun::AssignThenPropose : LaneRun::Single;
    dispatch_async(st.queue, ^{
        startOnQueue(token, sharedConfig, sharedRequest, sharedRoots, run);
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

// The Reject… sheet's last confirmed reason choice, for this session only
// (no setting): SIZE_MAX until the first confirmed Reject, so the first
// sheet opens on "Already in library" (rejectInitialChoice). Main thread.
size_t g_lastRejectChoice = SIZE_MAX;

// Reject…: the confirmation (doc 04 v1.2, confirm_reject), with the reason
// pop-up (IntakeRejectReason) above the free-text field.
void confirmReject(const ActionEntry &entry) {
    const size_t n = entry.roots.size();
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = n == 1 ? @"Reject this album?" : [NSString stringWithFormat:@"Reject %zu albums?", n];
    alert.informativeText = [NSString
        stringWithFormat:@"%@\n\nReject only changes the intake state. No files are deleted.",
                         NSStr(affectedAlbumsText(entry.roots))];
    [alert addButtonWithTitle:@"Reject"];   // Return
    [alert addButtonWithTitle:@"Cancel"];   // Escape

    const CGFloat width = 320, popupHeight = 26, gap = 8, fieldHeight = 22;
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, popupHeight + gap + fieldHeight)];
    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(-3, fieldHeight + gap, width + 6, popupHeight)
                                                      pullsDown:NO];
    for (const std::string &title : rejectReasonChoices()) [popup addItemWithTitle:NSStr(title)];
    popup.accessibilityLabel = @"Reason";
    const size_t initial = rejectInitialChoice(g_lastRejectChoice);
    [popup selectItemAtIndex:static_cast<NSInteger>(initial)];
    NSTextField *reasonField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, width, fieldHeight)];
    reasonField.placeholderString = @"Reason (optional)";
    reasonField.accessibilityLabel = @"Reason for rejecting";
    reasonField.usesSingleLineMode = YES;
    [box addSubview:popup];
    [box addSubview:reasonField];
    JLIntakeRejectReason *reason = [[JLIntakeRejectReason alloc] init];
    reason.popup = popup;
    reason.field = reasonField;
    popup.target = reason;
    popup.action = @selector(choiceChanged:);
    [reason start];
    alert.accessoryView = box;
    [alert layout];
    // Other…: typing at once; a preset: the pop-up (keyboard navigation
    // permitting). Return rejects and Escape cancels either way.
    alert.window.initialFirstResponder = rejectChoiceIsOther(initial) ? (NSView *)reasonField : (NSView *)popup;

    const ActionEntry captured = entry;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) {
            logDebug("reject: cancelled in the confirmation");
            return;
        }
        g_lastRejectChoice = [reason choice];
        // runMutation logs an Error line when it cannot start (the lane or
        // the CLI path changed while the alert was open).
        const std::string what = runMutation(captured, [reason reason]);
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

// The user confirmed Assign to `chosen`: it goes to the front of the
// hidden recent_collections list (IntakeCollectionSearch), which drops the
// names no longer listed and keeps at most five.
void rememberRecentCollection(const std::string &chosen, const std::vector<std::string> &names) {
    const std::vector<std::string> stored =
        parseRecentCollections(config::getString(config::kRecentCollections, ""));
    config::setString(config::kRecentCollections,
                      formatRecentCollections(updateRecentCollections(stored, chosen, names)));
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

    // A search field over the list (NSComboBox completes by prefix only,
    // and every collection name starts with "[").
    const CGFloat width = 380, fieldHeight = 24, gap = 8, listHeight = 12 * 22 + 4;  // about 12 rows
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, fieldHeight + gap + listHeight)];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, listHeight + gap, width, fieldHeight)];
    field.placeholderString = @"Search collections";
    field.accessibilityLabel = @"Search collections";
    field.usesSingleLineMode = YES;
    field.cell.wraps = NO;
    field.cell.scrollable = YES;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, width, listHeight)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;
    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.contentView.bounds];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    column.width = width - 4;
    [table addTableColumn:column];
    table.headerView = nil;
    table.style = NSTableViewStylePlain;
    table.rowHeight = 20;
    table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    table.refusesFirstResponder = YES;  // keys stay in the field
    table.allowsEmptySelection = YES;
    table.accessibilityLabel = @"Collections";
    scroll.documentView = table;
    [box addSubview:field];
    [box addSubview:scroll];

    std::vector<std::string> topRanked;
    for (const ActionRoot &r : entry.roots) topRanked.push_back(r.topRanked);
    const std::vector<std::string> suggested = suggestedCollections(topRanked, flow->names);
    const std::vector<std::string> recent = shownRecentCollections(
        parseRecentCollections(config::getString(config::kRecentCollections, "")), flow->names);
    JLIntakeCollectionPicker *helper = [[JLIntakeCollectionPicker alloc] initWithNames:flow->names
                                                                             suggested:suggested
                                                                                recent:recent];
    helper.field = field;
    helper.table = table;
    helper.okButton = ok;
    helper.cancelButton = cancel;
    field.delegate = helper;
    table.dataSource = helper;
    table.delegate = helper;
    table.target = helper;
    table.doubleAction = @selector(rowDoubleClicked:);
    alert.accessoryView = box;
    [alert layout];
    alert.window.initialFirstResponder = field;
    [helper refresh];  // empty field: the sections, nothing highlighted, Assign disabled
    flow->alert = alert;
    flow->helper = helper;

    std::shared_ptr<PickerFlow> current = flow;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        // The highlighted name, else the listed name the field holds.
        const std::string text = [helper chosenName];
        endPicker(current);
        if (actionsState().stopped) return;  // quit started: drop it
        if (response != NSAlertFirstButtonReturn) {
            logDebug("assign-other: cancelled in the picker");
        } else if (const std::string *listed = listedCollectionFor(current->names, text)) {
            // The listed name's own bytes, never the typed text.
            rememberRecentCollection(*listed, current->names);
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
    JLIntakeExecuteFollowUps *followUps = nil;  // its checkboxes
};

// Ends `flow` if it is still the current one; its alert is released on a
// later main-queue turn. By value, as endPicker.
void endExecuteFlow(std::shared_ptr<ExecuteFlow> flow) {
    if (!flow) return;
    ActionsState &st = actionsState();
    if (st.executeFlow == flow) st.executeFlow.reset();
    dispatch_async(dispatch_get_main_queue(), ^{
        flow->alert = nil;
        flow->followUps = nil;
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

// A finished run's result: per-root errors, one console line, a refresh;
// `reloaded` (optional: the Execute follow-ups) runs on the main thread
// when that refresh has ended. Returns the summary (the status bar's
// result).
RunSummary applyRunResult(CliCommand command, const std::vector<MutationRoot> &roots, const EnvelopeResult &envelope,
                          std::function<void(const LoaderStatus &status)> reloaded = nullptr) {
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
    serviceRefreshAfterCommand(std::move(reloaded));
    return summary;
}

void queueFollowUp(std::shared_ptr<FollowUpJob> job, const LoaderStatus &status);

// What applyRunResult waits for when an execute run has follow-ups (null:
// none): their job, queued once the reload after the run is back. From
// here the job counts as unfinished (followUpsUnfinished).
std::function<void(const LoaderStatus &)> followUpsAfterReload(const std::string &stem, CliCommand command,
                                                               const std::vector<std::string> &ids,
                                                               const RunFollowUps &choice, bool earlierSession) {
    if (command != CliCommand::Execute || !hasFollowUps(choice)) return nullptr;
    auto job = std::make_shared<FollowUpJob>();
    job->stem = stem;
    job->ids = ids;
    job->choice = choice;
    job->earlierSession = earlierSession;
    actionsState().followUpsUnfinished.push_back(job);
    return [job](const LoaderStatus &status) { queueFollowUp(job, status); };
}

// `job` is finished (its chain ended, or its reload failed): no line for
// it at quit.
void forgetFollowUp(const std::shared_ptr<FollowUpJob> &job) {
    std::vector<std::shared_ptr<FollowUpJob>> &unfinished = actionsState().followUpsUnfinished;
    unfinished.erase(std::remove(unfinished.begin(), unfinished.end(), job), unfinished.end());
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

// A tracked run has ended (own or adopted) with `envelope`: apply it (its
// follow-ups wait for the reload after it), forget the run, release the
// lane when it was the last, delete its files.
void finishRun(const std::string &stem, const EnvelopeResult &envelope, bool adopted) {
    ActionsState &st = actionsState();
    if (st.stopped) return;  // the files stay: the next session finishes it
    const TrackedRun *found = st.tracker.find(stem);
    if (found == nullptr) return;
    const TrackedRun run = *found;
    st.exitWatches.erase(stem);
    const std::vector<MutationRoot> roots = runRoots(run.ids, run.rootPaths);
    const RunSummary summary = applyRunResult(run.command, roots, envelope,
                                              followUpsAfterReload(stem, run.command, run.ids, run.followUps, adopted));
    st.tracker.remove(stem);
    activityEnd(activityRunKey(stem), activityResultFor(summary.outcome, roots.size(), cliCommandName(run.command)));
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
    finishRun(stem, result.envelope, false);
}

void onRunRefused(const std::string &stem, const std::string &refusal) {
    ActionsState &st = actionsState();
    const TrackedRun *run = st.tracker.find(stem);
    const std::string name = run != nullptr ? cliCommandName(run->command) : "execute";
    st.tracker.remove(stem);
    activityEnd(activityRunKey(stem), activityNotStarted(refusal));
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
                     std::shared_ptr<const std::vector<std::string>> rootPaths, RunFollowUps followUps) {
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
    provisional.followUps = followUps;  // the Execute sheet's choice, from the start
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
// lane and the configuration first. `followUps`: the Execute sheet's choice
// (a resume has none).
std::string startDetachedRun(CliCommand command, const std::vector<ActionRoot> &roots,
                             RunFollowUps followUps = RunFollowUps()) {
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
    st.tracker.begin(stem, command, request->ids, *rootPaths, followUps);
    // B14: the status bar's entry for this run, until finishRun or
    // onRunRefused; its n/m follows the published views.
    activityBeginRun(stem, command, request->ids, albumLabel(roots.front()));
    logInfo(std::string(cliCommandName(command)) + ": starting for " + rootCountText(request->ids.size()) + ": " +
            idList(request->ids) +
            (hasFollowUps(followUps) ? (followUps.deleteLocal ? " (then swap and delete)" : " (then swap)") : ""));
    std::shared_ptr<const CliConfig> sharedConfig = config;
    std::shared_ptr<const CliRequest> sharedRequest = request;
    std::shared_ptr<const std::vector<std::string>> sharedPaths = rootPaths;
    dispatch_async(st.queue, ^{
        startRunOnQueue(stem, sharedConfig, sharedRequest, sharedPaths, followUps);
    });
    return "starting for " + rootCountText(request->ids.size());
}

// The sheet's Execute. The lane was free while the sheet was up, so roots
// that changed meanwhile (no longer approved, another target) are left out
// first, one Error line each (IntakeExecutePlan recheckPlaceable); then the
// lane and the configuration again (startDetachedRun), with the sheet's
// follow-ups.
void confirmExecute(const std::shared_ptr<ExecuteFlow> &flow, const RunFollowUps &followUps) {
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
    startDetachedRun(CliCommand::Execute, recheck.keep, followUps);  // logs its start or refusal
}

void showExecuteSheet(const std::shared_ptr<ExecuteFlow> &flow) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSStr(executeSheetTitle(flow->plan));
    alert.informativeText = NSStr(executeSheetText(flow->plan));
    [alert addButtonWithTitle:@"Execute"];
    [alert addButtonWithTitle:@"Cancel"];  // Escape (NSAlert's Cancel rule)
    // The follow-ups: swap as last confirmed (hidden configInt), delete
    // unticked.
    JLIntakeExecuteFollowUps *followUps = [[JLIntakeExecuteFollowUps alloc]
        initWithSwap:followUpSetting(config::getInt(config::kExecuteSwapAfter, kExecuteSwapAfterDefault))];
    alert.accessoryView = followUps.view;
    flow->alert = alert;
    flow->followUps = followUps;

    std::shared_ptr<ExecuteFlow> current = flow;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        const RunFollowUps choice = [current->followUps choice];
        endExecuteFlow(current);
        if (actionsState().stopped) return;  // quit started: drop it
        if (response != NSAlertFirstButtonReturn) {
            logDebug("execute: cancelled in the sheet");
        } else {
            config::setInt(config::kExecuteSwapAfter, choice.swap ? 1 : 0);  // delete is never saved
            // The lane and the configuration again (startDetachedRun).
            confirmExecute(current, choice);
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

void onExecuteDryRun(uint64_t serial, uint64_t token, const std::vector<MutationRoot> &roots, const CliResult &result) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    logCliResult(result);
    // B14: the dry run's entry ends with its answer, a late one included
    // (Q2: it shows until then, even after the 10 s report freed the lane).
    activityEnd(activityLaneKey(token),
                activityResultFor(summarizeMutation(CliCommand::Execute, roots, result.envelope, kExecuteDryRunName),
                                  roots.size(), kExecuteDryRunName));
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
        [serial, token, roots](CliResult &&result) {
            auto shared = std::make_shared<CliResult>(std::move(result));
            dispatch_async(dispatch_get_main_queue(), ^{
                onExecuteDryRun(serial, token, *roots, *shared);
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
    std::shared_ptr<const DeleteTestHooks> test;  // the test aid's delete-sheet step, else null
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
    bool closed = false;  // the sheet has ended (the test aid's timer then does nothing)
};

void deleteReport(const std::shared_ptr<const DeleteTestHooks> &test, const std::string &line) {
    if (test && test->report) test->report(line);
}

void deleteDone(const std::shared_ptr<const DeleteTestHooks> &test) {
    if (test && test->done) test->done();
}

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
                   " playlist row(s) on a slow volume or under a share link could not be checked";
        }
        notRun(IntakeAction::DeleteLocal, why + "; nothing deleted");
        endDeleteFlow(flow);
        return;
    }
    deleteConfirmed(flow);
}

// Swaps the playlist rows of `ids` that still point at their income paths,
// one playlist of `pending` after the other (each found again; gone or
// without such rows: skipped), then calls `done`. Used by "Swap, then
// delete" and by the Execute follow-ups.
struct SwapChain {
    std::unordered_set<std::string> ids;
    std::vector<PlaylistRef> pending;
    std::function<void()> done;
    // A swap did not start (another swap running, ...): true goes on with
    // the next playlist, false ends the chain there (`done` never runs).
    std::function<bool(const std::string &why)> notStarted;
};

// One step: the next playlist of `chain` from `next` on.
void swapChainNext(std::shared_ptr<SwapChain> chain, size_t next) {
    if (actionsState().stopped) return;
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    while (view && next < chain->pending.size()) {
        const t_size playlist = findPlaylist(chain->pending[next++]);
        if (playlist == SIZE_MAX) continue;
        NativePathMenuBudget budget;
        std::vector<SwapRow> rows = swapIncomeRows(playlist, chain->ids, *view, &budget);
        if (rows.empty()) continue;
        std::string why;
        const bool started = swapStart(
            playlist, std::move(rows), view, serviceActionInfo().libraryPrefix,
            [chain, next](const SwapResult &) {
                if (actionsState().stopped) return;
                swapChainNext(chain, next);
            },
            why);
        if (started) return;
        if (!chain->notStarted(why)) return;
    }
    chain->done();
}

// "Swap, then delete": the rows of these roots that still point at income
// paths are swapped, in the playlist the click came from first, then in
// every other playlist that holds such rows (a locked one keeps them); gc
// runs only when none is left anywhere afterwards and none was unchecked
// (deleteAfterSwapCheck). A swap that does not start ends the flow.
void deleteAfterSwap(std::shared_ptr<DeleteFlow> flow) {
    if (!flow->income.offerSwap()) {
        notRun(IntakeAction::DeleteLocal, "\"Swap, then delete\" was not offered; nothing deleted");
        endDeleteFlow(flow);
        return;
    }
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    auto chain = std::make_shared<SwapChain>();
    chain->ids = rootIdSet(flow->entry.roots);
    if (view) {
        IncomeRowCensus census;
        countIncomeRows(*view, chain->ids, flow->playlist, nullptr, &census);
        chain->pending = std::move(census.playlists);
    }
    chain->done = [flow] { deleteAfterSwapCheck(flow); };
    chain->notStarted = [flow](const std::string &why) {
        notRun(IntakeAction::DeleteLocal, "the swap did not start: " + why);
        endDeleteFlow(flow);
        return false;
    };
    swapChainNext(chain, 0);
}

// The test aid's line for the sheet it shows.
std::string deleteSheetDescription(const DeleteFlow &flow, bool sheet) {
    std::string line = sheet ? "sheet shown: " : "shown app-modal (no window could take a sheet): ";
    line += "\"" + gcConfirmTitle(flow.entry.roots.size()) + "\"; " + gcConfirmSummary(flow.confirm, flow.income) +
            "; buttons Delete, Cancel" + (flow.income.offerSwap() ? ", Swap, then delete" : "");
    if (flow.test) {
        char seconds[32];
        snprintf(seconds, sizeof seconds, "%g", flow.test->closeSeconds);
        line += std::string("; closing as Cancel in ") + seconds + " s";
    }
    return line;
}

// The test aid: Cancel after `seconds`. Common modes include the modal
// panel mode, so this also fires while the app-modal fallback runs.
void scheduleDeleteCancel(std::shared_ptr<DeleteFlow> flow, NSButton *cancel, double seconds) {
    __weak NSButton *weakCancel = cancel;
    NSTimer *timer = [NSTimer timerWithTimeInterval:seconds
                                            repeats:NO
                                              block:^(NSTimer *) {
                                                  NSButton *button = weakCancel;
                                                  if (button != nil && !flow->closed) [button performClick:nil];
                                              }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

void showDeleteSheet(const std::shared_ptr<DeleteFlow> &flow) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = NSStr(gcConfirmTitle(flow->entry.roots.size()));
    alert.informativeText = NSStr(gcConfirmText(flow->confirm, flow->income));
    NSButton *deleteButton = [alert addButtonWithTitle:@"Delete"];
    if ([deleteButton respondsToSelector:@selector(setHasDestructiveAction:)]) deleteButton.hasDestructiveAction = YES;
    NSButton *cancel = [alert addButtonWithTitle:@"Cancel"];  // Escape (NSAlert's Cancel rule)
    if (flow->income.offerSwap()) [alert addButtonWithTitle:@"Swap, then delete"];
    flow->alert = alert;

    std::shared_ptr<DeleteFlow> current = flow;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        current->closed = true;
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
        // The test aid's step goes on once the sheet has closed.
        deleteDone(current->test);
    };
    // The window chosen at the click; if it can no longer take a sheet, the
    // main or key window as they are now.
    NSWindow *host = flow->hostWindow;
    if (!usableSheetHost(host)) host = activeSheetHost();
    if (host != nil) {
        [alert beginSheetModalForWindow:host completionHandler:finish];
        if (flow->test) {
            deleteReport(flow->test, deleteSheetDescription(*flow, true));
            scheduleDeleteCancel(flow, cancel, flow->test->closeSeconds);
        }
        return;
    }
    // App-modal from a run-loop callout, never inside this main-queue block
    // (see showPicker: the main queue must keep draining while it is up).
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        if (actionsState().stopped) {
            endDeleteFlow(current);
            return;
        }
        if (current->test) {
            deleteReport(current->test, deleteSheetDescription(*current, false));
            scheduleDeleteCancel(current, cancel, current->test->closeSeconds);
        }
        finish([alert runModal]);
    });
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

void onDeleteFilesRead(uint64_t serial, std::vector<PlacedFilesReply> &replies) {
    ActionsState &st = actionsState();
    // B14: the census entry ends with the reads, failed when a file list
    // could not be read (activityReadsResult; a reply after the 10 s timeout
    // finds it ended already).
    if (st.stopped || !st.deleteFlow || st.deleteFlow->serial != serial) {
        std::vector<std::string> unread;
        for (const PlacedFilesReply &r : replies) {
            if (!r.ok) unread.push_back(r.error);
        }
        activityEnd(activityCensusKey(serial), activityReadsResult(replies.size(), unread));
        return;
    }
    std::shared_ptr<DeleteFlow> flow = st.deleteFlow;
    flow->filesRead = true;
    flow->confirm.clear();
    flow->files.clear();
    std::vector<std::string> unread;
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
            unread.push_back(error);
        }
    }
    activityEnd(activityCensusKey(serial), activityReadsResult(flow->entry.roots.size(), unread));
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    flow->income = view ? countIncomeRows(*view, rootIdSet(flow->entry.roots), flow->playlist, &flow->files)
                        : GcIncomeRows();
    logDebug("delete-local: confirmation: " + gcConfirmSummary(flow->confirm, flow->income));
    showDeleteSheet(flow);
}

// --- Execute follow-ups (main) ---
//
// The Execute sheet's checkboxes, kept in the run file (RunFollowUps) and
// run when the run ends (own, adopted, or finished by the leftover scan),
// after its result and the reload that follows (applyRunResult): swap the
// rows of the roots now placed in every playlist (SwapChain, no lane), then,
// when chosen, take the lane, count the rows left (the Delete census) and
// run gc on the roots that pass the gc guard and whose census is clear
// (IntakeExecuteFollowUp); the others are kept with an Info line and a
// tooltip. The ticked checkbox is the confirm_gc confirmation for exactly
// those roots: no sheet. One chain at a time; a quit drops the rest, with
// one Info line per run whose follow-ups had not finished (actionsShutdown).

void startNextFollowUp();

// The current chain has ended (each chain gets here once).
void endFollowUp() {
    ActionsState &st = actionsState();
    if (st.followUpActive) forgetFollowUp(st.followUpActive);
    st.followUpActive.reset();
    startNextFollowUp();
}

void followUpGcEnded(uint64_t token) {
    ActionsState &st = actionsState();
    if (token == 0 || token != st.followUpGcToken) return;
    st.followUpGcToken = 0;
    endFollowUp();
}

// The run's reload is back: its follow-ups join the queue, unless that load
// failed (the statuses it would go by are not the run's).
void queueFollowUp(std::shared_ptr<FollowUpJob> job, const LoaderStatus &status) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    if (status.state != LoaderState::Ready) {
        logInfo("execute: no swap or delete after run " + job->stem + ": the reload after it did not succeed (" +
                loaderStateName(status.state) + (status.error.empty() ? std::string() : ": " + status.error) + ")");
        forgetFollowUp(job);
        return;
    }
    st.followUps.push_back(std::move(job));
    startNextFollowUp();
}

// The delete step, after the swap: the lane, the census, gc on the roots
// that pass; every path ends the chain (a started gc ends it when it ends).
void followUpDelete(std::shared_ptr<FollowUpJob> job) {
    ActionsState &st = actionsState();
    if (st.stopped) return;
    if (!job->choice.deleteLocal) {
        endFollowUp();
        return;
    }
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    std::string refusal = whyNotStartable();
    if (refusal.empty() && !view) refusal = "no intake data to check the playlists";
    if (refusal.empty() && view->isInert()) refusal = "intake is inert: " + view->inertReason();
    uint64_t token = 0;
    if (refusal.empty()) {
        token = st.lane.acquire(LaneHolder::Mutating);
        if (token == 0) refusal = "another intake command is still running";
    }
    // After the swap, so swapped rows count as library rows.
    std::unordered_map<std::string, size_t> left;
    size_t unchecked = 0;
    if (refusal.empty()) {
        IncomeRowCensus census;
        const std::unordered_set<std::string> ids(job->swapped.begin(), job->swapped.end());
        countIncomeRows(*view, ids, playlistRefFor(activePlaylist()), nullptr, &census);
        for (size_t i = 0; i < census.rows.size(); i++) left[census.rows[i].rootId] += census.entries[i];
        unchecked = census.unchecked;
    }
    const FollowUpGcPlan plan = planFollowUpGc(
        job->swapped,
        [&view](const std::string &id) -> const IntakeRecord * {
            return view ? view->snapshot().recordForId(id) : nullptr;
        },
        left, unchecked, refusal);
    RootErrorStore &errors = actionsErrorStore();
    for (const FollowUpSkip &skip : plan.skipped) {
        logInfo(followUpSkipLine(job->stem, skip));
        errors.set(skip.id, followUpSkipTooltip(skip), skip.baseline);
    }
    if (!plan.gc.empty()) {
        ActionEntry entry;
        entry.action = IntakeAction::DeleteLocal;
        entry.title = "Delete local copy";
        entry.enabled = true;
        entry.roots = plan.gc;
        logDebug("delete-local: \"Then delete the local copies\" in the Execute sheet confirms gc for " +
                 rootCountText(plan.gc.size()) + " of run " + job->stem);
        st.followUpGcToken = token;
        runMutation(entry, std::string(), token);  // logs its start, or why not (and releases the token)
        if (st.lane.busy()) return;                // gc runs: followUpGcEnded ends the chain
        st.followUpGcToken = 0;
    } else if (token != 0) {
        st.lane.finish(token);
    }
    if (!plan.skipped.empty()) serviceRefreshAfterCommand();  // shows the tooltips
    endFollowUp();
}

void startNextFollowUp() {
    ActionsState &st = actionsState();
    if (st.stopped || st.followUpActive || st.followUps.empty()) return;
    std::shared_ptr<FollowUpJob> job = st.followUps.front();
    st.followUps.pop_front();
    st.followUpActive = job;
    if (job->earlierSession) logInfo(earlierRunFollowUpLine(job->stem, job->choice));
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    if (!view || view->isInert()) {
        logInfo("execute: no swap or delete after run " + job->stem + ": " +
                (view ? "intake is inert: " + view->inertReason() : std::string("no intake data")));
        endFollowUp();
        return;
    }
    const FollowUpSwapPlan plan = planFollowUpSwap(
        job->ids, [&view](const std::string &id) { return view->snapshot().recordForId(id); });
    for (const auto &skipped : plan.notSwapped) {
        logDebug("execute: run " + job->stem + ": no swap for " + skipped.first + ": " + skipped.second);
    }
    if (plan.swap.empty()) {
        logInfo("execute: no swap or delete after run " + job->stem +
                ": none of its roots is placed with placed.verified");
        endFollowUp();
        return;
    }
    job->swapped = plan.swap;
    auto chain = std::make_shared<SwapChain>();
    chain->ids.insert(plan.swap.begin(), plan.swap.end());
    IncomeRowCensus census;
    countIncomeRows(*view, chain->ids, playlistRefFor(activePlaylist()), nullptr, &census);
    chain->pending = std::move(census.playlists);
    logInfo("execute: after run " + job->stem + ": swap for " + rootCountText(plan.swap.size()) + " (" +
            std::to_string(census.total) + " playlist row(s) in " + std::to_string(chain->pending.size()) +
            " playlist(s))" + (job->choice.deleteLocal ? ", then delete" : ""));
    const std::string stem = job->stem;
    chain->done = [job] { followUpDelete(job); };
    chain->notStarted = [stem](const std::string &why) {
        // The delete census finds the rows it left.
        logInfo("execute: after run " + stem + ": a playlist was not swapped: " + why);
        return true;
    };
    swapChainNext(chain, 0);
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
    finishRun(stem, envelope, true);
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
        // B14: an entry like an own run's, ended by finishRun.
        if (!run.file.ids.empty()) {
            activityBeginRun(run.stem, run.file.command, run.file.ids,
                             activityLabelFor(run.file.ids.front(),
                                              run.file.rootPaths.empty() ? std::string() : run.file.rootPaths.front()));
        }
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
        applyRunResult(run.file.command, runRoots(run.file.ids, run.file.rootPaths), result->finished[i],
                       followUpsAfterReload(run.stem, run.file.command, run.file.ids, run.file.followUps, true));
        deleteRunFilesLater(run.stem);
    }
    st.runScanDone = true;
    std::vector<std::function<void()>> waiting = std::move(st.afterRunScan);
    st.afterRunScan.clear();
    for (std::function<void()> &fn : waiting) fn();
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
    // B14: until its answer (onExecuteDryRun, late or not) or its refusal
    // (onRefused); the 10 s report does not end it. The runner never kills
    // a dry run (ReportOnly), so an answer may never come (a hung share):
    // at the mutating calls' hard cap the entry ends failed, and an answer
    // after that is ignored like any double end.
    activityBegin(activityLaneKey(token), ActivityKind::ExecuteDryRun, request.ids.size(),
                  albumLabel(entry.roots.front()));  // request.ids follow entry.roots
    {
        const double capSeconds = ProcessLimits().hardCapSeconds;
        const std::string minutes = std::to_string(static_cast<long>(capSeconds / 60.0));
        ActivityResult noAnswer;
        noAnswer.succeeded = false;
        noAnswer.reason = "no answer within " + minutes + " min";
        noAnswer.detail = std::string(kExecuteDryRunName) + ": no answer after " + minutes +
                          " minutes (it may still be running); a later answer is ignored";
        activityDeadline(activityLaneKey(token), static_cast<int64_t>(capSeconds * 1000.0), noAnswer);
    }
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

} // anonymous namespace

std::string actionsSwap(const ActionEntry &entry, metadb_handle_list_cref handles,
                        std::shared_ptr<const SwapTestHooks> test) {
    ActionsState &st = actionsState();
    // The test aid hears every early end, so its next step can run.
    auto endNow = [&test](const std::string &what) {
        if (test && test->report) test->report(what);
        if (test && test->done) test->done();
        return what;
    };
    if (st.stopped) return endNow("not run: intake is not running");
    if (!entry.enabled) return endNow("not run: the item is disabled");
    if (entry.roots.empty()) return endNow("not run: no qualifying root");
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    if (!view) return endNow(notRun(entry.action, "no intake data yet"));
    // The host frees `handles` when this returns: the rows are copied now.
    NativePathMenuBudget budget;
    size_t unchecked = 0;
    std::vector<SwapRow> rows = swapRowsFromHandles(handles, rootIdSet(entry.roots), *view, &budget, &unchecked);
    if (unchecked > 0) {
        logInfo("swap: " + std::to_string(unchecked) +
                " selected row(s) on a slow volume could not be checked and are left as they are");
    }
    if (rows.empty()) {
        return endNow(notRun(entry.action, "none of the selected rows points at an income path of these roots"));
    }
    std::string why;
    const size_t count = rows.size();
    const bool started = swapStart(
        activePlaylist(), std::move(rows), view, serviceActionInfo().libraryPrefix,
        [test](const SwapResult &result) {
            if (test && test->report) test->report(result.line);
            if (test && test->done) test->done();
        },
        why);
    if (!started) return endNow(notRun(entry.action, why));
    return "swapping " + std::to_string(count) + " row(s)";
}

std::string actionsDeleteLocal(const ActionEntry &entry, std::shared_ptr<const DeleteTestHooks> test) {
    ActionsState &st = actionsState();
    // The test aid hears every early end, so its next step can run.
    auto endNow = [&test](const std::string &what) {
        deleteReport(test, what);
        deleteDone(test);
        return what;
    };
    if (st.stopped) return endNow("not run: intake is not running");
    if (!entry.enabled) return endNow("not run: the item is disabled");
    if (entry.roots.empty()) return endNow("not run: no qualifying root");
    // The permanent guard first: placed, verified roots only
    // (requestForEntry applies it again to whatever finally runs).
    ActionEntry eligible = entry;
    eligible.roots = gcEligibleRoots(entry.roots);
    if (eligible.roots.empty()) return endNow(notRun(entry.action, "no placed root with placed.verified"));
    if (st.deleteFlow) {
        logInfo("delete-local: the confirmation is already open or being prepared; this request is ignored");
        return endNow("ignored: the delete confirmation is already open or being prepared");
    }
    // No confirmation for a call that could not start anyway.
    const std::string why = whyNotStartable();
    if (!why.empty()) return endNow(notRun(entry.action, why));
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    if (view && view->isInert()) return endNow(notRun(entry.action, "intake is inert: " + view->inertReason()));
    if (!serviceActionInfo().confirmGc) {
        // The test aid only shows the sheet: with no sheet, nothing runs.
        if (test) return endNow("no confirmation: confirm_gc is 0; nothing deleted");
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
    flow->test = std::move(test);
    flow->hostWindow = sheetHostWindow();  // now, while the pointer is where the menu was
    flow->playlist = playlistRefFor(activePlaylist());
    st.deleteFlow = flow;
    const uint64_t serial = flow->serial;
    // B14: the census entry, until the reads come back or the 10 s below.
    activityBegin(activityCensusKey(serial), ActivityKind::DeleteCensus, eligible.roots.size(),
                  albumLabel(eligible.roots.front()));
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
                       const std::string why =
                           "the sidecars could not be read within 10 s (the share is not answering)";
                       const std::string what =
                           notRun(IntakeAction::DeleteLocal, why + "; no confirmation, nothing deleted");
                       ActivityResult timedOut;
                       timedOut.succeeded = false;
                       timedOut.reason = "no answer within 10 s";
                       timedOut.detail = why;
                       activityEnd(activityCensusKey(serial), timedOut);
                       endDeleteFlow(late);
                       deleteReport(late->test, what);
                       deleteDone(late->test);
                   });
    return "reading the file lists of " + rootCountText(eligible.roots.size());
}

namespace {

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

bool actionsLaneFree() {
    const ActionsState &st = actionsState();
    // Execute follow-ups pending or running count as busy: between a run's
    // end and its follow-up's gc the lane is free (the reload, then the
    // swap), and a scan taking it then would make the delete step refuse
    // and keep the local copies.
    return !st.stopped && st.runScanDone && !st.lane.busy() && st.followUpsUnfinished.empty() && !st.followUpActive;
}

AutoScanStart actionsStartAutoScan(const AutoScanJob &job, std::function<void(AutoScanExit how)> done) {
    ActionsState &st = actionsState();
    if (!actionsLaneFree()) return AutoScanStart::LaneTaken;
    const std::string &name = job.income.name;
    // The driver gives the scheduler no incomes while the provider is
    // inert; this covers a job checked before that load's status reached it.
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    if (view && view->isInert()) {
        logInfo("auto-scan: " + name + " not started: intake is inert: " + view->inertReason());
        return AutoScanStart::Refused;
    }
    CliConfig config;
    if (!serviceMutationConfig(config)) {
        logInfo("auto-scan: " + name + " not started: intake is not running or has no CLI path");
        return AutoScanStart::Refused;
    }
    CliRequest request;
    request.command = CliCommand::Scan;
    request.income = name;
    request.incomePath = job.income.path;  // sent instead of a name starting with '-'
    const uint64_t token = st.lane.acquire(LaneHolder::Scan);
    if (token == 0) return AutoScanStart::LaneTaken;
    st.autoScanToken = token;
    st.autoScanIncome = name;
    st.autoScanIncomePath = job.income.path;
    st.autoScanDone = std::move(done);
    logInfo(autoScanStartLine(name, job.startup));
    // B14: from here to every path that releases the lane (endAutoScanRun).
    // The count stays 0: the result's count is the roots the scan wrote.
    activityBegin(activityLaneKey(token), ActivityKind::Scan, 0, name);
    auto sharedConfig = std::make_shared<const CliConfig>(std::move(config));
    auto sharedRequest = std::make_shared<const CliRequest>(std::move(request));
    dispatch_async(st.queue, ^{
        startAutoScanOnQueue(token, sharedConfig, sharedRequest);
    });
    return AutoScanStart::Started;
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

ActionTable actionsTableForHandles(metadb_handle_list_cref handles) {
    if (actionsState().stopped) return ActionTable();
    size_t rootCount = 0;
    return menuTableFor(handles, rootCount);
}

ActionTable actionsTableFor(const std::vector<const IntakeRecord *> &roots, const IntakeView *view) {
    return buildActionTable(roots, liveContext(view), menuActions());
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
    // B14: the status bar empties at once (one change notification); no
    // hook adds to it afterwards.
    activityClear();
    st.menuTable = ActionTable();
    // A running `collections` is killed; one not yet spawned never starts.
    st.pickerRunner.closeReadLane();
    // A swap's result is dropped (the playlist stays as it is).
    swapShutdown();
    st.deleteFlow.reset();
    // Follow-ups not finished are dropped: those waiting for their reload,
    // queued, or swapping (nothing is deleted). Their run files are gone,
    // so the next start cannot do them: one Info line per run (the log
    // backend goes only after this, IntakeService on_quit). A chain whose
    // gc is already on its way is left out: a quit never stops gc, and it
    // finishes on its own.
    for (const std::shared_ptr<FollowUpJob> &job : st.followUpsUnfinished) {
        if (job == st.followUpActive && st.followUpGcToken != 0) continue;
        logInfo(followUpQuitLine(job->stem, job->choice));
    }
    st.followUpsUnfinished.clear();
    st.followUps.clear();
    // Detached runs keep running and keep their files (the next session
    // adopts or finishes them); only the watching stops.
    for (auto &watch : st.exitWatches) watch.second->cancel();
    st.exitWatches.clear();
    st.afterRunScan.clear();
}

} // namespace intake
