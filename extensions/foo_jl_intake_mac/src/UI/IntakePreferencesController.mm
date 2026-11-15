//
//  IntakePreferencesController.mm
//  foo_jl_intake
//
//  The Tools > Intake preferences page (PLAN.md B5, 3.9; doc 04 v1.2
//  "Preferences page"). Programmatic AppKit in the suite's style
//  (shared/PreferencesCommon.h, knowledge_base 04/08/13): a flipped,
//  scrollable form, 11 pt controls, semantic colours only (dark mode), no
//  glass in form content.
//
//  Sections:
//   - Command-line tool: CLI path (a .ts path runs through bun), bun path
//     (empty: auto-detected, the result as the placeholder), rules folder
//     (empty: the CLI's own configuration). Each has Browse and a hint
//     line; the path checks stat files, so they run on a private
//     background queue and never on the main thread.
//   - Watched folders: one absolute path per line; problem lines are
//     highlighted in place and listed under the field (lexical checks
//     only, no filesystem access: these folders are usually on a share).
//   - Library mapping: one prefix pair, NAS path prefix -> Mac path prefix,
//     stored lexically clean (normalizedPrefix) and validated only (Swap,
//     B9, uses it).
//   - Confirmations (B6): "Confirm before Reject" (confirm_reject, default
//     on). Execute always asks; Delete's toggle arrives with B9.
//   - Logging: the log level.
//   - Status: state, CLI version, roots ("Releases") and last error from
//     the loader (statusDisplay), refreshed on
//     IntakeStatusDidChangeNotification while the page is visible (no
//     timer); Test CLI (`version --json`, built and run on a background
//     queue) and Reload now (serviceReload; "Reload finished." when the load
//     serving the click has ended, not on the first status change).
//   - Income folders: read-only (incomeDisplay): `intake income` when the
//     CLI offers it (a failed call is named, never shown as an empty list),
//     otherwise the folders holding the loaded roots.
//
//  Applying changes: a text field is written to configStore when editing
//  ends (Return, Tab, focus loss, and when the page goes away), the popup
//  and the checkbox at once; then IntakeSettingsDidChangeNotification is posted and
//  IntakeService applies it without a restart.
//
//  Keyboard: the key view order runs top to bottom through every control
//  (Tab in the watched folders field moves on instead of inserting a tab);
//  it joins the host's key view loop when there is one after the page's
//  root view, else it closes inside the page (joinHostKeyViewLoop). Every
//  control has an accessibility label.
//
//  Wrapping labels (status values, the Test CLI result, the folder
//  problems) wrap at their own width (IntakePrefsWrappingLabel), so they fit
//  the column at any page width.
//

#import "IntakePreferencesController.h"

#include "../Integration/IntakeConfig.h"
#include "../Integration/IntakeService.h"

#include "../Core/IntakeCommandArgs.h"
#include "../Core/IntakeLoadPolicy.h"
#include "../Core/IntakeSettingsParse.h"

#import "../../../../shared/PreferencesCommon.h"
#include "../../../../shared/version.h"

#include <string>
#include <vector>

using namespace intake;

