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
    // Check cache first
    JLTidalPlaybackInfo *cached = tidal::StreamCache::shared().get(std::string([trackID UTF8String]));
    if (cached) {
        completion(cached, nil);
        return;
    }

    // Ensure we have a valid token
    [[JLTidalAuthService shared] ensureValidTokenWithCompletion:^(NSError *tokenError) {
        if (tokenError) {
            completion(nil, tokenError);
            return;
        }

        // Get preferred quality and start resolution with fallback
        JLTidalQuality preferredQuality = tidal::TidalConfig::getPreferredQuality();
        [self resolveWithFallbackForTrackID:trackID
                           startingQuality:preferredQuality
                                completion:completion];
    }];
}

- (void)resolveWithFallbackForTrackID:(NSString *)trackID
                     startingQuality:(JLTidalQuality)quality
                          completion:(JLTidalStreamResolverCompletion)completion {
    tidal::logDebug([[NSString stringWithFormat:@"Trying quality %@ for track %@",
                      JLTidalQualityToString(quality), trackID] UTF8String]);

    [[JLTidalAPI shared] getPlaybackInfoForTrackID:trackID
                                           quality:quality
                                        completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            tidal::logDebug([[NSString stringWithFormat:@"Quality %@: API error %ld - %@",
                             JLTidalQualityToString(quality),
                             (long)error.code,
                             error.localizedDescription] UTF8String]);

            // Only fall back for subscription/quality errors (403).
            // Auth errors (401), network errors, rate limiting, and server errors
            // should not trigger fallback -- they'll fail at every quality level.
            BOOL shouldFallback = (error.code == JLTidalErrorSubscriptionRequired);

            if (shouldFallback) {
                JLTidalQuality nextQuality = [self nextLowerQuality:quality];
                if (nextQuality != quality) {
                    [self resolveWithFallbackForTrackID:trackID
                                       startingQuality:nextQuality
                                            completion:completion];
                    return;
                }
            }

            completion(nil, error);
            return;
        }

        JLTidalPlaybackInfo *info = [[JLTidalPlaybackInfo alloc] initWithDictionary:json
                                                                            trackID:trackID
                                                                    requestedQuality:quality];

        // Accept if we have either a direct URL OR a DASH SegmentTemplate (when enabled in prefs).
        BOOL hasDASH = (tidal::TidalConfig::isDASHEnabled()
                        && info.dashSegmentCount > 0
                        && info.dashInitURL.length
                        && info.dashMediaTemplate.length);
        if (!info.streamURL && !hasDASH) {
            tidal::logInfo([[NSString stringWithFormat:@"Quality %@ unavailable for track %@ (no direct URL and no DASH SegmentTemplate); falling back",
                              JLTidalQualityToString(quality), trackID] UTF8String]);
            JLTidalQuality nextQuality = [self nextLowerQuality:quality];
            if (nextQuality != quality) {
                [self resolveWithFallbackForTrackID:trackID
                                   startingQuality:nextQuality
                                        completion:completion];
                return;
            }
            completion(nil, JLTidalError(JLTidalErrorStreamNotAvailable, @"No stream URL in response at any quality"));
            return;
        }

        // Check for DRM - try fallback to lower quality
        if (info.isDRMProtected) {
            tidal::logInfo([[NSString stringWithFormat:@"Quality %@ is DRM-protected for track %@; falling back",
                             JLTidalQualityToString(quality), trackID] UTF8String]);
            JLTidalQuality nextQuality = [self nextLowerQuality:quality];
            if (nextQuality != quality) {
                [self resolveWithFallbackForTrackID:trackID
                                   startingQuality:nextQuality
                                        completion:completion];
                return;
            } else {
                // All qualities are DRM protected
                completion(nil, JLTidalError(JLTidalErrorDRMProtected,
                    @"Track is DRM protected at all quality levels"));
                return;
            }
        }

        // Cache and return
        tidal::StreamCache::shared().set(std::string([trackID UTF8String]), info);

        NSString *requestedStr = JLTidalQualityToString(quality);
        NSString *gotStr = info.qualityDescription;
        if ([requestedStr isEqualToString:gotStr] || [gotStr containsString:requestedStr]) {
            tidal::logInfo([[NSString stringWithFormat:@"Resolved track %@ at %@",
                             trackID, gotStr] UTF8String]);
        } else {
            tidal::logInfo([[NSString stringWithFormat:@"Resolved track %@: requested %@, got %@ (silent downgrade by API)",
                             trackID, requestedStr, gotStr] UTF8String]);
        }

        completion(info, nil);
    }];
}

