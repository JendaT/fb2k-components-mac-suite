//
//  TidalLibrarySaver.h
//  foo_jl_tidal_mac
//
//  Personal library export: downloads selected tidal:// tracks and files
//  them into the music.hq layout under the configured library root
//  (Preferences > Library). Runs on a serial background queue; progress
//  and a final summary go to the foobar2000 console.
//
//  Per track: metadata fetch -> genre-collection resolution (existing
//  artist folder on disk > remembered choice > one-time prompt) -> stream
//  download (DASH blobs come from JLTidalDashCache, so an already-prefetched
//  track is not re-downloaded) -> ffmpeg stream-copy remux to .flac with
//  tags -> cover.jpg. Without ffmpeg the raw container is saved untagged.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JLTidalLibrarySaver : NSObject

+ (instancetype)shared;

/// Queue the given track IDs for export. Returns immediately; work happens
/// on a serial background queue. Safe to call repeatedly — batches append.
- (void)saveTrackIDs:(NSArray<NSString *> *)trackIDs;

/// Abandon queued/remaining work (called on component quit).
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
