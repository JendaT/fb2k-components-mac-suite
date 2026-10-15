//
//  BpmResultsWindowController.mm
//  foo_jl_bpm_mac
//

#import "BpmResultsWindowController.h"

#include "../Core/BpmValue.h"
#include "../Core/TempoEstimator.h"
#include "../Integration/BpmJob.h"
#include "../Integration/BpmTagWriter.h"

#include <cmath>

static NSString *const kColumnWrite = @"write";
static NSString *const kColumnTrack = @"track";
static NSString *const kColumnTag = @"tag";
static NSString *const kColumnNew = @"new";
static NSString *const kColumnCompare = @"compare";
static NSString *const kColumnSource = @"source";

// ---------------------------------------------------------------------------
// One table row
// ---------------------------------------------------------------------------

@interface BpmResultItem : NSObject
@property (nonatomic) NSUInteger jobIndex;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *currentText;
@property (nonatomic) double currentValue;  // NAN when the tag is missing or unreadable
@property (nonatomic) double value;         // NAN when there is no result
@property (nonatomic, copy) NSString *sourceText;
@property (nonatomic) BOOL writable;
@property (nonatomic) BOOL checked;
@property (nonatomic, readonly) BOOL hasValue;
@property (nonatomic, readonly) NSString *tagText;         // what Write Tags writes
@property (nonatomic, readonly) NSString *comparisonText;  // same / double / half / different
@property (nonatomic, readonly) double currentSortKey;
@property (nonatomic, readonly) double valueSortKey;
- (void)resetChecked;
@end

@implementation BpmResultItem

- (BOOL)hasValue {
    return !std::isnan(self.value);
}

- (NSString *)tagText {
    return self.hasValue ? @(bpm::formatBpmTag(self.value).c_str()) : @"";
}

- (NSString *)comparisonText {
    if (!self.hasValue || std::isnan(self.currentValue)) return @"";
    switch (bpm::compareBpm(self.currentValue, self.value)) {
        case bpm::Agreement::Same: return @"same";
        case bpm::Agreement::Double: return @"double";
        case bpm::Agreement::Half: return @"half";
        case bpm::Agreement::Different: return @"different";
    }
    return @"";
}

// Sort keys: rows without a number sort first.
- (double)currentSortKey {
    return std::isnan(self.currentValue) ? -1.0 : self.currentValue;
}

- (double)valueSortKey {
    return self.hasValue ? self.value : -1.0;
}

// Checked by default when writing would change the tag.
- (void)resetChecked {
    self.checked = self.writable && self.hasValue &&
                   !(!std::isnan(self.currentValue) && std::fabs(std::round(self.value) - self.currentValue) < 0.5);
}

@end

// ---------------------------------------------------------------------------
// Window controller
// ---------------------------------------------------------------------------

@interface BpmResultsWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@end

@implementation BpmResultsWindowController {
    std::shared_ptr<bpm::AnalysisJob> _job;
    NSArray<BpmResultItem *> *_items;
    NSTableView *_table;
    NSTextField *_summary;
    NSButton *_writeButton;
}

static NSMutableSet<BpmResultsWindowController *> *g_openWindows;

+ (void)showResultsForJob:(std::shared_ptr<bpm::AnalysisJob>)job {
    if (!job || job->rows.empty()) return;
    if (!g_openWindows) g_openWindows = [NSMutableSet set];
    BpmResultsWindowController *controller = [[BpmResultsWindowController alloc] initWithJob:std::move(job)];
    [g_openWindows addObject:controller];
    [controller showWindow:nil];
    [controller.window makeKeyAndOrderFront:nil];
}