- (void)resolveStreamForTrackID:(NSString *)trackID
                        quality:(JLTidalQuality)quality
                     completion:(JLTidalStreamResolverCompletion)completion {
    // Ensure we have a valid token
    [[JLTidalAuthService shared] ensureValidTokenWithCompletion:^(NSError *tokenError) {
        if (tokenError) {
            completion(nil, tokenError);
            return;
        }

        [[JLTidalAPI shared] getPlaybackInfoForTrackID:trackID
                                               quality:quality
                                            completion:^(NSDictionary *json, NSError *error) {
            if (error) {
                completion(nil, error);
                return;
            }

            JLTidalPlaybackInfo *info = [[JLTidalPlaybackInfo alloc] initWithDictionary:json
                                                                                trackID:trackID
                                                                        requestedQuality:quality];

            if (!info.streamURL) {
                completion(nil, JLTidalError(JLTidalErrorStreamNotAvailable, @"No stream URL in response"));
                return;
            }

            if (info.isDRMProtected) {
                completion(nil, JLTidalError(JLTidalErrorDRMProtected, @"Track is DRM protected"));
                return;
            }

            // Cache and return
            tidal::StreamCache::shared().set(std::string([trackID UTF8String]), info);
            completion(info, nil);
        }];
    }];
}

- (JLTidalQuality)nextLowerQuality:(JLTidalQuality)quality {
    // Quality cascade: HI_RES_LOSSLESS -> HI_RES -> LOSSLESS -> HIGH -> LOW
    switch (quality) {
        case JLTidalQualityHiResLossless:
            return JLTidalQualityHiRes;
        case JLTidalQualityHiRes:
            return JLTidalQualityLossless;
        case JLTidalQualityLossless:
            return JLTidalQualityHigh;
        case JLTidalQualityHigh:
            return JLTidalQualityLow;
        case JLTidalQualityLow:
            return JLTidalQualityLow;  // No lower quality
    }
}

- (void)invalidateCacheForTrackID:(NSString *)trackID {
    tidal::StreamCache::shared().remove(std::string([trackID UTF8String]));
}

#pragma mark - Metadata

- (void)getMetadataForTrackID:(NSString *)trackID
                   completion:(JLTidalMetadataCompletion)completion {
    tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: %@", trackID] UTF8String]);

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
            tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: token error: %@",
                             tokenError.localizedDescription] UTF8String]);
            completion(nil, tokenError);
            return;
        }

        tidal::logDebug("getMetadataForTrackID: token valid, fetching from API");

        [[JLTidalAPI shared] getTrackMetadataForTrackID:trackID
                                             completion:^(NSDictionary *json, NSError *error) {
            if (error) {
                tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: API error: %@",
                                 error.localizedDescription] UTF8String]);
                completion(nil, error);
                return;
            }

            tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: got JSON with %lu keys",
                             (unsigned long)[json count]] UTF8String]);

            JLTidalTrack *track = [[JLTidalTrack alloc] initWithDictionary:json];

            tidal::logDebug([[NSString stringWithFormat:@"getMetadataForTrackID: parsed track - title=%@, artist=%@",
                             track.title ?: @"(nil)", track.artist ?: @"(nil)"] UTF8String]);

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

@end
