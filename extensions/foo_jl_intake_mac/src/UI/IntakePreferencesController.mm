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
//   - Share links (B11): local symlinks to the music share (the plorg
//     shadow link), one absolute path per line. Every line gets a flag
//     under the field, after the hint: where the link points ("→ <target>
//     (share <name>)" / "(not on a share)") or why it is not used ("not a
//     symlink", "missing", "on a network volume: ignored", ...), with the
//     unused lines highlighted. The links are read on the check queue with
//     the same rules as the loader (readShareLink: the mount table first,
//     lstat/readlink only on local paths, never inside a network mount;
//     summarizeShareLink), when the page loads or appears and after every
//     edit.
//   - Library mapping: one prefix pair, NAS path prefix -> Mac path prefix,
//     stored lexically clean (normalizedPrefix) and validated; Swap to
//     library paths and the library index use it (B9).
//   - Row colours (B10): one NSColorWell per tint_* key (New, Needs
//     review, Proposed, Approved / placing, Placed, Rejected), a "No tint"
//     checkbox beside each (stores 0) and Reset colours (removes the six
//     keys, so the defaults apply). A well's colour is converted to sRGB
//     (a colour that cannot be converted keeps the stored value) and packed
//     to 0xRRGGBBAA (IntakeTint packRgba); while a well is active the shared
//     colour panel shows its opacity slider (IntakePrefsColorWell). Changes
//     while the panel is dragged are written 0.25 s after the last one, so
//     the rows are rebuilt once, not per mouse move.
//   - Confirmations (B6, B10): "Ask before Delete local copy" (confirm_gc)
//     and "Ask before Reject" (confirm_reject), both default on, with the
//     note that Execute always asks. The menu titles' ellipsis follows them
//     at the next menu (serviceActionInfo), no restart.
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
//  and the checkboxes at once, a colour well 0.25 s after its last change
//  (or when the page goes away); then IntakeSettingsDidChangeNotification
//  is posted and IntakeService applies it without a restart.
//
//  Keyboard: the key view order runs top to bottom through every control
//  (Tab in the watched folders and share links fields moves on instead of
//  inserting a tab);
//  it joins the host's key view loop when there is one after the page's
//  root view, else it closes inside the page (joinHostKeyViewLoop). Every
//  control has an accessibility label.
//
//  Wrapping labels (status values, the Test CLI result, the folder
//  problems, the share link flags, the hints under the path and mapping
//  fields) wrap at their own
//  width (IntakePrefsWrappingLabel), so they fit the column at any page
//  width. A hint is a sentence, often with paths in it: cut in the middle it
//  loses its point, so only the fields and table cells that hold a bare path
//  truncate in the middle.
//

#import "IntakePreferencesController.h"

#include "../Integration/IntakeConfig.h"
#include "../Integration/IntakeMounts.h"
#include "../Integration/IntakeService.h"

#include "../Core/IntakeCommandArgs.h"
#include "../Core/IntakeLoadPolicy.h"
#include "../Core/IntakeMountAliases.h"
#include "../Core/IntakeSettingsParse.h"
#include "../Core/IntakeTint.h"
#include "../Core/IntakeWatchSet.h"

#import "../../../../shared/PreferencesCommon.h"
#include "../Integration/ComponentInfo.h"

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
// A colour well's change is written this long after the last one.
constexpr NSTimeInterval kTintWriteDelay = 0.25;

// A stored tint (0xRRGGBBAA, sRGB) as a colour for a well.
NSColor *ColourForTint(IntakeRgba rgba) {
    const RgbaUnits u = unpackRgba(rgba);
    return [NSColor colorWithSRGBRed:u.red green:u.green blue:u.blue alpha:u.alpha];
}

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

// B11: the line under the share links field before the flags.
NSString *const kShareLinksHint = @"Symlinks to the music share, one per line. Their rows match the share's releases "
                                  @"while the link points at a mounted share.";

// One share links line and its flag (B11).
struct ShareLinkFlag {
    size_t line = 0;   // FolderLine::line
    std::string text;  // the line as typed, trimmed
    std::string flag;
    // Neutral: the loader uses the link; Warning: it does not (or the line
    // repeats an earlier one); Error: not a usable path.
    StatusTone tone = StatusTone::Neutral;
};

