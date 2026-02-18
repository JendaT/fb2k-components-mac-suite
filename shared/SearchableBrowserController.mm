//
//  SearchableBrowserController.mm
//  Shared UI component for searchable browser panels
//

#import "SearchableBrowserController.h"
#import "UIStyles.h"
#include <foobar2000/SDK/foobar2000.h>

// Column identifiers
static NSString* const kTitleColumnID = @"TitleColumn";
static NSString* const kDurationColumnID = @"DurationColumn";

@interface SearchableBrowserController ()
@property (nonatomic, strong) NSSegmentedControl* segmentSelector;
@property (nonatomic, strong) NSTextField* searchField;
@property (nonatomic, strong) NSButton* searchButton;
@property (nonatomic, strong) NSScrollView* scrollView;
@property (nonatomic, strong) NSTableView* tableView;
@property (nonatomic, strong) NSTextField* statusBar;
@property (nonatomic, strong) NSTimer* debounceTimer;
@property (nonatomic, readwrite) BrowserState state;
@end

@implementation SearchableBrowserController

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = BrowserStateEmpty;
        _transparentBackground = NO;
        _debounceInterval = 0.5;
        _selectedSegment = 0;
    }
    return self;
}

- (void)dealloc {
    [_debounceTimer invalidate];
}

- (void)loadView {
    NSView* rootView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
    rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = rootView;

    [self setupSegmentSelector];
    [self setupSearchBar];
    [self setupTableView];
    [self setupStatusBar];
    [self updateStatusBar];
}

#pragma mark - UI Setup

- (void)setupSegmentSelector {
    NSArray<NSString*>* titles = nil;
    if ([_dataSource respondsToSelector:@selector(segmentTitlesForBrowser:)]) {
        titles = [_dataSource segmentTitlesForBrowser:self];
    }

    if (!titles || titles.count == 0) {
        return; // No selector needed
    }

    CGFloat padding = 8;

    _segmentSelector = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    _segmentSelector.translatesAutoresizingMaskIntoConstraints = NO;
    _segmentSelector.segmentCount = titles.count;
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        [_segmentSelector setLabel:titles[i] forSegment:i];
    }
    _segmentSelector.segmentStyle = NSSegmentStyleTexturedRounded;
    _segmentSelector.selectedSegment = _selectedSegment;
    _segmentSelector.target = self;
    _segmentSelector.action = @selector(segmentChanged:);
    [self.view addSubview:_segmentSelector];

    [NSLayoutConstraint activateConstraints:@[
        [_segmentSelector.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:padding],
        [_segmentSelector.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-padding],
        [_segmentSelector.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:padding],
        [_segmentSelector.heightAnchor constraintEqualToConstant:24],
    ]];
}

- (void)setupSearchBar {
    CGFloat searchBarHeight = 32;
    CGFloat padding = 8;

    // Search field
    _searchField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = @"Search...";
    _searchField.bezelStyle = NSTextFieldRoundedBezel;
    _searchField.font = [NSFont systemFontOfSize:13];
    _searchField.delegate = self;
    _searchField.target = self;
    _searchField.action = @selector(searchFieldAction:);
    [self.view addSubview:_searchField];

    // Update placeholder from data source
    if ([_dataSource respondsToSelector:@selector(searchPlaceholderForBrowser:)]) {
        _searchField.placeholderString = [_dataSource searchPlaceholderForBrowser:self];
    }

    // Search button
    _searchButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _searchButton.translatesAutoresizingMaskIntoConstraints = NO;
    _searchButton.title = @"Search";
    _searchButton.bezelStyle = NSBezelStyleRounded;
    _searchButton.target = self;
    _searchButton.action = @selector(searchButtonClicked:);
    [self.view addSubview:_searchButton];

    // Layout depends on whether segment selector exists
    NSLayoutAnchor* topAnchor = _segmentSelector ?
        _segmentSelector.bottomAnchor : self.view.topAnchor;

    [NSLayoutConstraint activateConstraints:@[
        [_searchField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:padding],
        [_searchField.topAnchor constraintEqualToAnchor:topAnchor constant:padding],
        [_searchField.heightAnchor constraintEqualToConstant:searchBarHeight - padding],

        [_searchButton.leadingAnchor constraintEqualToAnchor:_searchField.trailingAnchor constant:padding],
        [_searchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-padding],
        [_searchButton.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],
        [_searchButton.widthAnchor constraintEqualToConstant:70],
    ]];

    // Low priority for search field to allow button to take precedence
    [_searchField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
}

- (void)setupTableView {
    CGFloat selectorHeight = _segmentSelector ? 32 : 0;
    CGFloat searchBarHeight = 32;
    CGFloat statusBarHeight = 24;
    CGFloat padding = 8;

    // Scroll view
    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.borderType = NSNoBorder;

    if (_transparentBackground) {
        _scrollView.drawsBackground = NO;
    }
    [self.view addSubview:_scrollView];

    // Table view
    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.headerView = nil;
    _tableView.rowHeight = fb2k_ui::kDefaultRowHeight;
    _tableView.intercellSpacing = NSMakeSize(0, 0);
    _tableView.usesAlternatingRowBackgroundColors = YES;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _tableView.allowsMultipleSelection = NO;
    _tableView.doubleAction = @selector(tableViewDoubleClicked:);
    _tableView.target = self;

    // Enable drag
    [_tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [_tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];

    if (_transparentBackground) {
        _tableView.backgroundColor = [NSColor clearColor];
    }

    // Title column (flexible width)
    NSTableColumn* titleColumn = [[NSTableColumn alloc] initWithIdentifier:kTitleColumnID];
    titleColumn.title = @"Title";
    titleColumn.minWidth = 100;
    titleColumn.resizingMask = NSTableColumnAutoresizingMask;
    [_tableView addTableColumn:titleColumn];

    // Duration column (fixed width)
    NSTableColumn* durationColumn = [[NSTableColumn alloc] initWithIdentifier:kDurationColumnID];
    durationColumn.title = @"Duration";
    durationColumn.width = 60;
    durationColumn.minWidth = 50;
    durationColumn.maxWidth = 80;
    durationColumn.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:durationColumn];

    _scrollView.documentView = _tableView;

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:selectorHeight + searchBarHeight + padding],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-statusBarHeight],
    ]];
}

