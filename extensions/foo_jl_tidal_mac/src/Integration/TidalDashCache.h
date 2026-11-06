//
//  TidalDashCache.h
//  foo_jl_tidal_mac
//
//  Coalescing in-memory cache of assembled DASH blobs, keyed by track ID
//  AND resolved quality.
//  Background prefetch (JLTidalPrefetch) fills it ahead of playback; the
//  input decoder reads from it instead of downloading segments inline.
//  Foundation + GCD only — no fb2k SDK — so a track prefetched while its
//  predecessor plays opens instantly instead of stalling for the ~3-4s,
//  50+ MB segment download.
//

#pragma once

#import <Foundation/Foundation.h>
#import "../API/TidalConstants.h"

NS_ASSUME_NONNULL_BEGIN

/// A read handle on an assembly that is still downloading. Holding one keeps
/// the download alive (it counts as a waiter); close it, or let it go, when
/// done. Bytes only ever grow, in order, so a reader can consume them as they
/// arrive instead of waiting for the whole track.
@interface JLTidalDashStream : NSObject

/// Calls `block` with the bytes received so far, under the assembly's lock:
/// copy what you need and return promptly, and do not keep the pointer.
/// `complete` means the download finished and nothing more will arrive;
/// `failed` means it stopped short and the bytes will never be whole.
- (void)withBytes:(void (NS_NOESCAPE ^)(const uint8_t *bytes, NSUInteger length,
                                        BOOL complete, BOOL failed))block;

/// Blocks until the download finishes and returns the whole blob, or nil on
/// failure or when isCancelled returns YES.
- (nullable NSData *)waitForBlobWithCancel:(BOOL (^)(void))isCancelled;

/// Gives back this handle's interest in the download. Idempotent.
- (void)close;

@end

@interface JLTidalDashCache : NSObject

+ (instancetype)shared;

// Every entry point takes the RESOLVED quality as well as the track ID.
// A playlist entry can pin a tier ("?q=" in the URL) while the preference
// asks for another, and the two resolve to different segment templates and
// different audio. Keying on the track alone let whichever assembly ran
// first -- usually the prefetcher's, at the global preference -- serve the
// other one's bytes. The stream cache one layer up already keys this way.

/// Non-blocking cache probe. Returns the assembled blob, or nil on a miss.
- (nullable NSData *)cachedBlobForTrackID:(NSString *)trackID
                                  quality:(JLTidalQuality)quality;

/// Start assembling this track's blob in the background if it is not
/// already cached or in flight. Best-effort; returns immediately.
- (void)prefetchTrackID:(NSString *)trackID
                quality:(JLTidalQuality)quality
          mediaTemplate:(NSString *)mediaTemplate
           segmentCount:(NSInteger)segmentCount;

/// Return the assembled blob, blocking until it is ready. A cache hit
/// returns instantly; an in-flight prefetch is awaited (no duplicate
/// download); otherwise assembly starts now. isCancelled is polled while
/// waiting — when it returns YES the wait is abandoned and this returns nil
/// (the shared assembly keeps running for other waiters/prefetch). Returns
/// nil on assembly failure.
- (nullable NSData *)blobForTrackID:(NSString *)trackID
                            quality:(JLTidalQuality)quality
                      mediaTemplate:(NSString *)mediaTemplate
                       segmentCount:(NSInteger)segmentCount
                        isCancelled:(BOOL (^)(void))isCancelled;

/// Open a progressive read handle, starting the download if nothing is
/// fetching this track yet. Returns nil when the whole blob is already cached
/// (use blobForTrackID, which returns it instantly).
- (nullable JLTidalDashStream *)openStreamForTrackID:(NSString *)trackID
                                             quality:(JLTidalQuality)quality
                                       mediaTemplate:(NSString *)mediaTemplate
                                        segmentCount:(NSInteger)segmentCount;

/// Cancel every in-flight assembly that only a prefetch wants, except the
/// given track's. For a decoder that missed the cache: playback went somewhere
/// the prefetcher did not predict, so its downloads are for a track that no
/// longer comes next, and they compete with this open for bandwidth.
- (void)abandonPrefetchesExceptTrackID:(NSString *)trackID quality:(JLTidalQuality)quality;

/// Drop all cached blobs and stop in-flight assembly (called on component
/// quit before fb2k services tear down).
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
