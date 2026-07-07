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

// Walk every <S t=... d=... r=.../> element in a SegmentTimeline block and
// return the total segment count. Each S contributes (r ?: 1) segments; the
// caller adds the implicit init/first segment base of 2 (mirrors python-tidal
// DashInfo.get_urls, /tmp/tidalapi/tidalapi/media.py:836-844).
static NSInteger countSegmentTimelineSElements(NSString *manifestStr) {
    if (manifestStr.length == 0) return 0;
    NSRange tlOpen = [manifestStr rangeOfString:@"<SegmentTimeline"];
    if (tlOpen.location == NSNotFound) return 0;
    NSRange tlClose = [manifestStr rangeOfString:@"</SegmentTimeline>"
                                          options:0
                                            range:NSMakeRange(tlOpen.location, manifestStr.length - tlOpen.location)];
    if (tlClose.location == NSNotFound) return 0;
    NSRange tlBody = NSMakeRange(NSMaxRange(tlOpen),
                                 tlClose.location - NSMaxRange(tlOpen));
    NSString *body = [manifestStr substringWithRange:tlBody];

    static NSRegularExpression *sElementRegex = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        sElementRegex = [NSRegularExpression regularExpressionWithPattern:@"<S\\b[^/>]*/?>"
                                                                  options:0
                                                                    error:nil];
    });
    __block NSInteger count = 0;
    [sElementRegex enumerateMatchesInString:body
                                    options:0
                                      range:NSMakeRange(0, body.length)
                                 usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        NSString *sTag = [body substringWithRange:m.range];
        NSString *rStr = extractXMLAttr(sTag, @"r");
        NSInteger r = rStr.length ? [rStr integerValue] : 0;
        count += (r > 0) ? r : 1;
    }];
    return count;
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

                // Always-on diagnostic when DASH is enabled — gives us ground truth
                // XML on the first user report. Truncated to 4 KB to keep log readable.
                if (manifestStr && tidal::TidalConfig::isDASHEnabled()) {
                    NSString *dump = manifestStr.length > 4096
                        ? [manifestStr substringToIndex:4096]
                        : manifestStr;
                    tidal::logInfo([[NSString stringWithFormat:@"DASH MPD raw (len=%lu):\n%@",
                                      (unsigned long)manifestStr.length, dump] UTF8String]);
                }

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
                    // Mirrors python-tidal DashInfo (tidalapi/media.py:824-859):
                    //   - Segment count = 1 + 1 (init + first media) + sum(r ?: 1) over SegmentTimeline.S
                    //   - $Number$ iterates from 0; media[0] IS the init segment (no separate download)
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
                                NSString *mediaTpl = extractXMLAttr(tplTag, @"media");

                                // Segment count = base (2) + sum of SegmentTimeline S contributions.
                                NSInteger segCount = 1 + 1 + countSegmentTimelineSElements(manifestStr);

                                if (mediaTpl.length && [mediaTpl containsString:@"$Number$"] && segCount > 2) {
                                    _dashMediaTemplate = [mediaTpl copy];
                                    _dashSegmentCount = segCount;
                                    tidal::logInfo([[NSString stringWithFormat:
                                        @"DASH SegmentTemplate: %ld segments (incl. init at $Number$=0)",
                                        (long)_dashSegmentCount] UTF8String]);
                                } else {
                                    tidal::logDebug([[NSString stringWithFormat:
                                        @"DASH SegmentTemplate parse incomplete: media=%@ count=%ld",
                                        mediaTpl ?: @"(nil)", (long)segCount] UTF8String]);
                                }
                            }
                        }

                        // Normalise codec from <Representation codecs="..."> — Tidal reports
                        // "flac", "mp4a.40.2", "mp4a.40.5" in DASH but FLAC/MP4A/MP4A as
                        // simple names in BTS. We want one canonical form for downstream
                        // MIME-type lookup. Mirrors python-tidal:644-655.
                        NSRange repRange = [manifestStr rangeOfString:@"<Representation"];
                        if (repRange.location != NSNotFound) {
                            NSRange repEnd = [manifestStr rangeOfString:@">"
                                                                options:0
                                                                  range:NSMakeRange(repRange.location, manifestStr.length - repRange.location)];
                            if (repEnd.location != NSNotFound) {
                                NSString *repTag = [manifestStr substringWithRange:
                                    NSMakeRange(repRange.location, repEnd.location + repEnd.length - repRange.location)];
                                NSString *dashCodec = extractXMLAttr(repTag, @"codecs");
                                if (dashCodec.length) {
                                    NSString *lower = [dashCodec lowercaseString];
                                    if ([lower containsString:@"flac"]) {
                                        _codec = @"FLAC";
                                    } else if ([lower hasPrefix:@"mp4a"]) {
                                        _codec = @"MP4A";
                                    } else if ([lower hasPrefix:@"ec-3"] || [lower hasPrefix:@"eac3"]) {
                                        _codec = @"EAC3";
                                    } else if ([lower hasPrefix:@"ac-4"] || [lower hasPrefix:@"ac4"]) {
                                        _codec = @"AC4";
                                    }
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
