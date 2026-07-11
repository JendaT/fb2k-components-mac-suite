//
//  SimPlaylistHeaderBar.h
//  foo_simplaylist_mac
//
//  Column header bar with resize and reorder support
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "../../../../shared/UIStyles.h"

NS_ASSUME_NONNULL_BEGIN

@class ColumnDefinition;
@protocol SimPlaylistHeaderBarDelegate;

@interface SimPlaylistHeaderBar : NSView

@property (nonatomic, weak, nullable) id<SimPlaylistHeaderBarDelegate> delegate;
@property (nonatomic, strong) NSArray<ColumnDefinition *> *columns;
@property (nonatomic, assign) CGFloat groupColumnWidth;
// Width of the decorator icon gutter between the group column and the first
// content column (0 unless a row decorator provider exists). Keeps header
// cells aligned with the shifted content columns in SimPlaylistView.
@property (nonatomic, assign) CGFloat decorationGutterWidth;

// Style settings (set by controller based on config)
@property (nonatomic, assign) fb2k_ui::SizeVariant headerSize;
@property (nonatomic, assign) fb2k_ui::AccentMode accentMode;
@property (nonatomic, assign) BOOL glassBackground;

// Sync horizontal scroll with main view
- (void)setScrollOffset:(CGFloat)offset;

@end

@protocol SimPlaylistHeaderBarDelegate <NSObject>

@optional
// Column resize - called during drag
- (void)headerBar:(SimPlaylistHeaderBar *)bar didResizeColumn:(NSInteger)columnIndex toWidth:(CGFloat)newWidth;

// Column resize finished
- (void)headerBar:(SimPlaylistHeaderBar *)bar didFinishResizingColumn:(NSInteger)columnIndex;

// Group column (album art) resize
- (void)headerBar:(SimPlaylistHeaderBar *)bar didResizeGroupColumnToWidth:(CGFloat)newWidth;
- (void)headerBar:(SimPlaylistHeaderBar *)bar didFinishResizingGroupColumn:(CGFloat)finalWidth;

// Column reorder
- (void)headerBar:(SimPlaylistHeaderBar *)bar didReorderColumnFrom:(NSInteger)fromIndex to:(NSInteger)toIndex;

// Column click (for sorting)
- (void)headerBar:(SimPlaylistHeaderBar *)bar didClickColumn:(NSInteger)columnIndex;

// Right-click context menu for column configuration
- (void)headerBar:(SimPlaylistHeaderBar *)bar showColumnMenuAtPoint:(NSPoint)point;

@end

NS_ASSUME_NONNULL_END
