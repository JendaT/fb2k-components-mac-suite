//
//  TidalModels.mm
//  foo_jl_tidal_mac
//
//  Data models implementation
//

#import "TidalModels.h"
#import "TidalConfig.h"

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

        // Audio quality (returned by search API per track)
        id audioQuality = dict[@"audioQuality"];
        if ([audioQuality isKindOfClass:[NSString class]]) {
            _audioQuality = audioQuality;
        }

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

            // Total tracks from album
            id numTracks = album[@"numberOfTracks"];
            if (numTracks) {
                _totalTracks = [numTracks integerValue];
            }

            // Release date from album
            NSString *dateStr = album[@"releaseDate"];
            if ([dateStr isKindOfClass:[NSString class]] && dateStr.length >= 10) {
                NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                fmt.dateFormat = @"yyyy-MM-dd";
                fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
                _releaseDate = [fmt dateFromString:dateStr];
            }
        }

        // Fallback: track-level releaseDate if album didn't provide one
        if (!_releaseDate) {
            NSString *trackDateStr = dict[@"releaseDate"];
            if (!trackDateStr) trackDateStr = dict[@"streamStartDate"];
            if ([trackDateStr isKindOfClass:[NSString class]] && trackDateStr.length >= 10) {
                NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
                fmt.dateFormat = @"yyyy-MM-dd";
                fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
                _releaseDate = [fmt dateFromString:[trackDateStr substringToIndex:10]];
            }
        }

        // ISRC (International Standard Recording Code)
        id isrc = dict[@"isrc"];
        if ([isrc isKindOfClass:[NSString class]] && [isrc length] > 0) {
            _isrc = isrc;
        }

        // Copyright
        id copyright = dict[@"copyright"];
        if ([copyright isKindOfClass:[NSString class]] && [copyright length] > 0) {
            _copyright = copyright;
        }
    }
    return self;
}

@end

@implementation JLTidalAlbum

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _albumID = [dict[@"id"] description];
        _title = dict[@"title"] ?: @"Unknown Album";
        _numberOfTracks = [dict[@"numberOfTracks"] integerValue];
        _duration = [dict[@"duration"] integerValue];
        _audioQuality = dict[@"audioQuality"];

        // Artist - may be nested object
        id artist = dict[@"artist"];
        if ([artist isKindOfClass:[NSDictionary class]]) {
            _artist = artist[@"name"];
        } else if ([artist isKindOfClass:[NSString class]]) {
            _artist = artist;
        }

        // Cover art
        id cover = dict[@"cover"];
        if ([cover isKindOfClass:[NSString class]] && [cover length] > 0) {
            _coverID = cover;
        }

        // Release date (ISO 8601 date string, e.g. "2024-01-15")
        NSString *dateStr = dict[@"releaseDate"];
        if ([dateStr isKindOfClass:[NSString class]] && dateStr.length >= 10) {
            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"yyyy-MM-dd";
            fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            _releaseDate = [fmt dateFromString:dateStr];
        }
    }
    return self;
}

@end

@implementation JLTidalArtist

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _artistID = [dict[@"id"] description];
        _name = dict[@"name"] ?: @"Unknown Artist";

        // Picture ID - used to build CDN URLs
        id picture = dict[@"picture"];
        if ([picture isKindOfClass:[NSString class]] && [picture length] > 0) {
            _pictureID = picture;
        }
    }
    return self;
}

@end

