//
//  StrawberryImportPreviewController.h
//  foo_jl_plorg
//

#import <Cocoa/Cocoa.h>

@class TreeNode;

NS_ASSUME_NONNULL_BEGIN

// Represents a playlist item from Strawberry for preview
@interface StrawberryPlaylistItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *uiPath;  // Folder path in Strawberry
@property (nonatomic, assign) int64_t playlistId;
@property (nonatomic, assign) NSInteger trackCount;
@property (nonatomic, assign) BOOL isSelected;
@property (nonatomic, strong) NSMutableArray<NSString *> *trackPaths;  // Cached track paths
@end

// Represents a folder in the preview tree
@interface StrawberryPreviewFolder : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSMutableArray *children;  // StrawberryPreviewFolder or StrawberryPlaylistItem
@property (nonatomic, assign) BOOL isExpanded;
- (BOOL)isFolder;
- (NSInteger)totalTrackCount;
- (BOOL)hasSelectedItems;
- (BOOL)allItemsSelected;
- (void)setAllSelected:(BOOL)selected;
@end

@protocol StrawberryImportPreviewDelegate <NSObject>
- (void)strawberryImportDidComplete:(NSArray<StrawberryPlaylistItem *> *)selectedPlaylists
                       targetFolder:(nullable TreeNode *)targetFolder;
- (void)strawberryImportDidCancel;
@end

@interface StrawberryImportPreviewController : NSWindowController <NSOutlineViewDataSource, NSOutlineViewDelegate>

@property (nonatomic, weak, nullable) id<StrawberryImportPreviewDelegate> delegate;
@property (nonatomic, strong, nullable) TreeNode *targetFolder;  // Where to import into plorg tree

- (void)loadFromStrawberryDatabase;

@end

NS_ASSUME_NONNULL_END