namespace {

constexpr CGFloat kLabelColumnWidth = 112;
constexpr CGFloat kButtonColumnWidth = 92;
constexpr CGFloat kMinimumPageWidth = 540;
// The first wrap width of a wrapping label, below the narrowest column it
// can get (about 264 pt at kMinimumPageWidth); it then follows the label's
// width (IntakePrefsWrappingLabel).
constexpr CGFloat kInitialWrapWidth = 200;
constexpr size_t kMaxListedProblems = 6;

NSString *NSStr(const std::string &s) {
    NSString *out = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

std::string StdStr(NSString *s) {
    const char *c = s.UTF8String;
    return c ? std::string(c) : std::string();
}

NSString *Trimmed(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSColor *ToneColor(StatusTone tone) {
    switch (tone) {
        case StatusTone::Good: return [NSColor systemGreenColor];
        case StatusTone::Warning: return [NSColor systemOrangeColor];
        case StatusTone::Error: return [NSColor systemRedColor];
        case StatusTone::Neutral: break;
    }
    return [NSColor secondaryLabelColor];
}

// The results of the path checks (background queue).
struct PathHints {
    PathCheck cli = PathCheck::Empty;
    bool script = false;
    PathCheck bun = PathCheck::Empty;
    std::string autoBun;  // findBun over the default directories; "" when none
    PathCheck rules = PathCheck::Empty;
};

PathHints ComputePathHints(const std::string &cli, const std::string &bun, const std::string &rules,
                           const std::vector<std::string> &environment) {
    PathHints h;
    h.script = isScriptCliPath(cli);
    h.cli = cli.empty() ? PathCheck::Empty : checkCliPath(cli);
    h.bun = bun.empty() ? PathCheck::Empty : checkExecutable(bun);
    h.autoBun = findBun(defaultBunSearchDirs(environment));
    h.rules = rules.empty() ? PathCheck::Empty : checkDirectory(rules);
    return h;
}

// Line ranges of `text`, split exactly like parseFolderLines ("\r\n", "\n"
// and a lone "\r" each end a line), so FolderLine::line indexes them.
NSArray<NSValue *> *LineRanges(NSString *text) {
    NSMutableArray<NSValue *> *out = [NSMutableArray array];
    const NSUInteger length = text.length;
    NSUInteger start = 0;
    NSUInteger i = 0;
    while (i < length) {
        const unichar c = [text characterAtIndex:i];
        if (c == '\n' || c == '\r') {
            [out addObject:[NSValue valueWithRange:NSMakeRange(start, i - start)]];
            if (c == '\r' && i + 1 < length && [text characterAtIndex:i + 1] == '\n') i++;
            i++;
            start = i;
        } else {
            i++;
        }
    }
    [out addObject:[NSValue valueWithRange:NSMakeRange(start, length - start)]];
    return out;
}

} // anonymous namespace

// Flipped so the form starts at the top of the scroll view (unique class
// name per component, shared/PreferencesCommon.h).
@interface IntakePrefsFlippedView : NSView
@end
@implementation IntakePrefsFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

// A wrapping label whose wrap width follows its own width, so its height
// fits the column the grid gives it at any page width: a fixed
// preferredMaxLayoutWidth wider than the column would compute too few lines
// and clip the last one.
@interface IntakePrefsWrappingLabel : NSTextField
@end
@implementation IntakePrefsWrappingLabel
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    if (size.width > 1 && fabs(self.preferredMaxLayoutWidth - size.width) > 0.5) {
        self.preferredMaxLayoutWidth = size.width;
        [self invalidateIntrinsicContentSize];
    }
}
@end

@interface IntakePreferencesController () <NSTextFieldDelegate, NSTextViewDelegate, NSTableViewDataSource,
                                           NSTableViewDelegate>
@property (nonatomic, strong) NSButton *infoButton;

@property (nonatomic, strong) NSTextField *cliField;
@property (nonatomic, strong) NSButton *cliBrowseButton;
@property (nonatomic, strong) NSTextField *cliHint;
@property (nonatomic, strong) NSTextField *bunField;
@property (nonatomic, strong) NSButton *bunBrowseButton;
@property (nonatomic, strong) NSTextField *bunHint;
@property (nonatomic, strong) NSTextField *rulesField;
@property (nonatomic, strong) NSButton *rulesBrowseButton;
@property (nonatomic, strong) NSTextField *rulesHint;

@property (nonatomic, strong) NSTextView *foldersTextView;
@property (nonatomic, strong) NSTextField *foldersHint;

@property (nonatomic, strong) NSTextField *prefixFromField;
@property (nonatomic, strong) NSTextField *prefixToField;
@property (nonatomic, strong) NSTextField *prefixHint;

@property (nonatomic, strong) NSButton *confirmRejectCheckbox;

@property (nonatomic, strong) NSPopUpButton *logLevelPopup;

@property (nonatomic, strong) NSTextField *stateValue;
@property (nonatomic, strong) NSTextField *cliVersionValue;
@property (nonatomic, strong) NSTextField *rootsValue;
@property (nonatomic, strong) NSTextField *errorValue;
@property (nonatomic, strong) NSButton *testButton;
@property (nonatomic, strong) NSButton *reloadButton;
@property (nonatomic, strong) NSProgressIndicator *testSpinner;
@property (nonatomic, strong) NSTextField *actionResult;

@property (nonatomic, strong) NSTableView *incomeTable;
@property (nonatomic, strong) NSTextField *incomeNote;
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *incomeRows;  // name, path, state
@property (nonatomic, copy) NSIndexSet *missingIncomeRows;

// The values last written (or read), to write and notify only on change.
@property (nonatomic, copy) NSString *savedCli;
@property (nonatomic, copy) NSString *savedBun;
@property (nonatomic, copy) NSString *savedRules;
@property (nonatomic, copy) NSString *savedFolders;
@property (nonatomic, copy) NSString *savedPrefixFrom;
@property (nonatomic, copy) NSString *savedPrefixTo;

@property (nonatomic, assign) BOOL observingStatus;
@property (nonatomic, assign) NSUInteger reloadToken;  // the latest Reload now click
@property (nonatomic, assign) NSUInteger hintGeneration;
@end

@implementation IntakePreferencesController {
    dispatch_queue_t _checkQueue;  // path checks (stat), off the main thread
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _checkQueue = dispatch_queue_create("com.foobar2000.intake.prefs-checks", DISPATCH_QUEUE_SERIAL);
        _incomeRows = @[];
        _missingIncomeRows = [NSIndexSet indexSet];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Building

- (NSTextField *)fieldWithPlaceholder:(NSString *)placeholder accessibilityLabel:(NSString *)label {
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.font = [NSFont systemFontOfSize:11];
    field.placeholderString = placeholder;
    field.delegate = self;
    field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    field.usesSingleLineMode = YES;
    field.accessibilityLabel = label;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.widthAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    return field;
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action accessibilityLabel:(NSString *)label {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.font = [NSFont systemFontOfSize:11];
    button.accessibilityLabel = label;
    return button;
}

- (NSTextField *)hintLabel {
    NSTextField *hint = JLCreateHelperText(@"");
    hint.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [hint setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    return hint;
}

- (NSTextField *)wrappingLabel {
    NSTextField *label = [IntakePrefsWrappingLabel wrappingLabelWithString:@""];
    label.font = [NSFont systemFontOfSize:11];
    label.textColor = [NSColor secondaryLabelColor];
    label.preferredMaxLayoutWidth = kInitialWrapWidth;
    // The column decides the width; the text never widens the page.
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                    forOrientation:NSLayoutConstraintOrientationHorizontal];
    label.selectable = YES;
    return label;
}

- (NSTextField *)valueLabelWithAccessibilityLabel:(NSString *)label {
    NSTextField *value = [self wrappingLabel];
    value.textColor = [NSColor labelColor];
    value.accessibilityLabel = label;
    return value;
}

// A form grid: labels (trailing, indented), controls (fill), buttons.
- (NSGridView *)gridWithRows:(NSArray<NSArray<NSView *> *> *)rows {
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.rowSpacing = 5;
    grid.columnSpacing = 8;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    NSGridColumn *labels = [grid columnAtIndex:0];
    labels.xPlacement = NSGridCellPlacementTrailing;
    labels.width = kLabelColumnWidth;
    labels.leadingPadding = JLPrefsIndent;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementFill;
    NSGridColumn *buttons = [grid columnAtIndex:2];
    buttons.xPlacement = NSGridCellPlacementLeading;
    buttons.width = kButtonColumnWidth;
    return grid;
}

- (NSView *)empty {
    return NSGridCell.emptyContentView;
}

- (void)loadView {
    IntakePrefsFlippedView *document = [[IntakePrefsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 600, 900)];
    document.translatesAutoresizingMaskIntoConstraints = NO;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 600, 600)];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = NO;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;  // fill the host's area
    scrollView.documentView = document;
    NSClipView *clip = scrollView.contentView;
    NSLayoutConstraint *fillWidth = [document.widthAnchor constraintEqualToAnchor:clip.widthAnchor];
    fillWidth.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [document.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [document.widthAnchor constraintGreaterThanOrEqualToConstant:kMinimumPageWidth],
        fillWidth,
    ]];
    self.view = scrollView;

    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [document addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:JLPrefsLeftMargin],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-JLPrefsLeftMargin],
        [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-20],
    ]];
    void (^addFullWidth)(NSView *) = ^(NSView *view) {
        [stack addArrangedSubview:view];
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    };

    // ===== Title =====
    NSTextField *title = JLCreatePreferencesTitle(@"Intake");
    [stack addArrangedSubview:title];
    self.infoButton = JLAddPreferencesInfoButton(document, title, self, @selector(showComponentInfo:));
    self.infoButton.accessibilityLabel = @"Component details";
    NSTextField *intro =
        JLCreateHelperText(@"Tints SimPlaylist rows by music intake status. Changes apply at once.");
    [stack addArrangedSubview:intro];
    [stack setCustomSpacing:JLPrefsSectionGap afterView:intro];

    // ===== Command-line tool =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Command-line tool")];
    self.cliField = [self fieldWithPlaceholder:@"Absolute path of the intake CLI (or its cli.ts)"
                            accessibilityLabel:@"Intake CLI path"];
    self.cliBrowseButton = [self buttonWithTitle:@"Browse…"
                                          action:@selector(browseCli:)
                              accessibilityLabel:@"Choose the intake CLI"];
    self.cliHint = [self hintLabel];
    self.bunField = [self fieldWithPlaceholder:@"Automatic" accessibilityLabel:@"bun path"];
    self.bunBrowseButton = [self buttonWithTitle:@"Browse…"
                                          action:@selector(browseBun:)
                              accessibilityLabel:@"Choose bun"];
    self.bunHint = [self hintLabel];
    self.rulesField = [self fieldWithPlaceholder:@"The CLI's own configuration" accessibilityLabel:@"Rules folder"];
    self.rulesBrowseButton = [self buttonWithTitle:@"Browse…"
                                            action:@selector(browseRules:)
                                accessibilityLabel:@"Choose the rules folder"];
    self.rulesHint = [self hintLabel];
    NSGridView *cliGrid = [self gridWithRows:@[
        @[ JLCreateLabel(@"CLI path:"), self.cliField, self.cliBrowseButton ],
        @[ [self empty], self.cliHint, [self empty] ],
        @[ JLCreateLabel(@"bun:"), self.bunField, self.bunBrowseButton ],
        @[ [self empty], self.bunHint, [self empty] ],
        @[ JLCreateLabel(@"Rules folder:"), self.rulesField, self.rulesBrowseButton ],
        @[ [self empty], self.rulesHint, [self empty] ],
    ]];
    addFullWidth(cliGrid);
    [stack setCustomSpacing:JLPrefsSectionGap afterView:cliGrid];

    // ===== Watched folders =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Watched folders")];
    NSScrollView *foldersScroll = [self buildFoldersTextView];
    self.foldersHint = [self wrappingLabel];
    self.foldersHint.font = [NSFont systemFontOfSize:10];
    self.foldersHint.selectable = NO;
    NSTextField *foldersLabel = JLCreateLabel(@"Folders:");
    NSGridView *foldersGrid = [self gridWithRows:@[
        @[ foldersLabel, foldersScroll, [self empty] ],
        @[ [self empty], self.foldersHint, [self empty] ],
    ]];
    // The scroll view has no baseline: align the row's tops instead.
    NSGridRow *foldersRow = [foldersGrid rowAtIndex:0];
    foldersRow.rowAlignment = NSGridRowAlignmentNone;
    foldersRow.yPlacement = NSGridCellPlacementTop;
    addFullWidth(foldersGrid);
    [stack setCustomSpacing:JLPrefsSectionGap afterView:foldersGrid];

    // ===== Library mapping =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Library mapping (for Swap to library paths)")];
    self.prefixFromField = [self fieldWithPlaceholder:@"e.g. /share/library" accessibilityLabel:@"NAS path prefix"];
    self.prefixToField = [self fieldWithPlaceholder:@"e.g. /Volumes/library" accessibilityLabel:@"Mac path prefix"];
    self.prefixHint = [self hintLabel];
    NSGridView *prefixGrid = [self gridWithRows:@[
        @[ JLCreateLabel(@"NAS path prefix:"), self.prefixFromField, [self empty] ],
        @[ JLCreateLabel(@"Mac path prefix:"), self.prefixToField, [self empty] ],
        @[ [self empty], self.prefixHint, [self empty] ],
    ]];
    addFullWidth(prefixGrid);
    [stack setCustomSpacing:JLPrefsSectionGap afterView:prefixGrid];

    // ===== Confirmations =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Confirmations")];
    self.confirmRejectCheckbox = [NSButton checkboxWithTitle:@"Confirm before Reject"
                                                      target:self
                                                      action:@selector(confirmRejectChanged:)];
    self.confirmRejectCheckbox.font = [NSFont systemFontOfSize:11];
    self.confirmRejectCheckbox.accessibilityLabel = @"Confirm before Reject";
    NSTextField *confirmHint = JLCreateHelperText(
        @"Lists the albums and asks for an optional reason. Off: Reject runs at once, without a reason.");
    NSGridView *confirmGrid = [self gridWithRows:@[
        @[ [self empty], self.confirmRejectCheckbox, [self empty] ],
        @[ [self empty], confirmHint, [self empty] ],
    ]];
    [confirmGrid cellForView:self.confirmRejectCheckbox].xPlacement = NSGridCellPlacementLeading;
    addFullWidth(confirmGrid);
    [stack setCustomSpacing:JLPrefsSectionGap afterView:confirmGrid];

    // ===== Logging =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Logging")];
    self.logLevelPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.logLevelPopup.font = [NSFont systemFontOfSize:11];
    [self.logLevelPopup addItemsWithTitles:@[ @"Error", @"Info", @"Debug" ]];
    self.logLevelPopup.target = self;
    self.logLevelPopup.action = @selector(logLevelChanged:);
    self.logLevelPopup.accessibilityLabel = @"Log level";
    NSTextField *logHint = JLCreateHelperText(@"Messages appear in View > Console with an [intake] prefix.");
    NSGridView *logGrid = [self gridWithRows:@[
        @[ JLCreateLabel(@"Log level:"), self.logLevelPopup, [self empty] ],
        @[ [self empty], logHint, [self empty] ],
    ]];
    [logGrid cellForView:self.logLevelPopup].xPlacement = NSGridCellPlacementLeading;
    addFullWidth(logGrid);
    [stack setCustomSpacing:JLPrefsSectionGap afterView:logGrid];

    // ===== Status =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Status")];
    self.stateValue = [self valueLabelWithAccessibilityLabel:@"State"];
    self.cliVersionValue = [self valueLabelWithAccessibilityLabel:@"CLI version"];
    self.rootsValue = [self valueLabelWithAccessibilityLabel:@"Releases"];
    self.errorValue = [self valueLabelWithAccessibilityLabel:@"Last error"];
    self.testButton = [self buttonWithTitle:@"Test CLI"
                                     action:@selector(testCli:)
                         accessibilityLabel:@"Test CLI: run intake version"];
    self.reloadButton = [self buttonWithTitle:@"Reload now"
                                       action:@selector(reloadNow:)
                           accessibilityLabel:@"Reload now"];
    self.testSpinner = [[NSProgressIndicator alloc] init];
    self.testSpinner.style = NSProgressIndicatorStyleSpinning;
    self.testSpinner.controlSize = NSControlSizeSmall;
    self.testSpinner.displayedWhenStopped = NO;
    self.testSpinner.accessibilityLabel = @"Test CLI running";
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ self.testButton, self.reloadButton, self.testSpinner ]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;
    self.actionResult = [self wrappingLabel];
    self.actionResult.accessibilityLabel = @"Test CLI result";
    NSGridView *statusGrid = [self gridWithRows:@[
        @[ JLCreateLabel(@"State:"), self.stateValue, [self empty] ],
        @[ JLCreateLabel(@"CLI version:"), self.cliVersionValue, [self empty] ],
        @[ JLCreateLabel(@"Releases:"), self.rootsValue, [self empty] ],
        @[ JLCreateLabel(@"Last error:"), self.errorValue, [self empty] ],
        @[ [self empty], buttons, [self empty] ],
        @[ [self empty], self.actionResult, [self empty] ],
    ]];
    [statusGrid cellForView:buttons].xPlacement = NSGridCellPlacementLeading;
    [statusGrid rowAtIndex:4].topPadding = 4;
    addFullWidth(statusGrid);
    [stack setCustomSpacing:JLPrefsSectionGap afterView:statusGrid];

    // ===== Income folders =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Income folders")];
    NSView *incomeContainer = [self buildIncomeTable];
    addFullWidth(incomeContainer);
    self.incomeNote = JLCreateHelperText(@"");
    NSView *noteContainer = [[NSView alloc] init];
    noteContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.incomeNote.translatesAutoresizingMaskIntoConstraints = NO;
    [noteContainer addSubview:self.incomeNote];
    [NSLayoutConstraint activateConstraints:@[
        [self.incomeNote.topAnchor constraintEqualToAnchor:noteContainer.topAnchor],
        [self.incomeNote.bottomAnchor constraintEqualToAnchor:noteContainer.bottomAnchor],
        [self.incomeNote.leadingAnchor constraintEqualToAnchor:noteContainer.leadingAnchor constant:JLPrefsIndent],
        [self.incomeNote.trailingAnchor constraintLessThanOrEqualToAnchor:noteContainer.trailingAnchor],
    ]];
    addFullWidth(noteContainer);

    [self buildKeyViewLoop];
}

