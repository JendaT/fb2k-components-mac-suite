//
//  TidalStreamResolver.mm
//  foo_jl_tidal_mac
//
//  Stream URL resolution with DRM fallback
//

#import "TidalStreamResolver.h"
#import "TidalAuthService.h"
#import "../API/TidalAPI.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalErrors.h"
#import "../Core/StreamCache.h"
#import "../Core/StreamResolutionPolicy.h"

// Always-on diagnostic when DASH is enabled — gives us ground truth XML on
// the first user report. Truncated to 4 KB to keep log readable.
static void dumpRawManifestIfNeeded(JLTidalPlaybackInfo *info, BOOL dashEnabled) {
    NSString *rawMPD = info.rawDASHManifest;
    // Gated on debug logging as well as DASH: this dumped 4 KB of XML to the
    // console on every single resolve.
    if (rawMPD && dashEnabled && tidal::isDebugLoggingCached()) {
        NSString *dump = rawMPD.length > 4096
            ? [rawMPD substringToIndex:4096]
            : rawMPD;
        tidal::logInfo([[NSString stringWithFormat:@"DASH MPD raw (len=%lu):\n%@",
                          (unsigned long)rawMPD.length, dump] UTF8String]);
    }
}

static const NSUInteger kMaxMetadataCacheSize = 500;

@interface JLTidalStreamResolver ()
@property (nonatomic, strong) NSMutableDictionary<NSString*, JLTidalTrack*> *metadataCache;
@property (nonatomic, strong) dispatch_queue_t metadataQueue;
@end

@implementation JLTidalStreamResolver

