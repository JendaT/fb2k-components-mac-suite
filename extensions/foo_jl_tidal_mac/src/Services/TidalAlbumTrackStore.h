//
//  TidalAlbumTrackStore.h
//  foo_jl_tidal_mac
//
//  Album track lists for dragging albums out of the browser. A drag has to
//  hand over its tracks when it is dropped, long before a fresh fetch could
//  finish, so lists are fetched ahead -- when an album row is selected or
//  opened -- and a drop waits only for whatever is still on its way.
//
//  Thread-safe. Fetch completions never go through the main thread, so the
//  main thread may wait on them.
//

#pragma once

#import <Foundation/Foundation.h>
#import "../Core/TidalModels.h"

NS_ASSUME_NONNULL_BEGIN

@interface JLTidalAlbumTrackStore : NSObject

+ (instancetype)shared;

/// Records a list fetched elsewhere (the album drill-down), in album order.
- (void)setTracks:(NSArray<JLTidalTrack *> *)tracks forAlbumID:(NSString *)albumID;

/// Starts fetching the album's tracks unless they are known or on the way.
- (void)prefetchAlbumID:(NSString *)albumID;

/// Blocks until every album's tracks are known or `timeout` passes, fetching
/// the missing ones. Returns the lists that arrived, keyed by album ID; an
/// album whose fetch failed or ran late is absent.
- (NSDictionary<NSString *, NSArray<JLTidalTrack *> *> *)waitForAlbumIDs:(NSArray<NSString *> *)albumIDs
                                                                 timeout:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