- (instancetype)initWithJob:(std::shared_ptr<bpm::AnalysisJob>)job {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 820, 480)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:YES];
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(560, 280);
    self = [super initWithWindow:window];
    if (!self) return nil;

    _job = std::move(job);
    _items = [self buildItems];
    window.title = [NSString stringWithFormat:@"BPM Analysis: %lu track%@", (unsigned long)_items.count,
                                              _items.count == 1 ? @"" : @"s"];
    window.delegate = self;
    [self buildContent];
    [window center];
    window.frameAutosaveName = @"JLBpmAnalysisResults";
    [self updateSummary];
    return self;
}

- (NSArray<BpmResultItem *> *)buildItems {
    titleformat_object::ptr script;
    titleformat_compiler::get()->compile_safe(script, "[%artist% - ]%title%");

    NSMutableArray<BpmResultItem *> *items = [NSMutableArray arrayWithCapacity:_job->rows.size()];
    for (size_t i = 0; i < _job->rows.size(); i++) {
        const bpm::TrackRow &row = _job->rows[i];
        BpmResultItem *item = [BpmResultItem new];
        item.jobIndex = i;

        pfc::string8 title;
        row.handle->format_title(nullptr, title, script, nullptr);
        item.title = @(title.c_str()) ?: @"";
        item.currentText = @(row.currentTag.c_str()) ?: @"";
        item.currentValue = row.currentBpm ? *row.currentBpm : NAN;
        item.value = row.source != bpm::ResultSource::None ? row.bpm : NAN;
        item.writable = row.isLocalFile && row.source != bpm::ResultSource::None;

        switch (row.source) {
            case bpm::ResultSource::Tidal:
                item.sourceText = row.isLocalFile ? @"TIDAL (ISRC match)" : @"TIDAL (stream, tag not writable)";
                break;
            case bpm::ResultSource::Analysis:
                item.sourceText = row.strength < bpm::kWeakPulseStrength ? @"Analysis (no clear beat)" : @"Analysis";
                break;
            case bpm::ResultSource::None:
                item.sourceText = @(row.problem.c_str()) ?: @"";
                break;
        }
        [item resetChecked];
        [items addObject:item];
    }
    return items;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

- (NSTableColumn *)columnWithIdentifier:(NSString *)identifier
                                  title:(NSString *)title
                                  width:(CGFloat)width
                                sortKey:(nullable NSString *)sortKey {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
    column.title = title;
    column.width = width;
    column.minWidth = MIN(width, 40);
    column.resizingMask = NSTableColumnUserResizingMask;  // window resizes go to Track and Source
    if (sortKey) column.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:sortKey ascending:YES];
    return column;
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    return button;
}