// Check queue only: reads the links (readShareLink: lstat/readlink on local
// paths only, decided from the mount table first) and says what the
// loader's table makes of each (summarizeShareLink).
std::vector<ShareLinkFlag> ComputeShareLinkFlags(const std::string &text) {
    std::vector<ShareLinkFlag> out;
    const std::vector<FolderLine> lines = parseFolderLines(text);
    if (lines.empty()) return out;
    const std::vector<MountEntry> mounts = readMountTable();
    const LinkReader reader = &posixLinkReader;
    for (const FolderLine &line : lines) {
        ShareLinkFlag f;
        f.line = line.line;
        f.text = line.text;
        switch (line.problem) {
            case FolderLineProblem::NotAbsolute:
                f.flag = folderLineProblemText(line.problem);
                f.tone = StatusTone::Error;
                break;
            case FolderLineProblem::Root:
                // parseShareLinks drops it (every path lies under "/").
                f.flag = "the root folder (ignored)";
                f.tone = StatusTone::Error;
                break;
            case FolderLineProblem::Duplicate:
                f.flag = folderLineProblemText(line.problem);
                f.tone = StatusTone::Warning;
                break;
            case FolderLineProblem::None: {
                const ShareLinkSummary summary = summarizeShareLink(readShareLink(line.text, mounts, reader), mounts);
                f.flag = summary.text;
                f.tone = summary.used ? StatusTone::Neutral : StatusTone::Warning;
                break;
            }
        }
        out.push_back(std::move(f));
    }
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

// A colour well that shows the shared colour panel's opacity slider while
// one of the page's wells is active, and puts the panel's own setting back
// when the last one deactivates (the panel is shared with foobar2000 and
// other components). The count covers a switch from one well to another:
// the new one activates (exclusive) and the old one deactivates inside it.
// The classic style: the macOS 13 minimal style's popover has no opacity
// control.
static NSInteger g_activeTintWells = 0;
static BOOL g_savedShowsAlpha = NO;

@interface IntakePrefsColorWell : NSColorWell
@end
@implementation IntakePrefsColorWell
- (void)activate:(BOOL)exclusive {
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    if (!self.isActive) {
        if (g_activeTintWells == 0) g_savedShowsAlpha = panel.showsAlpha;
        g_activeTintWells++;
    }
    [super activate:exclusive];
    panel.showsAlpha = YES;
}
- (void)deactivate {
    const BOOL wasActive = self.isActive;
    [super deactivate];
    if (!wasActive || g_activeTintWells == 0) return;
    if (--g_activeTintWells == 0) [NSColorPanel sharedColorPanel].showsAlpha = g_savedShowsAlpha;
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

@property (nonatomic, strong) NSTextView *shareLinksTextView;  // B11
@property (nonatomic, strong) NSTextField *shareLinksHint;

@property (nonatomic, strong) NSTextField *prefixFromField;
@property (nonatomic, strong) NSTextField *prefixToField;
@property (nonatomic, strong) NSTextField *prefixHint;

@property (nonatomic, copy) NSArray<NSColorWell *> *tintWells;     // in kTintSlots order
@property (nonatomic, copy) NSArray<NSButton *> *tintOffCheckboxes; // in kTintSlots order
@property (nonatomic, strong) NSButton *resetColoursButton;

@property (nonatomic, strong) NSButton *confirmGcCheckbox;
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
@property (nonatomic, copy) NSString *savedShareLinks;
@property (nonatomic, copy) NSString *savedPrefixFrom;
@property (nonatomic, copy) NSString *savedPrefixTo;

@property (nonatomic, assign) BOOL observingStatus;
@property (nonatomic, assign) NSUInteger reloadToken;  // the latest Reload now click
@property (nonatomic, assign) NSUInteger hintGeneration;
@property (nonatomic, assign) NSUInteger linkFlagGeneration;  // the latest share link check
@end

@implementation IntakePreferencesController {
    dispatch_queue_t _checkQueue;  // path checks (stat) and share link reads, off the main thread
    IntakePalette _savedTints;     // the tint_* values last written (or read)
    IntakePalette _pendingTints;   // well colours not written yet
    uint32_t _pendingTintMask;     // bit i: kTintSlots[i] is pending
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

// Helper text (10 pt, tertiary) that wraps at the column's width.
- (NSTextField *)wrappingHelper:(NSString *)text {
    NSTextField *label = [self wrappingLabel];
    label.stringValue = text;
    label.font = [NSFont systemFontOfSize:10];
    label.textColor = [NSColor tertiaryLabelColor];
    label.selectable = NO;
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
    self.cliHint = [self wrappingHelper:@""];
    self.bunField = [self fieldWithPlaceholder:@"Automatic" accessibilityLabel:@"bun path"];
    self.bunBrowseButton = [self buttonWithTitle:@"Browse…"
                                          action:@selector(browseBun:)
                              accessibilityLabel:@"Choose bun"];
    self.bunHint = [self wrappingHelper:@""];
    self.rulesField = [self fieldWithPlaceholder:@"The CLI's own configuration" accessibilityLabel:@"Rules folder"];
    self.rulesBrowseButton = [self buttonWithTitle:@"Browse…"
                                            action:@selector(browseRules:)
                                accessibilityLabel:@"Choose the rules folder"];
    self.rulesHint = [self wrappingHelper:@""];
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
    NSScrollView *foldersScroll =
        [self buildPathListWithAccessibilityLabel:@"Watched folders, one absolute path per line"];
    self.foldersTextView = foldersScroll.documentView;
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

    // ===== Share links (B11) =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Share links")];
    NSScrollView *linksScroll =
        [self buildPathListWithAccessibilityLabel:@"Share links, one absolute symlink path per line"];
    self.shareLinksTextView = linksScroll.documentView;
    self.shareLinksHint = [self wrappingLabel];
    self.shareLinksHint.font = [NSFont systemFontOfSize:10];
    self.shareLinksHint.textColor = [NSColor tertiaryLabelColor];
    self.shareLinksHint.selectable = NO;
    self.shareLinksHint.stringValue = kShareLinksHint;  // the flags follow once the links are read
    NSGridView *linksGrid = [self gridWithRows:@[
        @[ JLCreateLabel(@"Links:"), linksScroll, [self empty] ],
        @[ [self empty], self.shareLinksHint, [self empty] ],
    ]];
    NSGridRow *linksRow = [linksGrid rowAtIndex:0];
    linksRow.rowAlignment = NSGridRowAlignmentNone;
    linksRow.yPlacement = NSGridCellPlacementTop;
    addFullWidth(linksGrid);
    [stack setCustomSpacing:JLPrefsSectionGap afterView:linksGrid];

    // ===== Library mapping =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Library mapping (for Swap to library paths)")];
    self.prefixFromField = [self fieldWithPlaceholder:@"e.g. /share/library" accessibilityLabel:@"NAS path prefix"];
    self.prefixToField = [self fieldWithPlaceholder:@"e.g. /Volumes/library" accessibilityLabel:@"Mac path prefix"];
    self.prefixHint = [self wrappingHelper:@""];
    NSGridView *prefixGrid = [self gridWithRows:@[
        @[ JLCreateLabel(@"NAS path prefix:"), self.prefixFromField, [self empty] ],
        @[ JLCreateLabel(@"Mac path prefix:"), self.prefixToField, [self empty] ],
        @[ [self empty], self.prefixHint, [self empty] ],
    ]];
    addFullWidth(prefixGrid);
    [stack setCustomSpacing:JLPrefsSectionGap afterView:prefixGrid];

    // ===== Row colours =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Row colours")];
    NSMutableArray<NSColorWell *> *wells = [NSMutableArray array];
    NSMutableArray<NSButton *> *offBoxes = [NSMutableArray array];
    NSMutableArray<NSArray<NSView *> *> *colourRows = [NSMutableArray array];
    NSMutableArray<NSStackView *> *colourStacks = [NSMutableArray array];
    for (TintSlot slot : kTintSlots) {
        NSString *label = @(tintLabel(slot));
        IntakePrefsColorWell *well = [[IntakePrefsColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 22)];
        well.target = self;
        well.action = @selector(tintWellChanged:);
        well.accessibilityLabel = [NSString stringWithFormat:@"%@ row colour", label];
        well.translatesAutoresizingMaskIntoConstraints = NO;
        [well.widthAnchor constraintEqualToConstant:44].active = YES;
        [well.heightAnchor constraintEqualToConstant:22].active = YES;
        NSButton *off = [NSButton checkboxWithTitle:@"No tint" target:self action:@selector(tintOffChanged:)];
        off.font = [NSFont systemFontOfSize:11];
        off.accessibilityLabel = [NSString stringWithFormat:@"No tint for %@ rows", label];
        NSStackView *pair = [NSStackView stackViewWithViews:@[ well, off ]];
        pair.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        pair.alignment = NSLayoutAttributeCenterY;
        pair.spacing = 10;
        [wells addObject:well];
        [offBoxes addObject:off];
        [colourStacks addObject:pair];
        [colourRows addObject:@[ JLCreateLabel([label stringByAppendingString:@":"]), pair, [self empty] ]];
    }
    self.tintWells = wells;
    self.tintOffCheckboxes = offBoxes;
    self.resetColoursButton = [self buttonWithTitle:@"Reset colours"
                                             action:@selector(resetColours:)
                                 accessibilityLabel:@"Reset the row colours to the defaults"];
    NSTextField *coloursHint = [self wrappingHelper:@"Row backgrounds, with opacity. Icons that take a colour use "
                                                    @"it at full opacity; on a tint of 60% opacity or more they use "
                                                    @"the text colour. No tint: normal background, normal icon "
                                                    @"colour."];
    [colourRows addObject:@[ [self empty], self.resetColoursButton, [self empty] ]];
    [colourRows addObject:@[ [self empty], coloursHint, [self empty] ]];
    NSGridView *coloursGrid = [self gridWithRows:colourRows];
    for (NSStackView *pair in colourStacks) {
        [coloursGrid cellForView:pair].xPlacement = NSGridCellPlacementLeading;
        // The well has no baseline: centre the row instead.
        NSGridRow *row = [coloursGrid cellForView:pair].row;
        row.rowAlignment = NSGridRowAlignmentNone;
        row.yPlacement = NSGridCellPlacementCenter;
    }
    [coloursGrid cellForView:self.resetColoursButton].xPlacement = NSGridCellPlacementLeading;
    [coloursGrid cellForView:self.resetColoursButton].row.topPadding = 4;
    addFullWidth(coloursGrid);
    [stack setCustomSpacing:JLPrefsSectionGap afterView:coloursGrid];

    // ===== Confirmations =====
    [stack addArrangedSubview:JLCreateSectionHeader(@"Confirmations")];
    self.confirmGcCheckbox = [NSButton checkboxWithTitle:@"Ask before Delete local copy"
                                                  target:self
                                                  action:@selector(confirmGcChanged:)];
    self.confirmGcCheckbox.font = [NSFont systemFontOfSize:11];
    self.confirmGcCheckbox.accessibilityLabel = @"Ask before Delete local copy";
    NSTextField *gcHint =
        [self wrappingHelper:@"Lists the local files and offers Swap, then delete. Off: the local copy is deleted at "
                             @"once."];
    self.confirmRejectCheckbox = [NSButton checkboxWithTitle:@"Ask before Reject"
                                                      target:self
                                                      action:@selector(confirmRejectChanged:)];
    self.confirmRejectCheckbox.font = [NSFont systemFontOfSize:11];
    self.confirmRejectCheckbox.accessibilityLabel = @"Ask before Reject";
    NSTextField *rejectHint = [self wrappingHelper:@"Lists the albums and asks for an optional reason. Off: Reject "
                                                   @"runs at once, without a reason."];
    NSTextField *executeNote = [self wrappingHelper:@"Execute placement always asks: it lists what it will place."];
    NSGridView *confirmGrid = [self gridWithRows:@[
        @[ [self empty], self.confirmGcCheckbox, [self empty] ],
        @[ [self empty], gcHint, [self empty] ],
        @[ [self empty], self.confirmRejectCheckbox, [self empty] ],
        @[ [self empty], rejectHint, [self empty] ],
        @[ [self empty], executeNote, [self empty] ],
    ]];
    [confirmGrid cellForView:self.confirmGcCheckbox].xPlacement = NSGridCellPlacementLeading;
    [confirmGrid cellForView:self.confirmRejectCheckbox].xPlacement = NSGridCellPlacementLeading;
    [confirmGrid rowAtIndex:2].topPadding = 4;
    [confirmGrid rowAtIndex:4].topPadding = 4;
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

// A multi-line path list (watched folders, share links); the text view is
// the scroll view's documentView.
- (NSScrollView *)buildPathListWithAccessibilityLabel:(NSString *)label {
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
    textView.accessibilityLabel = label;
    scroll.documentView = textView;

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
    NSArray *columns = @[ @[ @"name", @"Name", @90 ], @[ @"state", @"State", @92 ], @[ @"path", @"Folder", @260 ] ];
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
    NSMutableArray<NSView *> *order = [NSMutableArray arrayWithArray:@[
        self.infoButton,      self.cliField,      self.cliBrowseButton, self.bunField,
        self.bunBrowseButton, self.rulesField,    self.rulesBrowseButton, self.foldersTextView,
        self.shareLinksTextView, self.prefixFromField, self.prefixToField,
    ]];
    for (NSUInteger i = 0; i < self.tintWells.count; i++) {
        [order addObject:self.tintWells[i]];
        [order addObject:self.tintOffCheckboxes[i]];
    }
    [order addObjectsFromArray:@[
        self.resetColoursButton, self.confirmGcCheckbox, self.confirmRejectCheckbox, self.logLevelPopup,
        self.testButton, self.reloadButton, self.incomeTable,
    ]];
    for (NSUInteger i = 0; i < order.count; i++) {
        order[i].nextKeyView = order[(i + 1) % order.count];
    }
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadSettings];
    [self refreshFolderFlags];
    [self refreshShareLinkFlags];
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
    // B11: the mount agent may have re-pointed a link meanwhile.
    [self refreshShareLinkFlags];
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
    // The colour panel must not keep editing a well that is going away.
    for (NSColorWell *well in self.tintWells) [well deactivate];
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
    self.savedShareLinks = NSStr(config::getString(config::kShareLinks, ""));
    self.savedPrefixFrom = NSStr(normalizedPrefix(config::getString(config::kSwapPrefixFrom, "")));
    self.savedPrefixTo = NSStr(normalizedPrefix(config::getString(config::kSwapPrefixTo, "")));

    self.cliField.stringValue = self.savedCli;
    self.bunField.stringValue = self.savedBun;
    self.rulesField.stringValue = self.savedRules;
    self.foldersTextView.string = self.savedFolders;
    self.shareLinksTextView.string = self.savedShareLinks;
    self.prefixFromField.stringValue = self.savedPrefixFrom;
    self.prefixToField.stringValue = self.savedPrefixTo;

    int64_t level = config::getInt(config::kLogLevel, config::defaultLogLevel());
    if (level < 0) level = 0;
    if (level > 2) level = 2;
    [self.logLevelPopup selectItemAtIndex:static_cast<NSInteger>(level)];

    self.confirmRejectCheckbox.state =
        confirmSetting(config::getInt(config::kConfirmReject, kConfirmSettingDefault)) ? NSControlStateValueOn
                                                                                       : NSControlStateValueOff;
    self.confirmGcCheckbox.state =
        confirmSetting(config::getInt(config::kConfirmGc, kConfirmSettingDefault)) ? NSControlStateValueOn
                                                                                   : NSControlStateValueOff;
    [self loadTints];
}

// The wells and checkboxes from the stored tint_* values. A tint of 0 shows
// the default colour in a disabled well, so unticking No tint brings it
// back.
- (void)loadTints {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushTints) object:nil];
    _pendingTintMask = 0;
    _savedTints = config::loadPalette();
    const IntakePalette defaults;
    for (size_t i = 0; i < kTintSlotCount && i < self.tintWells.count; i++) {
        const IntakeRgba value = tintOf(_savedTints, kTintSlots[i]);
        const BOOL off = value == 0;
        self.tintWells[i].color = ColourForTint(off ? tintOf(defaults, kTintSlots[i]) : value);
        self.tintWells[i].enabled = !off;
        self.tintOffCheckboxes[i].state = off ? NSControlStateValueOn : NSControlStateValueOff;
    }
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

// Every text control and the pending well colours, written when changed;
// one notification for all.
- (void)saveAllFields {
    if (!self.isViewLoaded) return;
    BOOL changed = [self writePendingTints];
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
    // B11: stored as typed, like watch_folders (parseShareLinks cleans
    // each line when the settings are read).
    NSString *links = [self.shareLinksTextView.string copy];
    if ([self saveString:links key:config::kShareLinks saved:self.savedShareLinks]) {
        self.savedShareLinks = links;
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
    if (notification.object == self.shareLinksTextView) [self refreshShareLinkFlags];
}

- (void)textDidEndEditing:(NSNotification *)notification {
    if (notification.object == self.foldersTextView || notification.object == self.shareLinksTextView) {
        [self saveAllFields];
    }
}

// Tab and Shift-Tab move through the form instead of inserting a tab.
- (BOOL)textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (textView != self.foldersTextView && textView != self.shareLinksTextView) return NO;
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
                           text:@"Empty: no mapping. Swap to library paths uses the target paths the CLI reports."
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

// B11: reads the share links on the check queue (the field may name a path
// under a symlink into a share: readShareLink decides from the mount table
// before it examines anything), then shows one flag per line. A newer edit
// supersedes a check still running.
- (void)refreshShareLinkFlags {
    const std::string text = StdStr(self.shareLinksTextView.string ?: @"");
    const NSUInteger generation = ++self.linkFlagGeneration;
    __weak IntakePreferencesController *weakSelf = self;
    dispatch_async(_checkQueue, ^{
        auto flags = std::make_shared<std::vector<ShareLinkFlag>>(ComputeShareLinkFlags(text));
        dispatch_async(dispatch_get_main_queue(), ^{
            IntakePreferencesController *strongSelf = weakSelf;
            if (strongSelf == nil || generation != strongSelf.linkFlagGeneration) return;
            [strongSelf applyShareLinkFlags:*flags];
        });
    });
}

// The hint, then one line per link: unused links in orange (highlighted in
// the field), lines that are not usable paths in red, used links in the
// secondary colour. The text is the one the flags were read from: every
// edit starts a newer check, which discards this one.
- (void)applyShareLinkFlags:(const std::vector<ShareLinkFlag> &)flags {
    NSTextView *textView = self.shareLinksTextView;
    NSString *text = textView.string ?: @"";
    NSLayoutManager *layout = textView.layoutManager;
    [layout removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:NSMakeRange(0, text.length)];
    NSArray<NSValue *> *ranges = LineRanges(text);

    NSFont *font = self.shareLinksHint.font ?: [NSFont systemFontOfSize:10];
    NSMutableAttributedString *listing = [[NSMutableAttributedString alloc]
        initWithString:kShareLinksHint
            attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : [NSColor tertiaryLabelColor]}];
    size_t listed = 0;
    for (const ShareLinkFlag &f : flags) {
        NSColor *color = f.tone == StatusTone::Neutral ? [NSColor secondaryLabelColor] : ToneColor(f.tone);
        if (f.tone != StatusTone::Neutral && f.line >= 1 && f.line <= ranges.count) {
            const NSRange range = ranges[f.line - 1].rangeValue;
            if (range.length > 0 && NSMaxRange(range) <= text.length) {
                [layout addTemporaryAttribute:NSBackgroundColorAttributeName
                                        value:[color colorWithAlphaComponent:0.22]
                            forCharacterRange:range];
            }
        }
        if (listed < kMaxListedProblems) {
            NSString *entry =
                [NSString stringWithFormat:@"\nLine %zu (%@): %@", f.line, NSStr(f.text), NSStr(f.flag)];
            [listing appendAttributedString:[[NSAttributedString alloc]
                                                initWithString:entry
                                                    attributes:@{NSFontAttributeName : font,
                                                                 NSForegroundColorAttributeName : color}]];
            listed++;
        }
    }
    if (flags.size() > listed) {
        NSString *more = [NSString stringWithFormat:@"\n… and %zu more", flags.size() - listed];
        [listing appendAttributedString:[[NSAttributedString alloc]
                                            initWithString:more
                                                attributes:@{NSFontAttributeName : font,
                                                             NSForegroundColorAttributeName :
                                                                 [NSColor secondaryLabelColor]}]];
    }
    self.shareLinksHint.attributedStringValue = listing;
    textView.accessibilityHelp = self.shareLinksHint.stringValue;
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

- (void)confirmGcChanged:(id)sender {
    config::setInt(config::kConfirmGc, self.confirmGcCheckbox.state == NSControlStateValueOn ? 1 : 0);
    [self notifySettingsChanged];
}

#pragma mark - Row colours

// The well's colour in sRGB, packed; false when it cannot be converted (a
// pattern colour, for one).
- (BOOL)packedColourOf:(NSColorWell *)well into:(IntakeRgba *)out {
    NSColor *srgb = [well.color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (srgb == nil) return NO;
    *out = packRgba(srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent);
    return YES;
}

- (void)tintWellChanged:(NSColorWell *)well {
    const NSUInteger index = [self.tintWells indexOfObjectIdenticalTo:well];
    if (index == NSNotFound || index >= kTintSlotCount) return;
    const TintSlot slot = kTintSlots[index];
    IntakeRgba packed = 0;
    if (![self packedColourOf:well into:&packed]) {
        // Not convertible to sRGB: the stored value stays, and so does the
        // colour shown for it.
        const IntakeRgba kept = (_pendingTintMask & (1u << index)) ? tintOf(_pendingTints, slot) : tintOf(_savedTints, slot);
        well.color = ColourForTint(kept != 0 ? kept : tintOf(IntakePalette(), slot));
        return;
    }
    setTint(_pendingTints, slot, packed);
    _pendingTintMask |= 1u << index;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushTints) object:nil];
    [self performSelector:@selector(flushTints) withObject:nil afterDelay:kTintWriteDelay];
}

- (void)flushTints {
    if ([self writePendingTints]) [self notifySettingsChanged];
}

// Writes the pending well colours that differ from the stored ones. A well
// that came out fully transparent black packs to 0, which means no tint:
// the page shows it as such. Returns whether it wrote.
- (BOOL)writePendingTints {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushTints) object:nil];
    if (_pendingTintMask == 0) return NO;
    BOOL wrote = NO;
    for (size_t i = 0; i < kTintSlotCount; i++) {
        if (!(_pendingTintMask & (1u << i))) continue;
        const TintSlot slot = kTintSlots[i];
        const IntakeRgba value = tintOf(_pendingTints, slot);
        if (value == 0 && i < self.tintWells.count) {
            self.tintOffCheckboxes[i].state = NSControlStateValueOn;
            [self.tintWells[i] deactivate];
            self.tintWells[i].color = ColourForTint(tintOf(IntakePalette(), slot));
            self.tintWells[i].enabled = NO;
        }
        if (value == tintOf(_savedTints, slot)) continue;
        config::setInt(tintKey(slot), static_cast<int64_t>(value));
        setTint(_savedTints, slot, value);
        wrote = YES;
    }
    _pendingTintMask = 0;
    return wrote;
}

