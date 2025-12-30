//
//  ScrobbleWidgetView.h
//  foo_jl_scrobble_mac
//
//  Custom NSView for displaying Last.fm stats widget
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class TopAlbum;
@class ScrobbleWidgetView;

@protocol ScrobbleWidgetViewDelegate <NSObject>
@optional
- (void)widgetViewRequestsRefresh:(ScrobbleWidgetView *)view;
- (void)widgetViewRequestsContextMenu:(ScrobbleWidgetView *)view atPoint:(NSPoint)point;
- (void)widgetViewOpenLastFmProfile:(ScrobbleWidgetView *)view;
// Period navigation (Weekly/Monthly/All Time)
- (void)widgetViewNavigatePreviousPeriod:(ScrobbleWidgetView *)view;
- (void)widgetViewNavigateNextPeriod:(ScrobbleWidgetView *)view;
// Type navigation (Albums/Artists/Tracks)
- (void)widgetViewNavigatePreviousType:(ScrobbleWidgetView *)view;
- (void)widgetViewNavigateNextType:(ScrobbleWidgetView *)view;
// Album click
- (void)widgetView:(ScrobbleWidgetView *)view didClickAlbumAtIndex:(NSInteger)index;
@end

/// View state for the widget
typedef NS_ENUM(NSInteger, ScrobbleWidgetState) {
    ScrobbleWidgetStateLoading,      // Initial load in progress
    ScrobbleWidgetStateNotAuth,      // User not authenticated
    ScrobbleWidgetStateEmpty,        // No data available
    ScrobbleWidgetStateReady,        // Data loaded and ready
    ScrobbleWidgetStateError         // Error occurred
};

/// Chart time period types
typedef NS_ENUM(NSInteger, ScrobbleChartPeriod) {
    ScrobbleChartPeriodWeekly = 0,   // 7 day
    ScrobbleChartPeriodMonthly,      // 1 month
    ScrobbleChartPeriodOverall,      // All time
    ScrobbleChartPeriodCount         // Sentinel for counting
};

/// Chart item types
typedef NS_ENUM(NSInteger, ScrobbleChartType) {
    ScrobbleChartTypeAlbums = 0,     // Top albums
    ScrobbleChartTypeArtists,        // Top artists
    ScrobbleChartTypeTracks,         // Top tracks
    ScrobbleChartTypeCount           // Sentinel for counting
};

// Legacy aliases for compatibility
typedef ScrobbleChartPeriod ScrobbleChartPage;
#define ScrobbleChartPageWeekly ScrobbleChartPeriodWeekly
#define ScrobbleChartPageMonthly ScrobbleChartPeriodMonthly
#define ScrobbleChartPageOverall ScrobbleChartPeriodOverall
#define ScrobbleChartPageCount ScrobbleChartPeriodCount

@interface ScrobbleWidgetView : NSView

// Delegate for handling interactions
@property (nonatomic, weak, nullable) id<ScrobbleWidgetViewDelegate> delegate;

// Current state
@property (nonatomic, assign) ScrobbleWidgetState state;
@property (nonatomic, copy, nullable) NSString *errorMessage;

// Profile info
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, strong, nullable) NSImage *profileImage;

// Current chart settings
@property (nonatomic, assign) ScrobbleChartPeriod currentPeriod;
@property (nonatomic, assign) ScrobbleChartType currentType;
@property (nonatomic, copy, nullable) NSString *periodTitle;  // e.g., "Weekly"
@property (nonatomic, copy, nullable) NSString *typeTitle;    // e.g., "Top Albums"

// Legacy alias
@property (nonatomic, assign) ScrobbleChartPage currentPage;  // Maps to currentPeriod
@property (nonatomic, copy, nullable) NSString *chartTitle;   // Maps to combined title

// Album grid data
@property (nonatomic, copy, nullable) NSArray<TopAlbum *> *topAlbums;
@property (nonatomic, strong, nullable) NSDictionary<NSURL*, NSImage*> *albumImages;  // Loaded images by URL
@property (nonatomic, assign) NSInteger maxAlbums;  // Max albums to show (for scaling)

// Navigation arrows
@property (nonatomic, assign) BOOL canNavigatePrevious;
@property (nonatomic, assign) BOOL canNavigateNext;

// Status info
@property (nonatomic, assign) NSInteger scrobbledToday;
@property (nonatomic, assign) NSInteger queueCount;
@property (nonatomic, strong, nullable) NSDate *lastUpdated;

// Loading overlay - keeps content visible while refreshing
@property (nonatomic, assign) BOOL isRefreshing;

// Update UI with current data
- (void)refreshDisplay;

// Get API period string
+ (NSString *)apiPeriodForPeriod:(ScrobbleChartPeriod)period;

// Get display titles
+ (NSString *)titleForPeriod:(ScrobbleChartPeriod)period;
+ (NSString *)titleForType:(ScrobbleChartType)type;

// Legacy aliases
+ (NSString *)periodForPage:(ScrobbleChartPage)page;
+ (NSString *)titleForPage:(ScrobbleChartPage)page;

@end

NS_ASSUME_NONNULL_END