- (void)buildContent {
    NSView *content = self.window.contentView;

    _table = [[NSTableView alloc] init];
    _table.dataSource = self;
    _table.delegate = self;
    _table.allowsMultipleSelection = YES;
    _table.usesAlternatingRowBackgroundColors = YES;
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _table.style = NSTableViewStyleFullWidth;

    NSTableColumn *write = [self columnWithIdentifier:kColumnWrite title:@"" width:24 sortKey:nil];
    write.minWidth = 24;
    write.maxWidth = 24;
    write.headerToolTip = @"Write this value";
    [_table addTableColumn:write];
    NSTableColumn *track = [self columnWithIdentifier:kColumnTrack title:@"Track" width:330 sortKey:@"title"];
    track.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [_table addTableColumn:track];
    [_table addTableColumn:[self columnWithIdentifier:kColumnTag title:@"Tag" width:60 sortKey:@"currentSortKey"]];
    [_table addTableColumn:[self columnWithIdentifier:kColumnNew title:@"New" width:60 sortKey:@"valueSortKey"]];
    [_table addTableColumn:[self columnWithIdentifier:kColumnCompare
                                                title:@"vs Tag"
                                                width:70
                                              sortKey:@"comparisonText"]];
    NSTableColumn *source = [self columnWithIdentifier:kColumnSource title:@"Source" width:220 sortKey:@"sourceText"];
    source.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [_table addTableColumn:source];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = _table;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    [content addSubview:scroll];

    _summary = [NSTextField wrappingLabelWithString:@""];
    _summary.translatesAutoresizingMaskIntoConstraints = NO;
    _summary.textColor = NSColor.secondaryLabelColor;
    _summary.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    [_summary setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [content addSubview:_summary];

    NSButton *doubleButton = [self buttonWithTitle:@"Double" action:@selector(doubleSelected:)];
    doubleButton.toolTip = @"Double the new value of the selected rows";
    NSButton *halveButton = [self buttonWithTitle:@"Halve" action:@selector(halveSelected:)];
    halveButton.toolTip = @"Halve the new value of the selected rows";
    NSButton *cancelButton = [self buttonWithTitle:@"Cancel" action:@selector(cancel:)];
    cancelButton.keyEquivalent = @"\e";
    _writeButton = [self buttonWithTitle:@"Write Tags" action:@selector(writeTags:)];
    _writeButton.keyEquivalent = @"\r";
    for (NSButton *b in @[ doubleButton, halveButton, cancelButton, _writeButton ]) [content addSubview:b];

    const CGFloat margin = 16;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:content.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:_writeButton.topAnchor constant:-12],

        [_writeButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],
        [_writeButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-margin],
        [cancelButton.trailingAnchor constraintEqualToAnchor:_writeButton.leadingAnchor constant:-8],
        [cancelButton.centerYAnchor constraintEqualToAnchor:_writeButton.centerYAnchor],
        [halveButton.trailingAnchor constraintEqualToAnchor:cancelButton.leadingAnchor constant:-20],
        [halveButton.centerYAnchor constraintEqualToAnchor:_writeButton.centerYAnchor],
        [doubleButton.trailingAnchor constraintEqualToAnchor:halveButton.leadingAnchor constant:-8],
        [doubleButton.centerYAnchor constraintEqualToAnchor:_writeButton.centerYAnchor],

        [_summary.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [_summary.trailingAnchor constraintLessThanOrEqualToAnchor:doubleButton.leadingAnchor constant:-16],
        [_summary.centerYAnchor constraintEqualToAnchor:_writeButton.centerYAnchor],
    ]];
}

// ---------------------------------------------------------------------------
// Table
// ---------------------------------------------------------------------------

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_items.count;
}

- (NSTextField *)labelForTable:(NSTableView *)tableView identifier:(NSString *)identifier {
    NSTextField *label = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!label) {
        label = [NSTextField labelWithString:@""];
        label.identifier = identifier;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        label.cell.truncatesLastVisibleLine = YES;
    }
    return label;
}

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(nullable NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    BpmResultItem *item = _items[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:kColumnWrite]) {
        NSButton *box = [tableView makeViewWithIdentifier:kColumnWrite owner:self];
        if (!box) {
            box = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleChecked:)];
            box.identifier = kColumnWrite;
        }
        box.state = item.checked ? NSControlStateValueOn : NSControlStateValueOff;
        box.enabled = item.writable && item.hasValue;
        return box;
    }

    NSTextField *label = [self labelForTable:tableView identifier:identifier];
    label.toolTip = nil;
    label.alignment = NSTextAlignmentLeft;
    label.textColor = NSColor.labelColor;
    if ([identifier isEqualToString:kColumnTrack]) {
        label.stringValue = item.title;
        label.toolTip = @(_job->rows[item.jobIndex].handle->get_path());
    } else if ([identifier isEqualToString:kColumnTag]) {
        label.stringValue = item.currentText;
        label.alignment = NSTextAlignmentRight;
    } else if ([identifier isEqualToString:kColumnNew]) {
        label.stringValue = item.tagText;
        label.alignment = NSTextAlignmentRight;
        if (item.hasValue) label.toolTip = @(bpm::formatBpmDisplay(item.value).c_str());
    } else if ([identifier isEqualToString:kColumnCompare]) {
        NSString *text = item.comparisonText;
        label.stringValue = text;
        if ([text isEqualToString:@"double"] || [text isEqualToString:@"half"]) {
            label.textColor = NSColor.systemOrangeColor;
        } else if ([text isEqualToString:@"different"]) {
            label.textColor = NSColor.systemRedColor;
        } else {
            label.textColor = NSColor.secondaryLabelColor;
        }
    } else if ([identifier isEqualToString:kColumnSource]) {
        label.stringValue = item.sourceText;
        label.textColor = item.hasValue ? NSColor.labelColor : NSColor.secondaryLabelColor;
        label.toolTip = item.sourceText;
    }
    return label;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    _items = [_items sortedArrayUsingDescriptors:tableView.sortDescriptors];
    [tableView reloadData];
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