- (void)setupStatusBar {
    CGFloat statusBarHeight = 24;
    CGFloat padding = 8;

    _statusBar = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    _statusBar.editable = NO;
    _statusBar.selectable = NO;
    _statusBar.bordered = NO;
    _statusBar.drawsBackground = NO;
    _statusBar.font = [NSFont systemFontOfSize:11];
    _statusBar.textColor = [NSColor secondaryLabelColor];
    _statusBar.alignment = NSTextAlignmentCenter;
    _statusBar.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.view addSubview:_statusBar];

    [NSLayoutConstraint activateConstraints:@[
        [_statusBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:padding],
        [_statusBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-padding],
        [_statusBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-4],
        [_statusBar.heightAnchor constraintEqualToConstant:statusBarHeight - 8],
    ]];
}

- (void)updateStatusBar {
    NSString* text = nil;

    if ([_dataSource respondsToSelector:@selector(browser:statusTextForState:)]) {
        text = [_dataSource browser:self statusTextForState:_state];
    }

    if (!text) {
        // Default status text
        switch (_state) {
            case BrowserStateEmpty:
                text = @"Enter a search term";
                break;
            case BrowserStateSearching:
                text = @"Searching...";
                break;
            case BrowserStateResults: {
                NSInteger count = [self numberOfResultsInBrowser:self];
                text = [NSString stringWithFormat:@"%ld result%@", (long)count, count == 1 ? @"" : @"s"];
                break;
            }
            case BrowserStateNoResults:
                text = @"No results found";
                break;
            case BrowserStateError:
                text = @"Search failed";
                break;
        }
    }

    _statusBar.stringValue = text ?: @"";
}

#pragma mark - Actions

- (void)segmentChanged:(id)sender {
    _selectedSegment = _segmentSelector.selectedSegment;

    if ([_dataSource respondsToSelector:@selector(browser:didSelectSegment:)]) {
        [_dataSource browser:self didSelectSegment:_selectedSegment];
    }
}

- (void)searchFieldAction:(id)sender {
    [self triggerSearch];
}

- (void)searchButtonClicked:(id)sender {
    [self triggerSearch];
}

- (void)triggerSearch {
    [_debounceTimer invalidate];
    _debounceTimer = nil;

    NSString* query = _searchField.stringValue;
    if (query.length == 0) {
        return;
    }

    if ([_dataSource respondsToSelector:@selector(browser:performSearch:)]) {
        [_dataSource browser:self performSearch:query];
    }
}

- (void)tableViewDoubleClicked:(id)sender {
    NSInteger row = _tableView.clickedRow;
    if (row < 0) return;

    if ([_dataSource respondsToSelector:@selector(browser:didDoubleClickRow:)]) {
        [_dataSource browser:self didDoubleClickRow:row];
    }
}

#pragma mark - Public Methods

- (void)setState:(BrowserState)state {
    _state = state;
    [self updateStatusBar];
}

- (void)reloadData {
    [_tableView reloadData];
    [self updateStatusBar];
}

