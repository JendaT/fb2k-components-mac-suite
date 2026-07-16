//
//  DecorationCoordinator.h
//  foo_simplaylist_mac
//
//  SDK-aware bridge between jl_row_decorator_provider services (shared suite
//  API, intake doc 04 Part A) and the pure DecorationStore the view reads.
//
//  Owned by SimPlaylistController, one per panel instance. Created ONLY when
//  at least one provider service is registered (zero-provider guard: the
//  factory returns nil and nothing else in the panel touches decorations).
//
//  Responsibilities:
//  - enumerate providers once at panel init
//  - resolve playlist indices to metadb handles and batch-query providers
//    off the main thread (visible range + overscan, driven by the view's
//    prepare callback)
//  - commit results to the DecorationStore on the main thread and trigger a
//    redraw via the invalidation handler
//  - observe provider invalidate callbacks and metadb changes
//  - surface provider context actions as menu items
//
//  All public methods are main-thread only.
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "../fb2k_sdk.h"
#import "../Core/DecorationStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface DecorationCoordinator : NSObject

// Returns nil when no jl_row_decorator_provider service is registered.
// invalidationHandler is called on the main thread whenever cached
// decorations changed and visible rows should redraw.
+ (nullable instancetype)coordinatorWithInvalidationHandler:(void (^)(void))invalidationHandler;

@property (nonatomic, readonly) DecorationStore *store;

// Batch-resolve decorations for playlist indices entering the visible range.
// Unresolved items are queried off-main; cached items are no-ops.
- (void)prepareTrackIndices:(NSIndexSet *)indices inPlaylist:(t_size)playlist;

// Resolve a group header decoration (no-op when already resolved/in flight).
- (void)prepareGroup:(NSInteger)groupIndex
              header:(NSString *)header
          indexRange:(NSRange)indexRange
          inPlaylist:(t_size)playlist;

// Playlist content, order or grouping changed: index bindings and group
// decorations are stale. Drops all cached state (cache re-warms in one
// batch per visible screen).
- (void)noteIndexMappingChanged;

// foobar2000 reported metadata changes for these handles.
- (void)handleMetadbChanged:(metadb_handle_list_cref)changed;

// Appends provider context actions for the selection to the menu (after a
// separator). Returns YES if anything was added. The selection is retained
// until an action is invoked or the next menu is built.
- (BOOL)appendContextActionsToMenu:(NSMenu *)menu
                        forHandles:(metadb_handle_list_cref)handles;

// Unregister provider callbacks. Call from the owning controller's dealloc.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