- (NSScrollView *)buildFoldersTextView {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 320, 78)];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    const NSSize size = scroll.contentSize;

    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    textView.minSize = NSMakeSize(0, size.height);
    textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.autoresizingMask = NSViewWidthSizable;
    textView.textContainer.containerSize = NSMakeSize(size.width, CGFLOAT_MAX);
    textView.textContainer.widthTracksTextView = YES;
    textView.textContainerInset = NSMakeSize(2, 3);
    textView.richText = NO;
    textView.importsGraphics = NO;
    textView.allowsUndo = YES;
    textView.font = [NSFont systemFontOfSize:11];
    textView.textColor = [NSColor textColor];
    // Paths: no substitutions or corrections.
    textView.automaticQuoteSubstitutionEnabled = NO;
    textView.automaticDashSubstitutionEnabled = NO;
    textView.automaticTextReplacementEnabled = NO;
    textView.automaticSpellingCorrectionEnabled = NO;
    textView.continuousSpellCheckingEnabled = NO;
    textView.grammarCheckingEnabled = NO;
    textView.smartInsertDeleteEnabled = NO;
    textView.automaticLinkDetectionEnabled = NO;
    textView.delegate = self;
    textView.accessibilityLabel = @"Watched folders, one absolute path per line";
    scroll.documentView = textView;
    self.foldersTextView = textView;

    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll.heightAnchor constraintEqualToConstant:78].active = YES;
    [scroll.widthAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    return scroll;
}

