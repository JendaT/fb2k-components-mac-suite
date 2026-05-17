#pragma once

#import <Cocoa/Cocoa.h>

@class AlbumItem;
@class AlbumTrack;

NS_ASSUME_NONNULL_BEGIN

extern NSPasteboardType const AlbumViewVancedPasteboardType;

@protocol AlbumGridViewDelegate <NSObject>
/// Double-click album: replace active playlist and play from first track
- (void)albumGridView:(id)gridView wantsPlayAlbum:(AlbumItem *)album;
/// Double-click track in expanded list: replace active playlist and play from that track
- (void)albumGridView:(id)gridView wantsPlayTrack:(AlbumTrack *)track inAlbum:(AlbumItem *)album;
- (void)albumGridView:(id)gridView requestsContextMenuForAlbum:(AlbumItem *)album atPoint:(NSPoint)point;
- (void)albumGridView:(id)gridView requestsContextMenuForTrack:(AlbumTrack *)track inAlbum:(AlbumItem *)album atPoint:(NSPoint)point;
- (void)albumGridView:(id)gridView wantsQueueAlbum:(AlbumItem *)album;
- (void)albumGridView:(id)gridView wantsQueueTrack:(AlbumTrack *)track inAlbum:(AlbumItem *)album;
@end

@interface AlbumGridView : NSView <NSDraggingSource>

@property (nonatomic, weak) id<AlbumGridViewDelegate> delegate;
@property (nonatomic, strong, nullable) NSArray<AlbumItem *> *albums;
@property (nonatomic, assign) CGFloat thumbnailSize;

/// Index of the album whose track list is expanded, or NSNotFound.
@property (nonatomic, assign, readonly) NSInteger expandedAlbumIndex;

- (void)reloadData;
- (void)recalcFrameHeight;
- (void)collapseExpandedAlbum;
- (void)scrollToAlbumWithTrackPath:(NSString *)path;

/// The currently selected album, if any.
- (nullable AlbumItem *)selectedAlbum;

/// The currently selected track (inside expanded album), if any.
- (nullable AlbumTrack *)selectedTrack;

@end

NS_ASSUME_NONNULL_END