@implementation JLTidalPlaylist

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _playlistUUID = dict[@"uuid"] ?: [dict[@"id"] description];
        _title = dict[@"title"] ?: @"Untitled Playlist";
        _playlistDescription = dict[@"description"];
        _numberOfTracks = [dict[@"numberOfTracks"] integerValue];
        _duration = [dict[@"duration"] integerValue];

        // Playlist image (may be a squareImage or image array)
        id squareImage = dict[@"squareImage"];
        if ([squareImage isKindOfClass:[NSString class]] && [squareImage length] > 0) {
            _coverID = squareImage;
        } else {
            id image = dict[@"image"];
            if ([image isKindOfClass:[NSString class]] && [image length] > 0) {
                _coverID = image;
            }
        }

        // Last updated date
        NSString *lastUpdated = dict[@"lastUpdated"];
        if ([lastUpdated isKindOfClass:[NSString class]] && lastUpdated.length >= 10) {
            NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
            _lastUpdated = [fmt dateFromString:lastUpdated];
            if (!_lastUpdated) {
                // Fallback for date-only format
                NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
                dateFmt.dateFormat = @"yyyy-MM-dd";
                dateFmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
                _lastUpdated = [dateFmt dateFromString:lastUpdated];
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

        tidal::logDebug([[NSString stringWithFormat:@"Playback info: quality=%@, codec=%@, manifestType=%@",
                          audioQuality ?: @"(nil)", _codec ?: @"(nil)", _manifestMimeType ?: @"(nil)"] UTF8String]);

        // Check for DRM and extract stream URL
        _drmProtected = NO;
        if (_manifest) {
            // Both JSON (application/vnd.tidal.bts) and standard JSON manifests are
            // base64-encoded JSON with a "urls" array. DASH manifests are XML-based.
            BOOL isJSONManifest = !_manifestMimeType
                || [_manifestMimeType isEqualToString:@"application/vnd.tidal.bts"]
                || [_manifestMimeType containsString:@"json"];

            NSData *manifestData = [[NSData alloc] initWithBase64EncodedString:_manifest options:0];
            if (!manifestData) {
                tidal::logError([[NSString stringWithFormat:@"Failed to base64-decode manifest (type=%@)",
                                  _manifestMimeType ?: @"(nil)"] UTF8String]);
            } else if (isJSONManifest) {
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
                        tidal::logDebug([[NSString stringWithFormat:@"Manifest has DRM: keyId=%@", keyId] UTF8String]);
                    } else if (encryptionType && ![encryptionType isEqualToString:@"NONE"]) {
                        _drmProtected = YES;
                        tidal::logDebug([[NSString stringWithFormat:@"Manifest has DRM: encryptionType=%@", encryptionType] UTF8String]);
                    } else {
                        tidal::logDebug("Manifest: no DRM");
                    }

                    // Extract stream URL
                    NSArray *urls = manifestDict[@"urls"];
                    if ([urls isKindOfClass:[NSArray class]] && urls.count > 0) {
                        NSString *urlStr = urls.firstObject;
                        if ([urlStr isKindOfClass:[NSString class]]) {
                            _streamURL = [NSURL URLWithString:urlStr];
                        }
                    }

                    if (!_streamURL) {
                        tidal::logError([[NSString stringWithFormat:@"No URLs in %@ manifest", _manifestMimeType] UTF8String]);
                    }
                } else {
                    tidal::logError([[NSString stringWithFormat:@"Failed to parse %@ manifest as JSON: %@",
                                      _manifestMimeType, error.localizedDescription] UTF8String]);
                }
            } else if ([_manifestMimeType containsString:@"dash"] || [_manifestMimeType containsString:@"xml"]) {
                // DASH manifest - check for ContentProtection
                NSString *manifestStr = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
                if (manifestStr && [manifestStr containsString:@"<ContentProtection"]) {
                    _drmProtected = YES;
                    tidal::logDebug("DASH manifest has DRM (ContentProtection)");
                } else {
                    tidal::logDebug("DASH manifest: no DRM");
                }
            } else {
                tidal::logError([[NSString stringWithFormat:@"Unknown manifest type: %@", _manifestMimeType] UTF8String]);
            }
        }

        // Direct URL if no manifest
        if (!_streamURL) {
            NSString *urlStr = dict[@"url"];
            if (urlStr) {
                _streamURL = [NSURL URLWithString:urlStr];
                tidal::logDebug("Using direct URL from response (no manifest)");
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
