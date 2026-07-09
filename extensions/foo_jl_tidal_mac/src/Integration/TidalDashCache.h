//
//  TidalDashCache.h
//  foo_jl_tidal_mac
//
//  Coalescing in-memory cache of assembled DASH blobs, keyed by track ID.
//  Background prefetch (JLTidalPrefetch) fills it ahead of playback; the
//  input decoder reads from it instead of downloading segments inline.
//  Foundation + GCD only — no fb2k SDK — so a track prefetched while its
//  predecessor plays opens instantly instead of stalling for the ~3-4s,
//  50+ MB segment download.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JLTidalDashCache : NSObject

+ (instancetype)shared;

/// Non-blocking cache probe. Returns the assembled blob, or nil on a miss.
- (nullable NSData *)cachedBlobForTrackID:(NSString *)trackID;

/// Start assembling this track's blob in the background if it is not
/// already cached or in flight. Best-effort; returns immediately.
- (void)prefetchTrackID:(NSString *)trackID
          mediaTemplate:(NSString *)mediaTemplate
           segmentCount:(NSInteger)segmentCount;

/// Return the assembled blob, blocking until it is ready. A cache hit
/// returns instantly; an in-flight prefetch is awaited (no duplicate
/// download); otherwise assembly starts now. isCancelled is polled while
/// waiting — when it returns YES the wait is abandoned and this returns nil
/// (the shared assembly keeps running for other waiters/prefetch). Returns
/// nil on assembly failure.
- (nullable NSData *)blobForTrackID:(NSString *)trackID
                      mediaTemplate:(NSString *)mediaTemplate
                       segmentCount:(NSInteger)segmentCount
                        isCancelled:(BOOL (^)(void))isCancelled;

/// Drop all cached blobs and stop in-flight assembly (called on component
/// quit before fb2k services tear down).
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