- (NSView *)buildIncomeTable {
    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    table.dataSource = self;
    table.delegate = self;
    table.rowHeight = 18;
    table.style = NSTableViewStylePlain;
    table.usesAlternatingRowBackgroundColors = YES;
    table.allowsEmptySelection = YES;
    table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    table.accessibilityLabel = @"Income folders";
    NSArray *columns = @[ @[ @"name", @"Name", @90 ], @[ @"state", @"State", @70 ], @[ @"path", @"Folder", @260 ] ];
    for (NSArray *spec in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        column.title = spec[1];
        column.width = [spec[2] doubleValue];
        column.minWidth = 50;
        column.editable = NO;
        [table addTableColumn:column];
    }
    self.incomeTable = table;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 420, 112)];
    scroll.documentView = table;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *container = [[NSView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:container.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:JLPrefsIndent],
        [scroll.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [scroll.heightAnchor constraintEqualToConstant:112],
    ]];
    return container;
}

- (void)buildKeyViewLoop {
    NSArray<NSView *> *order = @[
        self.infoButton,      self.cliField,      self.cliBrowseButton, self.bunField,
        self.bunBrowseButton, self.rulesField,    self.rulesBrowseButton, self.foldersTextView,
        self.prefixFromField, self.prefixToField, self.confirmRejectCheckbox, self.logLevelPopup,
        self.testButton,      self.reloadButton,  self.incomeTable,
    ];
    for (NSUInteger i = 0; i < order.count; i++) {
        order[i].nextKeyView = order[(i + 1) % order.count];
    }
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadSettings];
    [self refreshFolderFlags];
    [self refreshPrefixHint];
    [self refreshPathHints];
    [self refreshStatus];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    if (!self.observingStatus) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(statusChanged:)
                                                     name:IntakeStatusDidChangeNotification
                                                   object:nil];
        self.observingStatus = YES;
    }
    [self joinHostKeyViewLoop];
    [self refreshStatus];
    [self refreshPathHints];
}

