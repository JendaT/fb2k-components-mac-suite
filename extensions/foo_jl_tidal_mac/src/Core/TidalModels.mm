//
//  TidalModels.mm
//  foo_jl_tidal_mac
//
//  Data models implementation
//

#import "TidalModels.h"
#import "TidalConfig.h"

static NSDateFormatter *sharedDateOnlyFormatter(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd";
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return fmt;
}

static NSISO8601DateFormatter *sharedISO8601Formatter(void) {
    static NSISO8601DateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSISO8601DateFormatter alloc] init];
    });
    return fmt;
}

static NSRegularExpression *sharedDASHBaseURLRegex(void) {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
            @"<BaseURL>\\s*(https?://[^<]+?)\\s*</BaseURL>"
            options:0 error:nil];
    });
    return regex;
}

// Extract a single attribute value (e.g. initialization="...") from an XML tag.
static NSString *extractXMLAttr(NSString *tag, NSString *attr) {
    NSString *pattern = [NSString stringWithFormat:@"\\b%@\\s*=\\s*\"([^\"]*)\"", attr];
    NSError *err = nil;
    NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&err];
    if (!r) return nil;
    NSTextCheckingResult *m = [r firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (m && m.numberOfRanges > 1) {
        return [tag substringWithRange:[m rangeAtIndex:1]];
    }
    return nil;
}

// Parse ISO 8601 duration (PT4M55.5S, PT1H, PT300S).
static double parseISO8601Duration(NSString *str) {
    if (str.length == 0) return 0;
    static NSRegularExpression *r = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        r = [NSRegularExpression regularExpressionWithPattern:
              @"PT(?:(\\d+)H)?(?:(\\d+)M)?(?:([0-9.]+)S)?"
              options:0 error:nil];
    });
    NSTextCheckingResult *m = [r firstMatchInString:str options:0 range:NSMakeRange(0, str.length)];
    if (!m) return 0;
    double total = 0;
    NSRange h = [m rangeAtIndex:1];
    NSRange mn = [m rangeAtIndex:2];
    NSRange s = [m rangeAtIndex:3];
    if (h.location != NSNotFound) total += [[str substringWithRange:h] doubleValue] * 3600.0;
    if (mn.location != NSNotFound) total += [[str substringWithRange:mn] doubleValue] * 60.0;
    if (s.location != NSNotFound) total += [[str substringWithRange:s] doubleValue];
    return total;
}

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

        // Artist - may be nested object or null
        id artist = dict[@"artist"];
        if ([artist isKindOfClass:[NSDictionary class]]) {
            _artist = artist[@"name"];
        } else if ([artist isKindOfClass:[NSString class]]) {
            _artist = artist;
        }

        // Fallback to artists array (plural) if singular artist is missing
        if (!_artist.length) {
            NSArray *artists = dict[@"artists"];
            if ([artists isKindOfClass:[NSArray class]] && artists.count > 0) {
                NSDictionary *firstArtist = artists[0];
                if ([firstArtist isKindOfClass:[NSDictionary class]]) {
                    _artist = firstArtist[@"name"];
                }
            }
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
                _releaseDate = [sharedDateOnlyFormatter() dateFromString:dateStr];
            }
        }

        // Fallback: track-level releaseDate if album didn't provide one
        if (!_releaseDate) {
            NSString *trackDateStr = dict[@"releaseDate"];
            if (!trackDateStr) trackDateStr = dict[@"streamStartDate"];
            if ([trackDateStr isKindOfClass:[NSString class]] && trackDateStr.length >= 10) {
                _releaseDate = [sharedDateOnlyFormatter() dateFromString:[trackDateStr substringToIndex:10]];
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

        // Artist - may be nested object or null
        id artist = dict[@"artist"];
        if ([artist isKindOfClass:[NSDictionary class]]) {
            _artist = artist[@"name"];
        } else if ([artist isKindOfClass:[NSString class]]) {
            _artist = artist;
        }

        // Fallback to artists array (plural) if singular artist is missing
        if (!_artist.length) {
            NSArray *artists = dict[@"artists"];
            if ([artists isKindOfClass:[NSArray class]] && artists.count > 0) {
                NSDictionary *firstArtist = artists[0];
                if ([firstArtist isKindOfClass:[NSDictionary class]]) {
                    _artist = firstArtist[@"name"];
                }
            }
        }

        // Cover art
        id cover = dict[@"cover"];
        if ([cover isKindOfClass:[NSString class]] && [cover length] > 0) {
            _coverID = cover;
        }

        // Release date (ISO 8601 date string, e.g. "2024-01-15")
        NSString *dateStr = dict[@"releaseDate"];
        if ([dateStr isKindOfClass:[NSString class]] && dateStr.length >= 10) {
            _releaseDate = [sharedDateOnlyFormatter() dateFromString:dateStr];
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
            _lastUpdated = [sharedISO8601Formatter() dateFromString:lastUpdated];
            if (!_lastUpdated) {
                // Fallback for date-only format
                _lastUpdated = [sharedDateOnlyFormatter() dateFromString:lastUpdated];
            }
        }
    }
    return self;
}

@end