- (NSString*)currentQuery {
    return _searchField.stringValue;
}

- (void)setSearchQuery:(NSString*)query {
    _searchField.stringValue = query ?: @"";
}

- (NSInteger)selectedRow {
    return _tableView.selectedRow;
}

- (void)setStatusText:(NSString*)text {
    _statusBar.stringValue = text ?: @"";
}

- (void)setSearchPlaceholder:(NSString*)placeholder {
    _searchField.placeholderString = placeholder ?: @"Search...";
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return [self numberOfResultsInBrowser:self];
}

- (NSInteger)numberOfResultsInBrowser:(SearchableBrowserController*)browser {
    if ([_dataSource respondsToSelector:@selector(numberOfResultsInBrowser:)]) {
        return [_dataSource numberOfResultsInBrowser:self];
    }
    return 0;
}

#pragma mark - NSTableViewDelegate

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
    NSString* identifier = tableColumn.identifier;

    NSTextField* cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[NSTextField alloc] initWithFrame:NSZeroRect];
        cell.identifier = identifier;
        cell.bordered = NO;
        cell.editable = NO;
        cell.selectable = NO;
        cell.drawsBackground = NO;
        cell.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.font = [NSFont systemFontOfSize:12.0];
    }

    if ([identifier isEqualToString:kTitleColumnID]) {
        NSString* title = @"";
        if ([_dataSource respondsToSelector:@selector(browser:titleForRow:)]) {
            title = [_dataSource browser:self titleForRow:row] ?: @"";
        }
        cell.stringValue = title;
        cell.alignment = NSTextAlignmentLeft;
    } else if ([identifier isEqualToString:kDurationColumnID]) {
        NSString* info = @"";
        if ([_dataSource respondsToSelector:@selector(browser:secondaryInfoForRow:)]) {
            info = [_dataSource browser:self secondaryInfoForRow:row] ?: @"";
        }
        cell.stringValue = info;
        cell.alignment = NSTextAlignmentRight;
        cell.textColor = [NSColor secondaryLabelColor];
    }

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    NSInteger row = _tableView.selectedRow;
    if (row < 0) return;

    if ([_dataSource respondsToSelector:@selector(browser:didClickRow:)]) {
        [_dataSource browser:self didClickRow:row];
    }
}

#pragma mark - Drag Support

- (id<NSPasteboardWriting>)tableView:(NSTableView*)tableView pasteboardWriterForRow:(NSInteger)row {
    NSString* urlString = nil;
    if ([_dataSource respondsToSelector:@selector(browser:urlStringForRow:)]) {
        urlString = [_dataSource browser:self urlStringForRow:row];
    }

    if (!urlString || urlString.length == 0) {
        return nil;
    }

    // Create pasteboard item with URL and String types for compatibility
    // This enables drag-drop to SimPlaylist and other URL-accepting targets
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    [item setString:urlString forType:NSPasteboardTypeURL];
    [item setString:urlString forType:NSPasteboardTypeString];

    return item;
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification*)notification {
    // Debounce search input
    [_debounceTimer invalidate];
    _debounceTimer = [NSTimer scheduledTimerWithTimeInterval:_debounceInterval
                                                      target:self
                                                    selector:@selector(debounceTimerFired:)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)debounceTimerFired:(NSTimer*)timer {
    [self triggerSearch];
}

#pragma mark - Keyboard Handling

- (void)keyDown:(NSEvent*)event {
    NSString* chars = event.charactersIgnoringModifiers;
    if (chars.length == 0) {
        [super keyDown:event];
        return;
    }

    unichar key = [chars characterAtIndex:0];
    NSEventModifierFlags modifiers = event.modifierFlags;
    BOOL hasCommand = (modifiers & NSEventModifierFlagCommand) != 0;

    switch (key) {
        case NSCarriageReturnCharacter:
        case NSEnterCharacter:
            if (hasCommand) {
                // Cmd+Enter: double-click action
                NSInteger row = _tableView.selectedRow;
                if (row >= 0 && [_dataSource respondsToSelector:@selector(browser:didDoubleClickRow:)]) {
                    [_dataSource browser:self didDoubleClickRow:row];
                }
            } else {
                // Enter: single-click action
                NSInteger row = _tableView.selectedRow;
                if (row >= 0 && [_dataSource respondsToSelector:@selector(browser:didClickRow:)]) {
                    [_dataSource browser:self didClickRow:row];
                }
            }
            break;

        case 27: // Escape
            if ([_dataSource respondsToSelector:@selector(browserCancelSearch:)]) {
                [_dataSource browserCancelSearch:self];
            }
            break;

        default:
            [super keyDown:event];
            break;
    }
}

@end