// When the host's key view loop goes on after the page's root view, the
// page's controls join it there, so Tab leaves the page after the last one;
// otherwise the loop stays closed inside the page (buildKeyViewLoop), which
// keeps Tab working with no chain from the host.
- (void)joinHostKeyViewLoop {
    NSView *root = self.view;
    NSView *hostNext = root.nextKeyView;
    if (hostNext == nil || hostNext == root || [hostNext isDescendantOf:root]) return;  // none, or joined
    root.nextKeyView = self.infoButton;
    self.incomeTable.nextKeyView = hostNext;
}

- (void)viewWillDisappear {
    // An edit in progress is kept: the page may go away without the field
    // ending its editing first.
    [self saveAllFields];
    [super viewWillDisappear];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    if (self.observingStatus) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:IntakeStatusDidChangeNotification object:nil];
        self.observingStatus = NO;
    }
}

#pragma mark - Settings

- (void)loadSettings {
    self.savedCli = NSStr(trimmedSetting(config::getString(config::kCliPath, "")));
    self.savedBun = NSStr(trimmedSetting(config::getString(config::kBunPath, "")));
    self.savedRules = NSStr(trimmedSetting(config::getString(config::kRulesDir, "")));
    self.savedFolders = NSStr(config::getString(config::kWatchFolders, ""));
    self.savedPrefixFrom = NSStr(normalizedPrefix(config::getString(config::kSwapPrefixFrom, "")));
    self.savedPrefixTo = NSStr(normalizedPrefix(config::getString(config::kSwapPrefixTo, "")));

    self.cliField.stringValue = self.savedCli;
    self.bunField.stringValue = self.savedBun;
    self.rulesField.stringValue = self.savedRules;
    self.foldersTextView.string = self.savedFolders;
    self.prefixFromField.stringValue = self.savedPrefixFrom;
    self.prefixToField.stringValue = self.savedPrefixTo;

    int64_t level = config::getInt(config::kLogLevel, config::defaultLogLevel());
    if (level < 0) level = 0;
    if (level > 2) level = 2;
    [self.logLevelPopup selectItemAtIndex:static_cast<NSInteger>(level)];

    self.confirmRejectCheckbox.state =
        config::getInt(config::kConfirmReject, 1) != 0 ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)notifySettingsChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:IntakeSettingsDidChangeNotification object:nil];
}

// Writes `value` under `key` when it differs from `saved`. Returns whether
// it wrote.
- (BOOL)saveString:(NSString *)value key:(const char *)key saved:(NSString *)saved {
    if ([value isEqualToString:saved ?: @""]) return NO;
    config::setString(key, StdStr(value));
    return YES;
}

// Every text control, written when changed; one notification for all.
- (void)saveAllFields {
    if (!self.isViewLoaded) return;
    BOOL changed = NO;
    BOOL pathsChanged = NO;

    NSString *cli = Trimmed(self.cliField.stringValue);
    if ([self saveString:cli key:config::kCliPath saved:self.savedCli]) {
        self.savedCli = cli;
        changed = pathsChanged = YES;
    }
    NSString *bun = Trimmed(self.bunField.stringValue);
    if ([self saveString:bun key:config::kBunPath saved:self.savedBun]) {
        self.savedBun = bun;
        changed = pathsChanged = YES;
    }
    NSString *rules = Trimmed(self.rulesField.stringValue);
    if ([self saveString:rules key:config::kRulesDir saved:self.savedRules]) {
        self.savedRules = rules;
        changed = pathsChanged = YES;
    }
    NSString *folders = [self.foldersTextView.string copy];
    if ([self saveString:folders key:config::kWatchFolders saved:self.savedFolders]) {
        self.savedFolders = folders;
        changed = YES;
    }
    // The prefixes are stored lexically clean ("/a/" as "/a").
    NSString *from = NSStr(normalizedPrefix(StdStr(self.prefixFromField.stringValue)));
    if ([self saveString:from key:config::kSwapPrefixFrom saved:self.savedPrefixFrom]) {
        self.savedPrefixFrom = from;
        changed = YES;
    }
    NSString *to = NSStr(normalizedPrefix(StdStr(self.prefixToField.stringValue)));
    if ([self saveString:to key:config::kSwapPrefixTo saved:self.savedPrefixTo]) {
        self.savedPrefixTo = to;
        changed = YES;
    }

    if (pathsChanged) [self refreshPathHints];
    if (changed) [self notifySettingsChanged];
}