- (void)tintOffChanged:(NSButton *)sender {
    const NSUInteger index = [self.tintOffCheckboxes indexOfObjectIdenticalTo:sender];
    if (index == NSNotFound || index >= kTintSlotCount || index >= self.tintWells.count) return;
    const TintSlot slot = kTintSlots[index];
    // Other wells' pending colours go first; this slot's is replaced.
    _pendingTintMask &= ~(1u << index);
    BOOL changed = [self writePendingTints];
    NSColorWell *well = self.tintWells[index];
    IntakeRgba value = 0;
    if (sender.state == NSControlStateValueOn) {
        [well deactivate];
        well.enabled = NO;
    } else {
        well.enabled = YES;
        if (![self packedColourOf:well into:&value] || value == 0) value = tintOf(IntakePalette(), slot);
        well.color = ColourForTint(value);
    }
    if (value != tintOf(_savedTints, slot)) {
        config::setInt(tintKey(slot), static_cast<int64_t>(value));
        setTint(_savedTints, slot, value);
        changed = YES;
    }
    if (changed) [self notifySettingsChanged];
}

// Removes the six keys: the defaults apply again.
- (void)resetColours:(id)sender {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushTints) object:nil];
    _pendingTintMask = 0;
    for (NSColorWell *well in self.tintWells) [well deactivate];
    for (TintSlot slot : kTintSlots) config::deleteInt(tintKey(slot));
    const BOOL changed = !(_savedTints == IntakePalette());
    [self loadTints];
    if (changed) [self notifySettingsChanged];
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
        @[ @"Component", @JL_COMPONENT_FILE ],
        @[ @"Version", @JL_COMPONENT_VERSION ],
        @[ @"Layout element", @JL_LAYOUT_ELEMENT_NOTE ],
        @[ @"Preferences", @JL_PREFERENCES_PATH ],
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
