//
//  DashCachePolicy.h
//  foo_jl_tidal_mac
//
//  Pure helpers for the DASH prefetch blob cache: segment-URL generation
//  and byte-capped LRU eviction. Foundation-only — no SDK, no network —
//  unit-tested standalone (Tests/DashCachePolicyTests.mm). JLTidalDashCache
//  owns the concurrency, storage, and downloads.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JLTidalDashCachePolicy : NSObject

/// Expand a Tidal DASH media template into the ordered segment URL list by
/// substituting $Number$ = 0..count-1. Tidal treats media[$Number$=0] as
/// the init segment, so there is no separate init URL. Returns an empty
/// array when the template lacks $Number$ or count <= 0.
+ (NSArray<NSString *> *)segmentURLsForTemplate:(NSString *)mediaTemplate
                                          count:(NSInteger)count;

/// Given LRU order (oldest first), each key's size in bytes, and a total
/// byte cap, return the oldest keys to evict so the remaining total fits
/// under the cap. Never evicts the newest (last) entry, so a single blob
/// larger than the cap is still kept.
+ (NSArray<NSString *> *)evictionKeysForOrder:(NSArray<NSString *> *)order
                                        sizes:(NSDictionary<NSString *, NSNumber *> *)sizes
                                     capBytes:(long long)capBytes;

@end

NS_ASSUME_NONNULL_END