// Ends editing in the page (so the field editor hands its text over), then
// writes what changed.
- (void)commitEdits {
    NSWindow *window = self.view.window;
    NSResponder *responder = window.firstResponder;
    if ([responder isKindOfClass:[NSView class]] && [(NSView *)responder isDescendantOf:self.view]) {
        [window makeFirstResponder:nil];
    }
    [self saveAllFields];
}

#pragma mark - Text editing

- (void)controlTextDidChange:(NSNotification *)notification {
    id field = notification.object;
    if (field == self.prefixFromField || field == self.prefixToField) [self refreshPrefixHint];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    id field = notification.object;
    if ([field isKindOfClass:[NSTextField class]]) {
        NSTextField *textField = field;
        const BOOL prefix = textField == self.prefixFromField || textField == self.prefixToField;
        NSString *clean = prefix ? NSStr(normalizedPrefix(StdStr(textField.stringValue))) : Trimmed(textField.stringValue);
        if (![clean isEqualToString:textField.stringValue]) textField.stringValue = clean;
        if (prefix) [self refreshPrefixHint];
    }
    [self saveAllFields];
}

- (void)textDidChange:(NSNotification *)notification {
    if (notification.object == self.foldersTextView) [self refreshFolderFlags];
}

- (void)textDidEndEditing:(NSNotification *)notification {
    if (notification.object == self.foldersTextView) [self saveAllFields];
}

// Tab and Shift-Tab move through the form instead of inserting a tab.
- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (textView != self.foldersTextView) return NO;
    if (selector == @selector(insertTab:)) {
        [textView.window selectNextKeyView:nil];
        return YES;
    }
    if (selector == @selector(insertBacktab:)) {
        [textView.window selectPreviousKeyView:nil];
        return YES;
    }
    return NO;
}

#pragma mark - Hints

- (void)setHint:(NSTextField *)hint text:(NSString *)text tone:(StatusTone)tone neutralIsHelper:(BOOL)helper {
    hint.stringValue = text;
    hint.toolTip = text;
    hint.textColor = (tone == StatusTone::Neutral && helper) ? [NSColor tertiaryLabelColor] : ToneColor(tone);
}

- (void)refreshPathHints {
    const std::string cli = StdStr(Trimmed(self.cliField.stringValue));
    const std::string bun = StdStr(Trimmed(self.bunField.stringValue));
    const std::string rules = StdStr(Trimmed(self.rulesField.stringValue));
    const std::vector<std::string> environment = processEnvironmentSnapshot();  // main thread only
    const NSUInteger generation = ++self.hintGeneration;
    __weak IntakePreferencesController *weakSelf = self;
    dispatch_async(_checkQueue, ^{
        const PathHints hints = ComputePathHints(cli, bun, rules, environment);
        dispatch_async(dispatch_get_main_queue(), ^{
            IntakePreferencesController *strongSelf = weakSelf;
            if (strongSelf == nil || generation != strongSelf.hintGeneration) return;
            [strongSelf applyPathHints:hints];
        });
    });
}

- (void)applyPathHints:(const PathHints &)h {
    const bool bunAvailable = h.bun == PathCheck::Ok || (h.bun == PathCheck::Empty && !h.autoBun.empty());

    // CLI path
    if (h.cli == PathCheck::Empty) {
        [self setHint:self.cliHint
                       text:@"Not set: nothing runs and no row is tinted."
                       tone:StatusTone::Neutral
            neutralIsHelper:YES];
    } else if (h.cli != PathCheck::Ok) {
        [self setHint:self.cliHint
                       text:[NSString stringWithFormat:@"Cannot run: %s.", pathCheckText(h.cli)]
                       tone:StatusTone::Error
            neutralIsHelper:NO];
    } else if (h.script && !bunAvailable) {
        [self setHint:self.cliHint
                       text:@"A .ts script runs through bun, and bun was not found."
                       tone:StatusTone::Warning
            neutralIsHelper:NO];
    } else {
        [self setHint:self.cliHint
                       text:h.script ? @"A .ts script: runs through bun." : @"An executable file."
                       tone:StatusTone::Neutral
            neutralIsHelper:YES];
    }

    // bun
    self.bunField.placeholderString =
        h.autoBun.empty() ? @"Automatic: not found" : [NSString stringWithFormat:@"Automatic: %@", NSStr(h.autoBun)];
    if (h.bun == PathCheck::Empty) {
        [self setHint:self.bunHint
                       text:@"Empty: looks in ~/.bun/bin, /opt/homebrew/bin and /usr/local/bin."
                       tone:StatusTone::Neutral
            neutralIsHelper:YES];
    } else if (h.bun == PathCheck::Ok) {
        [self setHint:self.bunHint text:@"An executable file." tone:StatusTone::Neutral neutralIsHelper:YES];
    } else {
        NSString *text =
            h.script ? [NSString stringWithFormat:@"Cannot run: %s; the .ts CLI needs it.", pathCheckText(h.bun)]
                     : [NSString stringWithFormat:@"Cannot run: %s; ignored, this CLI does not need bun.",
                                                  pathCheckText(h.bun)];
        [self setHint:self.bunHint text:text tone:h.script ? StatusTone::Error : StatusTone::Warning neutralIsHelper:NO];
    }

    // Rules folder
    if (h.rules == PathCheck::Empty) {
        [self setHint:self.rulesHint
                       text:@"Empty: the CLI uses its own rules setting."
                       tone:StatusTone::Neutral
            neutralIsHelper:YES];
    } else if (h.rules == PathCheck::Ok) {
        [self setHint:self.rulesHint
                       text:@"The CLI reads its rules from this folder."
                       tone:StatusTone::Neutral
            neutralIsHelper:YES];
    } else {
        [self setHint:self.rulesHint
                       text:[NSString stringWithFormat:@"Not usable: %s.", pathCheckText(h.rules)]
                       tone:StatusTone::Error
            neutralIsHelper:NO];
    }

    self.cliField.accessibilityHelp = self.cliHint.stringValue;
    self.bunField.accessibilityHelp = self.bunHint.stringValue;
    self.rulesField.accessibilityHelp = self.rulesHint.stringValue;
}

