//
//  TidalModels.mm
//  foo_jl_tidal_mac
//
//  Data models implementation
//

#import "TidalModels.h"

@implementation JLTidalTrack

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _trackID = [dict[@"id"] description];
        _title = dict[@"title"] ?: @"Unknown Title";
        _duration = [dict[@"duration"] integerValue];
        _trackNumber = [dict[@"trackNumber"] integerValue];
        _discNumber = [dict[@"volumeNumber"] integerValue];
        _isExplicit = [dict[@"explicit"] boolValue];

        // Artist - may be nested object
        id artist = dict[@"artist"];
        if ([artist isKindOfClass:[NSDictionary class]]) {
            _artist = artist[@"name"];
        } else if ([artist isKindOfClass:[NSString class]]) {
            _artist = artist;
        }

        // Album - may be nested object
        id album = dict[@"album"];
        if ([album isKindOfClass:[NSDictionary class]]) {
            _album = album[@"title"];

            // Album art from cover
            id cover = album[@"cover"];
            if ([cover isKindOfClass:[NSString class]] && [cover length] > 0) {
                _coverID = cover;  // Store raw cover ID for album art cache
                NSString *coverPath = [cover stringByReplacingOccurrencesOfString:@"-" withString:@"/"];
                NSString *urlStr = [NSString stringWithFormat:@"https://resources.tidal.com/images/%@/640x640.jpg", coverPath];
                _albumArtURL = [NSURL URLWithString:urlStr];
            }

            // Album artist
            id albumArtist = album[@"artist"];
            if ([albumArtist isKindOfClass:[NSDictionary class]]) {
                _albumArtist = albumArtist[@"name"];
            }
        }
    }
    return self;
}

@end

@implementation JLTidalPlaybackInfo

- (instancetype)initWithDictionary:(NSDictionary *)dict
                           trackID:(NSString *)trackID
                   requestedQuality:(JLTidalQuality)requestedQuality {
    self = [super init];
    if (self) {
        _trackID = [trackID copy];
        _quality = requestedQuality;

        // Parse audio quality info
        NSString *audioQuality = dict[@"audioQuality"];
        if ([audioQuality isEqualToString:@"HI_RES_LOSSLESS"]) {
            _quality = JLTidalQualityHiResLossless;
        } else if ([audioQuality isEqualToString:@"HI_RES"]) {
            _quality = JLTidalQualityHiRes;
        } else if ([audioQuality isEqualToString:@"LOSSLESS"]) {
            _quality = JLTidalQualityLossless;
        } else if ([audioQuality isEqualToString:@"HIGH"]) {
            _quality = JLTidalQualityHigh;
        } else if ([audioQuality isEqualToString:@"LOW"]) {
            _quality = JLTidalQualityLow;
        }

        _bitDepth = [dict[@"bitDepth"] integerValue];
        _sampleRate = [dict[@"sampleRate"] integerValue];
        _codec = dict[@"codec"];

        // Parse manifest
        _manifestMimeType = dict[@"manifestMimeType"];
        _manifest = dict[@"manifest"];

        // Check for DRM and extract stream URL
        _drmProtected = NO;
        if (_manifest) {
            // Decode base64 manifest if needed
            NSData *manifestData = [[NSData alloc] initWithBase64EncodedString:_manifest options:0];
            if (manifestData) {
                NSError *error;
                NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData
                                                                             options:0
                                                                               error:&error];
                if (manifestDict) {
                    // Check for actual DRM encryption
                    NSString *encryptionType = manifestDict[@"encryptionType"];
                    NSString *keyId = manifestDict[@"keyId"];

                    // Only flag as DRM if encryption is actually enabled
                    // encryptionType "NONE" means no DRM
                    if (keyId.length > 0) {
                        _drmProtected = YES;
                    } else if (encryptionType && ![encryptionType isEqualToString:@"NONE"]) {
                        _drmProtected = YES;
                    }

                    // Extract stream URL
                    NSArray *urls = manifestDict[@"urls"];
                    if ([urls isKindOfClass:[NSArray class]] && urls.count > 0) {
                        NSString *urlStr = urls.firstObject;
                        if ([urlStr isKindOfClass:[NSString class]]) {
                            _streamURL = [NSURL URLWithString:urlStr];
                        }
                    }
                } else {
                    // If not JSON, check for DASH manifest with ContentProtection
                    NSString *manifestStr = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
                    if (manifestStr && [manifestStr containsString:@"<ContentProtection"]) {
                        _drmProtected = YES;
                    }
                }
            }
        }

        // Direct URL if no manifest
        if (!_streamURL) {
            NSString *urlStr = dict[@"url"];
            if (urlStr) {
                _streamURL = [NSURL URLWithString:urlStr];
            }
        }
    }
    return self;
}

- (NSString *)qualityDescription {
    switch (_quality) {
        case JLTidalQualityHiResLossless:
            return [NSString stringWithFormat:@"HiFi Plus (%ld-bit/%ldkHz)",
                    (long)_bitDepth, (long)_sampleRate / 1000];
        case JLTidalQualityHiRes:
            return [NSString stringWithFormat:@"HiFi MQA (%ld-bit/%ldkHz)",
                    (long)_bitDepth, (long)_sampleRate / 1000];
        case JLTidalQualityLossless:
            return @"Lossless (16-bit/44.1kHz)";
        case JLTidalQualityHigh:
            return @"High (320kbps)";
        case JLTidalQualityLow:
            return @"Normal (96kbps)";
    }
}

@end

@implementation JLTidalStreamCacheEntry

- (instancetype)initWithPlaybackInfo:(JLTidalPlaybackInfo *)info
                                 ttl:(NSTimeInterval)ttl {
    self = [super init];
    if (self) {
        _playbackInfo = info;
        _expiresAt = [NSDate dateWithTimeIntervalSinceNow:ttl];
    }
    return self;
}

- (BOOL)isExpired {
    return [self.expiresAt compare:[NSDate date]] != NSOrderedDescending;
}

@end