+ (instancetype)shared {
    static JLTidalStreamResolver *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[JLTidalStreamResolver alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _metadataCache = [[NSMutableDictionary alloc] init];
        _metadataQueue = dispatch_queue_create("com.foobar2000.tidal.metadata", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)initialize {
    tidal::logDebug("StreamResolver initialized");
}

- (void)shutdown {
    tidal::StreamCache::shared().shutdown();

    dispatch_sync(self.metadataQueue, ^{
        [self.metadataCache removeAllObjects];
    });

    tidal::logDebug("StreamResolver shutdown");
}

#pragma mark - Stream Resolution

- (void)resolveStreamForTrackID:(NSString *)trackID
                     completion:(JLTidalStreamResolverCompletion)completion {
    [self resolveStreamForTrackID:trackID
                          quality:tidal::TidalConfig::getPreferredQuality()
                       completion:completion];
}

- (void)resolveStreamForTrackID:(NSString *)trackID
                        quality:(JLTidalQuality)quality
                     completion:(JLTidalStreamResolverCompletion)completion {
    // The cache is keyed by the quality that was ASKED for, not the one the
    // cascade landed on: a HI_RES_LOSSLESS request that fell back to LOSSLESS
    // must hit next time it is asked for HI_RES_LOSSLESS, or it re-runs the
    // whole cascade on every play.
    std::string trackKey([trackID UTF8String]);
    JLTidalPlaybackInfo *cached = tidal::StreamCache::shared().get(trackKey, quality);
    if (cached) {
        completion(cached, nil);
        return;
    }

    // Availability is known before any stream request when the track came from
    // a list response. A withdrawn or region-locked track otherwise costs a
    // 404, or five playbackinfo requests down the cascade for a 403, every time
    // it is played AND again on every prefetch.
    __block JLTidalTrack *known = nil;
    dispatch_sync(self.metadataQueue, ^{
        known = self.metadataCache[trackID];
    });
    if (known && (!known.allowStreaming || !known.streamReady)) {
        tidal::logInfo([[NSString stringWithFormat:
                         @"Track %@ is not streamable (allowStreaming=%d streamReady=%d)",
                         trackID, known.allowStreaming, known.streamReady] UTF8String]);
        completion(nil, JLTidalError(JLTidalErrorStreamNotAvailable,
                                     @"Track is not available for streaming"));
        return;
    }

    // Ensure we have a valid token
    [[JLTidalAuthService shared] ensureValidTokenWithCompletion:^(NSError *tokenError) {
        if (tokenError) {
            completion(nil, tokenError);
            return;
        }

        [self resolveWithFallbackForTrackID:trackID
                           startingQuality:quality
                                completion:^(JLTidalPlaybackInfo *info, NSError *error) {
            if (info) {
                tidal::StreamCache::shared().set(trackKey, quality, info);
            }
            completion(info, error);
        }];
    }];
}

- (void)resolveWithFallbackForTrackID:(NSString *)trackID
                     startingQuality:(JLTidalQuality)quality
                          completion:(JLTidalStreamResolverCompletion)completion {
    tidal::logDebug([[NSString stringWithFormat:@"Trying quality %@ for track %@",
                      JLTidalQualityToString(quality), trackID] UTF8String]);

    // Snapshot config BEFORE the request. The completion runs on the URL
    // session's queue and could land after fb2k has torn down configStore,
    // whose accessor bug-checks rather than throws.
    BOOL dashEnabled = tidal::TidalConfig::isDASHEnabled();

    [[JLTidalAPI shared] getPlaybackInfoForTrackID:trackID
                                           quality:quality
                                        completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            tidal::logDebug([[NSString stringWithFormat:@"Quality %@: API error %ld - %@",
                             JLTidalQualityToString(quality),
                             (long)error.code,
                             error.localizedDescription] UTF8String]);

            // Fallback policy lives in JLTidalStreamResolutionPolicy (pure, unit-tested).
            JLTidalResolveDecision *decision =
                [JLTidalStreamResolutionPolicy decisionForError:error atQuality:quality];
            if (decision.action == JLTidalResolveActionRetryLower) {
                [self resolveWithFallbackForTrackID:trackID
                                   startingQuality:decision.nextQuality
                                        completion:completion];
                return;
            }

            completion(nil, error);
            return;
        }

        JLTidalPlaybackInfo *info = [[JLTidalPlaybackInfo alloc] initWithDictionary:json
                                                                            trackID:trackID
                                                                    requestedQuality:quality];
        dumpRawManifestIfNeeded(info, dashEnabled);

        JLTidalResolveDecision *decision =
            [JLTidalStreamResolutionPolicy decisionForPlaybackWithDirectURL:(info.streamURL != nil)
                                                           dashSegmentCount:info.dashSegmentCount
                                                          dashMediaTemplate:info.dashMediaTemplate
                                                                dashEnabled:dashEnabled
                                                               drmProtected:info.isDRMProtected
                                                                previewOnly:info.isPreviewOnly
                                                              previewReason:info.previewReason
                                                                    quality:quality];

        if (decision.action != JLTidalResolveActionAccept) {
            if (decision.failureCode == JLTidalErrorPreviewOnly) {
                tidal::logError([[NSString stringWithFormat:@"Track %@: %@",
                                  trackID, decision.failureMessage] UTF8String]);
            } else if (decision.failureCode == JLTidalErrorDRMProtected) {
                tidal::logInfo([[NSString stringWithFormat:@"Quality %@ is DRM-protected for track %@; falling back",
                                 JLTidalQualityToString(quality), trackID] UTF8String]);
            } else {
                tidal::logInfo([[NSString stringWithFormat:@"Quality %@ unavailable for track %@ (no direct URL and no DASH SegmentTemplate); falling back",
                                  JLTidalQualityToString(quality), trackID] UTF8String]);
            }

            if (decision.action == JLTidalResolveActionRetryLower) {
                [self resolveWithFallbackForTrackID:trackID
                                   startingQuality:decision.nextQuality
                                        completion:completion];
            } else {
                completion(nil, JLTidalError(decision.failureCode, decision.failureMessage));
            }
            return;
        }

        // Tidal answers a request for a tier a track does not carry with HIGH
        // rather than the track's real maximum, and asking lower does not help
        // (verified: an explicit LOSSLESS request for such a track still
        // returns HIGH). So report what we got and move on — no extra requests.
        if (info.quality >= quality) {
            tidal::logInfo([[NSString stringWithFormat:@"Resolved track %@ at %@",
                             trackID, info.qualityDescription] UTF8String]);
        } else {
            tidal::logInfo([[NSString stringWithFormat:
                             @"Resolved track %@ at %@ (%@ not available for this track)",
                             trackID, info.qualityDescription,
                             JLTidalQualityToString(quality)] UTF8String]);
        }

        completion(info, nil);
    }];
}