@implementation JLTidalPlaylistFolder

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        // v2 API uses "trn" like "trn:folder:uuid" or just "id"
        NSString *trn = dict[@"trn"];
        if ([trn isKindOfClass:[NSString class]] && trn.length > 0) {
            // Extract UUID from TRN format "trn:folder:{uuid}"
            NSArray *parts = [trn componentsSeparatedByString:@":"];
            _folderID = parts.lastObject ?: trn;
        } else {
            id dictID = dict[@"id"];
            _folderID = dictID ? [dictID description] : [[NSUUID UUID] UUIDString];
        }

        _name = dict[@"name"] ?: @"Untitled Folder";
        _parentFolderID = dict[@"parentFolderId"];
        _subfolders = [NSMutableArray array];
        _playlistUUIDs = [NSMutableArray array];

        // Parse nested items if present
        NSArray *items = dict[@"items"];
        if ([items isKindOfClass:[NSArray class]]) {
            for (NSDictionary *item in items) {
                NSString *type = item[@"type"];
                if ([type isEqualToString:@"FOLDER"]) {
                    JLTidalPlaylistFolder *subfolder = [[JLTidalPlaylistFolder alloc] initWithDictionary:item];
                    if (subfolder) {
                        [_subfolders addObject:subfolder];
                    }
                } else if ([type isEqualToString:@"PLAYLIST"]) {
                    NSDictionary *data = item[@"data"];
                    NSString *uuid = data[@"uuid"] ?: [data[@"id"] description];
                    if (uuid.length > 0) {
                        [_playlistUUIDs addObject:uuid];
                    }
                }
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
                // DASH manifest (MPD XML) - check for DRM and extract stream URL
                NSString *manifestStr = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
                if (manifestStr && [manifestStr containsString:@"<ContentProtection"]) {
                    _drmProtected = YES;
                    tidal::logDebug("DASH manifest has DRM (ContentProtection)");
                } else {
                    tidal::logDebug("DASH manifest: no DRM");
                }

                if (manifestStr) {
                    // 1) Try BaseURL — direct playable URL (oldest Tidal format)
                    NSRegularExpression *regex = sharedDASHBaseURLRegex();
                    NSTextCheckingResult *match = [regex firstMatchInString:manifestStr
                        options:0 range:NSMakeRange(0, manifestStr.length)];
                    if (match && match.numberOfRanges > 1) {
                        NSString *urlStr = [manifestStr substringWithRange:[match rangeAtIndex:1]];
                        _streamURL = [NSURL URLWithString:urlStr];
                        tidal::logDebug([[NSString stringWithFormat:@"DASH BaseURL: %@", urlStr] UTF8String]);
                    }

                    // 2) Try SegmentTemplate — segmented fMP4 (Tidal LOSSLESS / HiRes path).
                    // Decoder will concatenate init + segments to reconstruct a playable file.
                    if (!_streamURL && !_drmProtected) {
                        NSRange tplRange = [manifestStr rangeOfString:@"<SegmentTemplate"];
                        if (tplRange.location != NSNotFound) {
                            NSRange endRange = [manifestStr rangeOfString:@"/>"
                                                                   options:0
                                                                     range:NSMakeRange(tplRange.location, manifestStr.length - tplRange.location)];
                            if (endRange.location == NSNotFound) {
                                endRange = [manifestStr rangeOfString:@">"
                                                              options:0
                                                                range:NSMakeRange(tplRange.location, manifestStr.length - tplRange.location)];
                            }
                            if (endRange.location != NSNotFound) {
                                NSRange tagRange = NSMakeRange(tplRange.location,
                                                               endRange.location + endRange.length - tplRange.location);
                                NSString *tplTag = [manifestStr substringWithRange:tagRange];
                                NSString *initURL = extractXMLAttr(tplTag, @"initialization");
                                NSString *mediaTpl = extractXMLAttr(tplTag, @"media");
                                NSString *startStr = extractXMLAttr(tplTag, @"startNumber");
                                NSString *timescaleStr = extractXMLAttr(tplTag, @"timescale");
                                NSString *segDurStr = extractXMLAttr(tplTag, @"duration");

                                double timescale = [timescaleStr doubleValue];
                                if (timescale <= 0) timescale = 1;
                                double segDurUnits = [segDurStr doubleValue];
                                double segDurSec = (segDurUnits > 0) ? (segDurUnits / timescale) : 0;

                                NSString *mpdDurStr = extractXMLAttr(manifestStr, @"mediaPresentationDuration");
                                double totalSec = parseISO8601Duration(mpdDurStr);

                                if (initURL.length && mediaTpl.length && segDurSec > 0 && totalSec > 0
                                    && [mediaTpl containsString:@"$Number$"]) {
                                    _dashInitURL = [initURL copy];
                                    _dashMediaTemplate = [mediaTpl copy];
                                    _dashStartNumber = startStr.length ? [startStr integerValue] : 1;
                                    _dashSegmentCount = (NSInteger)ceil(totalSec / segDurSec);
                                    tidal::logInfo([[NSString stringWithFormat:
                                        @"DASH SegmentTemplate: %ld segments × %.2fs (total %.1fs)",
                                        (long)_dashSegmentCount, segDurSec, totalSec] UTF8String]);
                                } else {
                                    tidal::logDebug([[NSString stringWithFormat:
                                        @"DASH SegmentTemplate parse incomplete: init=%@ media=%@ segDur=%.2f totalSec=%.1f",
                                        initURL ?: @"(nil)", mediaTpl ?: @"(nil)", segDurSec, totalSec] UTF8String]);
                                }
                            }
                        }
                    }

                    if (!_streamURL && _dashSegmentCount == 0) {
                        tidal::logDebug("DASH manifest: no playable URL or SegmentTemplate, will fall back");
                    }
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