- (void)refreshPrefixHint {
    const std::string from = StdStr(self.prefixFromField.stringValue);
    const std::string to = StdStr(self.prefixToField.stringValue);
    const PrefixPairCheck check = validatePrefixPair(from, to);
    switch (check) {
        case PrefixPairCheck::BothEmpty:
            [self setHint:self.prefixHint
                           text:@"Empty: no mapping. Swap to library paths will use it (not available yet)."
                           tone:StatusTone::Neutral
                neutralIsHelper:YES];
            break;
        case PrefixPairCheck::Ok:
            [self setHint:self.prefixHint
                           text:[NSString stringWithFormat:@"%@/… maps to %@/…", NSStr(normalizedPrefix(from)),
                                                           NSStr(normalizedPrefix(to))]
                           tone:StatusTone::Neutral
                neutralIsHelper:YES];
            break;
        default:
            [self setHint:self.prefixHint
                           text:[NSString stringWithFormat:@"Not usable: %s.", prefixPairCheckText(check)]
                           tone:StatusTone::Warning
                neutralIsHelper:NO];
            break;
    }
    self.prefixFromField.accessibilityHelp = self.prefixHint.stringValue;
    self.prefixToField.accessibilityHelp = self.prefixHint.stringValue;
}

// Highlights problem lines in place and lists them under the field.
- (void)refreshFolderFlags {
    NSTextView *textView = self.foldersTextView;
    NSString *text = textView.string ?: @"";
    const std::vector<FolderLine> lines = parseFolderLines(StdStr(text));

    NSLayoutManager *layout = textView.layoutManager;
    const NSRange all = NSMakeRange(0, text.length);
    [layout removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:all];
    NSArray<NSValue *> *ranges = LineRanges(text);

    // One line per problem: red for an ignored line, orange for a warning.
    NSMutableAttributedString *listing = [[NSMutableAttributedString alloc] init];
    NSFont *font = self.foldersHint.font ?: [NSFont systemFontOfSize:10];
    size_t problemCount = 0;
    size_t listed = 0;
    for (const FolderLine &line : lines) {
        if (line.problem == FolderLineProblem::None) continue;
        problemCount++;
        NSColor *color = line.problem == FolderLineProblem::NotAbsolute ? [NSColor systemRedColor]
                                                                        : [NSColor systemOrangeColor];
        if (line.line >= 1 && line.line <= ranges.count) {
            const NSRange range = ranges[line.line - 1].rangeValue;
            if (range.length > 0) {
                [layout addTemporaryAttribute:NSBackgroundColorAttributeName
                                        value:[color colorWithAlphaComponent:0.22]
                            forCharacterRange:range];
            }
        }
        if (listed < kMaxListedProblems) {
            NSString *entry = [NSString stringWithFormat:@"%@Line %zu (%@): %s", listing.length ? @"\n" : @"",
                                                         line.line, NSStr(line.text),
                                                         folderLineProblemText(line.problem)];
            [listing appendAttributedString:[[NSAttributedString alloc]
                                                initWithString:entry
                                                    attributes:@{NSFontAttributeName : font,
                                                                 NSForegroundColorAttributeName : color}]];
            listed++;
        }
    }
    if (problemCount > listed) {
        NSString *more = [NSString stringWithFormat:@"\n… and %zu more", problemCount - listed];
        [listing appendAttributedString:[[NSAttributedString alloc]
                                            initWithString:more
                                                attributes:@{NSFontAttributeName : font,
                                                             NSForegroundColorAttributeName :
                                                                 [NSColor secondaryLabelColor]}]];
    }

    if (problemCount == 0) {
        self.foldersHint.stringValue = @"One absolute path per line, added to the income folders and the folders of "
                                       @"known releases, which are always watched.";
        self.foldersHint.textColor = [NSColor tertiaryLabelColor];
    } else {
        self.foldersHint.attributedStringValue = listing;
    }
    textView.accessibilityHelp = self.foldersHint.stringValue;
}

#pragma mark - Actions

- (void)runOpenPanel:(NSOpenPanel *)panel completion:(void (^)(NSURL *url))completion {
    panel.allowsMultipleSelection = NO;
    panel.showsHiddenFiles = YES;
    NSWindow *window = self.view.window;
    if (window) {
        [panel beginSheetModalForWindow:window
                      completionHandler:^(NSModalResponse result) {
                          if (result == NSModalResponseOK && panel.URL) completion(panel.URL);
                      }];
    } else if ([panel runModal] == NSModalResponseOK && panel.URL) {
        completion(panel.URL);
    }
}

- (NSURL *)directoryURLForField:(NSTextField *)field fallback:(NSString *)fallback {
    NSString *current = Trimmed(field.stringValue);
    NSString *directory = current.length ? current.stringByDeletingLastPathComponent : fallback;
    return directory.length ? [NSURL fileURLWithPath:directory isDirectory:YES] : nil;
}

- (void)browseCli:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.message = @"Choose the intake CLI: an executable, or a .ts script that runs through bun.";
    panel.directoryURL = [self directoryURLForField:self.cliField fallback:NSHomeDirectory()];
    __weak IntakePreferencesController *weakSelf = self;
    [self runOpenPanel:panel
            completion:^(NSURL *url) {
                weakSelf.cliField.stringValue = url.path;
                [weakSelf saveAllFields];
            }];
}

