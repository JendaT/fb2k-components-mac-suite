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
- (void)albumGridView:(id)gridView wantsSetRating:(NSInteger)rating forAlbum:(AlbumItem *)album;
- (void)albumGridView:(id)gridView wantsSetRating:(NSInteger)rating forTrack:(AlbumTrack *)track inAlbum:(AlbumItem *)album;
@end

@interface AlbumGridView : NSView <NSDraggingSource>

@property (nonatomic, weak) id<AlbumGridViewDelegate> delegate;
@property (nonatomic, strong, nullable) NSArray<AlbumItem *> *albums;
@property (nonatomic, assign) CGFloat thumbnailSize;

/// Index of the first album shown under the "Appears on" label, or NSNotFound for no section.
/// Set after `albums`.
@property (nonatomic, assign) NSInteger appearsOnStartIndex;

/// Index of the album whose track list is expanded, or NSNotFound.
@property (nonatomic, assign, readonly) NSInteger expandedAlbumIndex;

/// When set, a single click on an album card calls this instead of expanding it inline
/// (the grid never expands while it is set). nil restores inline expansion.
@property (nonatomic, copy, nullable) void (^openAlbumHandler)(AlbumItem *album);

/// Replaces the albums. With resetSelection:NO (data-only rebuild) the selected and expanded
/// albums are re-found by identity (artist + album + date) and track indices are clamped.
- (void)setAlbums:(nullable NSArray<AlbumItem *> *)albums resetSelection:(BOOL)reset;

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