- (void)invalidateCacheForTrackID:(NSString *)trackID {
    tidal::StreamCache::shared().removeTrack(std::string([trackID UTF8String]));
}

#pragma mark - Metadata

- (void)getMetadataForTrackID:(NSString *)trackID
                   completion:(JLTidalMetadataCompletion)completion {
    // Runs per track in hot paths; skip the eager NSString formatting
    // unless debug logging is actually enabled (same as URLUtils).
    if (tidal::isDebugLoggingCached()) {
        tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: %@", trackID] UTF8String]);
    }

    // Check cache first
    __block JLTidalTrack *cached = nil;
    dispatch_sync(self.metadataQueue, ^{
        cached = self.metadataCache[trackID];
    });

    if (cached) {
        tidal::logDebug("getMetadataForTrackID: returning cached metadata");
        completion(cached, nil);
        return;
    }

    // Ensure we have a valid token
    [[JLTidalAuthService shared] ensureValidTokenWithCompletion:^(NSError *tokenError) {
        if (tokenError) {
            if (tidal::isDebugLoggingCached()) {
                tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: token error: %@",
                                 tokenError.localizedDescription] UTF8String]);
            }
            completion(nil, tokenError);
            return;
        }

        tidal::logDebug("getMetadataForTrackID: token valid, fetching from API");

        [[JLTidalAPI shared] getTrackMetadataForTrackID:trackID
                                             completion:^(NSDictionary *json, NSError *error) {
            if (error) {
                if (tidal::isDebugLoggingCached()) {
                    tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: API error: %@",
                                     error.localizedDescription] UTF8String]);
                }
                completion(nil, error);
                return;
            }

            if (tidal::isDebugLoggingCached()) {
                tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: got JSON with %lu keys",
                                 (unsigned long)[json count]] UTF8String]);
            }

            JLTidalTrack *track = [[JLTidalTrack alloc] initWithDictionary:json];

            if (tidal::isDebugLoggingCached()) {
                tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: parsed track - title=%@, artist=%@",
                                 track.title ?: @"(nil)", track.artist ?: @"(nil)"] UTF8String]);
            }

            // Cache it (with size limit)
            dispatch_async(self.metadataQueue, ^{
                if (self.metadataCache.count >= kMaxMetadataCacheSize) {
                    // Evict roughly half the cache when limit is reached
                    NSArray *keys = [self.metadataCache allKeys];
                    NSUInteger evictCount = keys.count / 2;
                    for (NSUInteger i = 0; i < evictCount; i++) {
                        [self.metadataCache removeObjectForKey:keys[i]];
                    }
                }
                self.metadataCache[trackID] = track;
            });

            completion(track, nil);
        }];
    }];
}

- (void)seedMetadataForTracks:(NSArray<JLTidalTrack *> *)tracks {
    if (tracks.count == 0) return;
    dispatch_async(self.metadataQueue, ^{
        for (JLTidalTrack *track in tracks) {
            if (track.trackID.length == 0) continue;
            // Never overwrite: a cached entry may have come from the richer
            // per-track endpoint, and a list entry carries less.
            if (self.metadataCache[track.trackID]) continue;
            if (self.metadataCache.count >= kMaxMetadataCacheSize) break;
            self.metadataCache[track.trackID] = track;
        }
        tidal::logDebug([[NSString stringWithFormat:@"Seeded metadata cache with %lu track(s), now %lu",
                          (unsigned long)tracks.count,
                          (unsigned long)self.metadataCache.count] UTF8String]);
    });
}

@end
