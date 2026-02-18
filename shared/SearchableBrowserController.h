//
//  SearchableBrowserController.h
//  Shared UI component for searchable browser panels
//
//  Provides a reusable base for browser-style UI elements with:
//  - Optional segmented control for source/category selection
//  - Search field with debouncing
//  - Table view with two columns (title + secondary info)
//  - Drag support for URLs (compatible with SimPlaylist drop)
//  - Status bar with state feedback
//  - fb2k_ui styling
//
//  Usage: Subclass and implement the required delegate methods.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Browser state
typedef NS_ENUM(NSInteger, BrowserState) {
    BrowserStateEmpty,       // Initial state, no search performed
    BrowserStateSearching,   // Search in progress
    BrowserStateResults,     // Search completed with results
    BrowserStateNoResults,   // Search completed with no results
    BrowserStateError        // Search failed with error
};

@class SearchableBrowserController;

// Protocol for browser data source and actions
@protocol SearchableBrowserDataSource <NSObject>

@required
// Number of results to display
- (NSInteger)numberOfResultsInBrowser:(SearchableBrowserController*)browser;

// Title for row (main column)
- (NSString*)browser:(SearchableBrowserController*)browser titleForRow:(NSInteger)row;

// Secondary info for row (duration column) - can return nil
- (nullable NSString*)browser:(SearchableBrowserController*)browser secondaryInfoForRow:(NSInteger)row;

// URL string for drag operation (e.g., "soundcloud://track/123")
- (nullable NSString*)browser:(SearchableBrowserController*)browser urlStringForRow:(NSInteger)row;

// Perform search with query
- (void)browser:(SearchableBrowserController*)browser performSearch:(NSString*)query;

// Cancel current search
- (void)browserCancelSearch:(SearchableBrowserController*)browser;

@optional
// Segment titles for selector (return nil or empty to hide selector)
- (nullable NSArray<NSString*>*)segmentTitlesForBrowser:(SearchableBrowserController*)browser;

// Called when segment selection changes
- (void)browser:(SearchableBrowserController*)browser didSelectSegment:(NSInteger)segment;

// Placeholder text for search field (default: "Search...")
- (NSString*)searchPlaceholderForBrowser:(SearchableBrowserController*)browser;

// Status text for given state
- (NSString*)browser:(SearchableBrowserController*)browser statusTextForState:(BrowserState)state;

// Single click action (default: add to playlist)
- (void)browser:(SearchableBrowserController*)browser didClickRow:(NSInteger)row;

// Double click action (default: add and play)
- (void)browser:(SearchableBrowserController*)browser didDoubleClickRow:(NSInteger)row;

@end

@interface SearchableBrowserController : NSViewController <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>

// Data source (weak reference)
@property (nonatomic, weak, nullable) id<SearchableBrowserDataSource> dataSource;

// Current state
@property (nonatomic, readonly) BrowserState state;

// Selected segment index (0-based)
@property (nonatomic) NSInteger selectedSegment;

// Transparent background mode
@property (nonatomic) BOOL transparentBackground;

// Debounce interval in seconds (default: 0.5)
@property (nonatomic) NSTimeInterval debounceInterval;

// Update state and refresh UI
- (void)setState:(BrowserState)state;

// Reload table data
- (void)reloadData;

// Get current search query
- (NSString*)currentQuery;

// Set search query programmatically
- (void)setSearchQuery:(NSString*)query;

// Get selected row index (-1 if none)
- (NSInteger)selectedRow;

// Update status bar text
- (void)setStatusText:(NSString*)text;

// Update search placeholder
- (void)setSearchPlaceholder:(NSString*)placeholder;

@end

NS_ASSUME_NONNULL_END