- (void)browseBun:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.message = @"Choose the bun executable.";
    panel.directoryURL = [self directoryURLForField:self.bunField
                                           fallback:[NSHomeDirectory() stringByAppendingPathComponent:@".bun/bin"]];
    __weak IntakePreferencesController *weakSelf = self;
    [self runOpenPanel:panel
            completion:^(NSURL *url) {
                weakSelf.bunField.stringValue = url.path;
                [weakSelf saveAllFields];
            }];
}

- (void)browseRules:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = NO;
    panel.message = @"Choose the folder that holds the intake rules.";
    NSString *current = Trimmed(self.rulesField.stringValue);
    panel.directoryURL = [NSURL fileURLWithPath:current.length ? current : NSHomeDirectory() isDirectory:YES];
    __weak IntakePreferencesController *weakSelf = self;
    [self runOpenPanel:panel
            completion:^(NSURL *url) {
                weakSelf.rulesField.stringValue = url.path;
                [weakSelf saveAllFields];
            }];
}

- (void)logLevelChanged:(id)sender {
    const NSInteger index = self.logLevelPopup.indexOfSelectedItem;
    if (index < 0 || index > 2) return;
    config::setInt(config::kLogLevel, index);
    [self notifySettingsChanged];
}

- (void)confirmRejectChanged:(id)sender {
    config::setInt(config::kConfirmReject, self.confirmRejectCheckbox.state == NSControlStateValueOn ? 1 : 0);
    [self notifySettingsChanged];
}

- (void)testCli:(id)sender {
    [self commitEdits];
    self.testButton.enabled = NO;
    [self.testSpinner startAnimation:nil];
    self.actionResult.stringValue = @"Running intake version…";
    self.actionResult.textColor = [NSColor secondaryLabelColor];
    __weak IntakePreferencesController *weakSelf = self;
    serviceTestCli(^(bool ok, const std::string &text) {
        IntakePreferencesController *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.testButton.enabled = YES;
        [strongSelf.testSpinner stopAnimation:nil];
        strongSelf.actionResult.stringValue = [NSString stringWithFormat:@"Test CLI: %@", NSStr(text)];
        strongSelf.actionResult.textColor = ok ? [NSColor systemGreenColor] : [NSColor systemRedColor];
    });
}

- (void)reloadNow:(id)sender {
    [self commitEdits];
    // Only the latest click reports; an earlier one finishing is not it.
    const NSUInteger token = ++self.reloadToken;
    self.actionResult.stringValue = @"Reloading…";
    self.actionResult.textColor = [NSColor secondaryLabelColor];
    __weak IntakePreferencesController *weakSelf = self;
    serviceReload(true, ^(const LoaderStatus &status) {
        IntakePreferencesController *strongSelf = weakSelf;
        if (strongSelf == nil || token != strongSelf.reloadToken) return;
        strongSelf.actionResult.stringValue =
            status.state == LoaderState::Stopped ? @"Not running." : @"Reload finished.";
        strongSelf.actionResult.textColor = [NSColor secondaryLabelColor];
        [strongSelf refreshStatus];
    });
}

- (void)showComponentInfo:(NSButton *)sender {
    JLShowComponentInfo(sender, @[
        @[ @"Component", @"foo_jl_intake" ],
        @[ @"Version", @INTAKE_VERSION ],
        @[ @"Layout element", @"none (decorates SimPlaylist rows)" ],
        @[ @"Preferences", @"Tools > Intake" ],
    ]);
}

#pragma mark - Status

- (void)statusChanged:(NSNotification *)notification {
    [self refreshStatus];
}

- (void)refreshStatus {
    if (!self.isViewLoaded) return;
    const LoaderStatus status = serviceStatus();
    const StatusDisplay display = statusDisplay(status);
    self.stateValue.stringValue = NSStr(display.state);
    self.stateValue.textColor = display.tone == StatusTone::Neutral ? [NSColor labelColor] : ToneColor(display.tone);
    self.cliVersionValue.stringValue = NSStr(display.cliVersion);
    self.rootsValue.stringValue = NSStr(display.roots);
    self.errorValue.stringValue = NSStr(display.lastError);
    self.errorValue.textColor = status.error.empty() ? [NSColor labelColor] : ToneColor(display.tone);

    const IncomeDisplay income = incomeDisplay(status);
    NSMutableArray<NSArray<NSString *> *> *rows = [NSMutableArray array];
    NSMutableIndexSet *missing = [NSMutableIndexSet indexSet];
    for (const IncomeDisplayRow &row : income.rows) {
        NSString *state = income.fromCli ? (row.exists ? @"Found" : @"Missing") : @"Has releases";
        if (!row.exists) [missing addIndex:rows.count];
        [rows addObject:@[ NSStr(row.name), NSStr(row.path), state ]];
    }
    self.incomeRows = rows;
    self.missingIncomeRows = missing;
    [self.incomeTable reloadData];
    self.incomeNote.stringValue = NSStr(income.note);
}

#pragma mark - Income table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return static_cast<NSInteger>(self.incomeRows.count);
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTextField *cell = [tableView makeViewWithIdentifier:column.identifier owner:self];
    if (cell == nil) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = column.identifier;
        cell.font = [NSFont systemFontOfSize:11];
        cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    if (row < 0 || static_cast<NSUInteger>(row) >= self.incomeRows.count) return cell;
    NSArray<NSString *> *values = self.incomeRows[static_cast<NSUInteger>(row)];
    NSString *identifier = column.identifier;
    const BOOL missing = [self.missingIncomeRows containsIndex:static_cast<NSUInteger>(row)];
    if ([identifier isEqualToString:@"name"]) {
        cell.stringValue = values[0];
        cell.textColor = [NSColor labelColor];
    } else if ([identifier isEqualToString:@"path"]) {
        cell.stringValue = values[1];
        cell.toolTip = values[1];
        cell.textColor = missing ? [NSColor secondaryLabelColor] : [NSColor labelColor];
    } else {
        cell.stringValue = values[2];
        cell.textColor = missing ? [NSColor systemOrangeColor] : [NSColor secondaryLabelColor];
    }
    return cell;
}

@end