- (void)toggleChecked:(NSButton *)sender {
    const NSInteger row = [_table rowForView:sender];
    if (row < 0) return;
    _items[(NSUInteger)row].checked = sender.state == NSControlStateValueOn;
    [self updateSummary];
}

- (void)scaleSelectedBy:(double)factor {
    NSIndexSet *rows = _table.selectedRowIndexes;
    if (rows.count == 0) {
        NSBeep();
        return;
    }
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *) {
        BpmResultItem *item = self->_items[row];
        if (!item.hasValue) return;
        item.value *= factor;
        [item resetChecked];
    }];
    [_table reloadDataForRowIndexes:rows
                      columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)_table.numberOfColumns)]];
    [self updateSummary];
}

- (void)doubleSelected:(id)sender {
    [self scaleSelectedBy:2.0];
}

- (void)halveSelected:(id)sender {
    [self scaleSelectedBy:0.5];
}

- (void)cancel:(id)sender {
    [self.window performClose:sender];
}

- (void)writeTags:(id)sender {
    metadb_handle_list handles;
    std::vector<std::string> values;
    for (BpmResultItem *item in _items) {
        if (!item.checked || !item.writable || !item.hasValue) continue;
        handles.add_item(_job->rows[item.jobIndex].handle);
        values.push_back(bpm::formatBpmTag(item.value));
    }
    if (!values.empty()) bpm::writeBpmTags(handles, values);
    [self.window performClose:sender];
}

- (void)updateSummary {
    NSUInteger tidal = 0, analysed = 0, failed = 0, same = 0, octave = 0, different = 0, toWrite = 0;
    for (BpmResultItem *item in _items) {
        const bpm::TrackRow &row = _job->rows[item.jobIndex];
        if (row.source == bpm::ResultSource::Tidal) tidal++;
        else if (row.source == bpm::ResultSource::Analysis) analysed++;
        else failed++;
        if (item.checked) toWrite++;

        NSString *comparison = item.comparisonText;
        if ([comparison isEqualToString:@"same"]) same++;
        else if ([comparison isEqualToString:@"double"] || [comparison isEqualToString:@"half"]) octave++;
        else if ([comparison isEqualToString:@"different"]) different++;
    }

    NSMutableString *text = [NSMutableString stringWithFormat:@"%lu from TIDAL, %lu analyzed, %lu without result.",
                                                              (unsigned long)tidal, (unsigned long)analysed,
                                                              (unsigned long)failed];
    if (same + octave + different > 0) {
        [text appendFormat:@" Against existing tags: %lu same, %lu half or double, %lu different.",
                           (unsigned long)same, (unsigned long)octave, (unsigned long)different];
    }
    _summary.stringValue = text;
    _writeButton.title = toWrite > 0 ? [NSString stringWithFormat:@"Write %lu Tag%@", (unsigned long)toWrite,
                                                                  toWrite == 1 ? @"" : @"s"]
                                     : @"Write Tags";
    _writeButton.enabled = toWrite > 0;
}

// ---------------------------------------------------------------------------
// NSWindowDelegate
// ---------------------------------------------------------------------------

- (void)windowWillClose:(NSNotification *)notification {
    _table.dataSource = nil;
    _table.delegate = nil;
    [g_openWindows removeObject:self];
}

@end
