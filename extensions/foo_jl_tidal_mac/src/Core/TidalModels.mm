//
//  TidalModels.mm
//  foo_jl_tidal_mac
//
//  Data models implementation
//

#import "TidalModels.h"
#import "ManifestParser.h"
#include "TidalLog.h"

// JSON values arrive untrusted; NSNull and numbers must never reach -isEqual:
// as if they were strings.
static BOOL JLTidalIsString(id obj) {
    return [obj isKindOfClass:[NSString class]];
}

static NSDateFormatter *sharedDateOnlyFormatter(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd";
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        // TIDAL sends a plain calendar date ("2024-01-01") with no zone. Parsing
        // it in the local zone yields local midnight, which every consumer then
        // reads back in UTC (LibraryLayout, the export tagger), shifting the
        // year back a day for anyone east of Greenwich -- 2024-01-01 files as
        // 2023 in Europe/Prague. Parse and render in UTC everywhere so the date
        // that arrives is the date that is shown, filed and tagged.
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
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

// String form of a JSON "id" value, or nil when the value is missing or
// NSNull — [NSNull description] would otherwise yield the literal "<null>"
// and flow into tidal://track/<null> URLs.
static NSString *stringIDFromValue(id value) {
    if (!value || value == [NSNull null]) return nil;
    return [value description];
}

@implementation JLTidalTrack

- (NSString *)displayTitle {
    NSString *title = self.title ?: @"";
    if (self.version.length == 0 ||
        [title rangeOfString:self.version options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return title;
    }
    return [NSString stringWithFormat:@"%@ (%@)", title, self.version];
}

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    self = [super init];
    if (self) {
        _trackID = stringIDFromValue(dict[@"id"]);
        if (_trackID.length == 0) return nil;
        id title = dict[@"title"];
        _title = [title isKindOfClass:[NSString class]] ? title : @"Unknown Title";
        _duration = [dict[@"duration"] integerValue];
        _trackNumber = [dict[@"trackNumber"] integerValue];
        _discNumber = [dict[@"volumeNumber"] integerValue];
        _isExplicit = [dict[@"explicit"] boolValue];

        // Availability. Absent means "no reason to think otherwise" -- only an
        // explicit false marks a track unplayable.
        id allowStreaming = dict[@"allowStreaming"];
        _allowStreaming = [allowStreaming isKindOfClass:[NSNumber class]] ? [allowStreaming boolValue] : YES;
        id streamReady = dict[@"streamReady"];
        _streamReady = [streamReady isKindOfClass:[NSNumber class]] ? [streamReady boolValue] : YES;

        if (JLTidalIsString(dict[@"version"]) && [dict[@"version"] length] > 0) {
            _version = dict[@"version"];
        }

        // Catalogue ReplayGain, when the response carries it.
        id gain = dict[@"replayGain"];
        if ([gain isKindOfClass:[NSNumber class]]) {
            _hasReplayGain = YES;
            _replayGain = [gain doubleValue];
            id peak = dict[@"peak"];
            _peakAmplitude = [peak isKindOfClass:[NSNumber class]] ? [peak doubleValue] : 1.0;
        }

        // Audio quality (returned by search API per track)
        id audioQuality = dict[@"audioQuality"];
        if ([audioQuality isKindOfClass:[NSString class]]) {
            _audioQuality = audioQuality;
        }

        id mediaMetadata = dict[@"mediaMetadata"];
        if ([mediaMetadata isKindOfClass:[NSDictionary class]]) {
            id tags = mediaMetadata[@"tags"];
            if ([tags isKindOfClass:[NSArray class]]) {
                NSMutableArray<NSString *> *clean = [NSMutableArray array];
                for (id tag in (NSArray *)tags) {
                    if ([tag isKindOfClass:[NSString class]]) [clean addObject:tag];
                }
                _mediaTags = clean;
            }
        }
        if (tidal::isDebugLoggingCached()) {
            tidal::logDebug([[NSString stringWithFormat:
                @"Track %@ quality fields: audioQuality=%@ mediaTags=%@",
                _trackID ?: @"?", _audioQuality ?: @"(nil)",
                _mediaTags ? [_mediaTags componentsJoinedByString:@","] : @"(absent)"] UTF8String]);
        }

        // Artist - may be nested object or null
        id artist = dict[@"artist"];
        if ([artist isKindOfClass:[NSDictionary class]]) {
            id artistName = artist[@"name"];
            if ([artistName isKindOfClass:[NSString class]]) _artist = artistName;
        } else if ([artist isKindOfClass:[NSString class]]) {
            _artist = artist;
        }

        // Every credited name, in response order. A collaboration otherwise
        // loses its featured artists entirely.
        NSArray *artists = dict[@"artists"];
        if ([artists isKindOfClass:[NSArray class]] && artists.count > 0) {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (id entry in (NSArray *)artists) {
                if (![entry isKindOfClass:[NSDictionary class]]) continue;
                id name = ((NSDictionary *)entry)[@"name"];
                if (JLTidalIsString(name) && [name length] > 0) [names addObject:name];
            }
            if (names.count > 0) _allArtists = [names copy];
        }

        // Fallback to artists array (plural) if singular artist is missing
        if (!_artist.length) {
            _artist = _allArtists.firstObject;
        }

        // Album - may be nested object
        id album = dict[@"album"];
        if ([album isKindOfClass:[NSDictionary class]]) {
            id albumTitle = album[@"title"];
            if ([albumTitle isKindOfClass:[NSString class]]) _album = albumTitle;
            NSString *albumID = stringIDFromValue(album[@"id"]);
            if (albumID.length > 0) _albumID = albumID;

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
                id albumArtistName = albumArtist[@"name"];
                if ([albumArtistName isKindOfClass:[NSString class]]) _albumArtist = albumArtistName;
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

        // Tempo and key. Absent, null, 0 and "UNKNOWN" all mean the catalogue
        // has none.
        id bpm = dict[@"bpm"];
        if ([bpm isKindOfClass:[NSNumber class]] && [bpm doubleValue] > 0) {
            _bpm = [bpm doubleValue];
        }
        id key = dict[@"key"];
        if (JLTidalIsString(key) && [key length] > 0 && ![key isEqualToString:@"UNKNOWN"]) {
            _key = key;
        }
        id keyScale = dict[@"keyScale"];
        if (JLTidalIsString(keyScale) && [keyScale length] > 0 && ![keyScale isEqualToString:@"UNKNOWN"]) {
            _keyScale = keyScale;
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
        _albumID = stringIDFromValue(dict[@"id"]);
        if (_albumID.length == 0) return nil;
        id title = dict[@"title"];
        _title = [title isKindOfClass:[NSString class]] ? title : @"Unknown Album";
        _numberOfTracks = [dict[@"numberOfTracks"] integerValue];
        _duration = [dict[@"duration"] integerValue];

        // Audio quality (same NSNull guard as JLTidalTrack)
        id audioQuality = dict[@"audioQuality"];
        if ([audioQuality isKindOfClass:[NSString class]]) {
            _audioQuality = audioQuality;
        }

        // Artist - may be nested object or null
        id artist = dict[@"artist"];
        if ([artist isKindOfClass:[NSDictionary class]]) {
            id artistName = artist[@"name"];
            if ([artistName isKindOfClass:[NSString class]]) _artist = artistName;
        } else if ([artist isKindOfClass:[NSString class]]) {
            _artist = artist;
        }

        // Fallback to artists array (plural) if singular artist is missing
        if (!_artist.length) {
            NSArray *artists = dict[@"artists"];
            if ([artists isKindOfClass:[NSArray class]] && artists.count > 0) {
                NSDictionary *firstArtist = artists[0];
                if ([firstArtist isKindOfClass:[NSDictionary class]]) {
                    id firstName = firstArtist[@"name"];
                    if ([firstName isKindOfClass:[NSString class]]) _artist = firstName;
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
        _artistID = stringIDFromValue(dict[@"id"]);
        if (_artistID.length == 0) return nil;
        id name = dict[@"name"];
        _name = [name isKindOfClass:[NSString class]] ? name : @"Unknown Artist";

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
        id rawUUID = dict[@"uuid"];
        _playlistUUID = [rawUUID isKindOfClass:[NSString class]]
            ? rawUUID : stringIDFromValue(dict[@"id"]);
        if (_playlistUUID.length == 0) return nil;
        id title = dict[@"title"];
        _title = [title isKindOfClass:[NSString class]] ? title : @"Untitled Playlist";
        id desc = dict[@"description"];
        if ([desc isKindOfClass:[NSString class]]) _playlistDescription = desc;
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
            _folderID = stringIDFromValue(dict[@"id"]) ?: [[NSUUID UUID] UUIDString];
        }

        id name = dict[@"name"];
        _name = [name isKindOfClass:[NSString class]] ? name : @"Untitled Folder";
        id parentID = dict[@"parentFolderId"];
        if ([parentID isKindOfClass:[NSString class]]) _parentFolderID = parentID;
        _subfolders = [NSMutableArray array];
        _playlistUUIDs = [NSMutableArray array];

        // Parse nested items if present
        NSArray *items = dict[@"items"];
        if ([items isKindOfClass:[NSArray class]]) {
            for (NSDictionary *item in items) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                id type = item[@"type"];
                if (![type isKindOfClass:[NSString class]]) continue;
                if ([type isEqualToString:@"FOLDER"]) {
                    JLTidalPlaylistFolder *subfolder = [[JLTidalPlaylistFolder alloc] initWithDictionary:item];
                    if (subfolder) {
                        [_subfolders addObject:subfolder];
                    }
                } else if ([type isEqualToString:@"PLAYLIST"]) {
                    NSDictionary *data = item[@"data"];
                    if (![data isKindOfClass:[NSDictionary class]]) continue;
                    id rawUUID = data[@"uuid"];
                    NSString *uuid = [rawUUID isKindOfClass:[NSString class]]
                        ? rawUUID : stringIDFromValue(data[@"id"]);
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

        // Parse audio quality info
        NSString *audioQuality = dict[@"audioQuality"];
        _quality = [JLTidalManifestParser qualityFromString:audioQuality
                                                   fallback:requestedQuality];

        _bitDepth = [dict[@"bitDepth"] integerValue];
        _sampleRate = [dict[@"sampleRate"] integerValue];
        _codec = dict[@"codec"];

        // ReplayGain travels with the stream response; fb2k can apply it if we
        // pass it on, which keeps TIDAL tracks at the same level as local files
        // in a mixed playlist.
        id trackGain = dict[@"trackReplayGain"];
        if ([trackGain isKindOfClass:[NSNumber class]]) {
            _hasReplayGain = YES;
            _trackReplayGain = [trackGain doubleValue];
            id peak = dict[@"trackPeakAmplitude"];
            _trackPeakAmplitude = [peak isKindOfClass:[NSNumber class]] ? [peak doubleValue] : 1.0;
        }
        id albumGain = dict[@"albumReplayGain"];
        if ([albumGain isKindOfClass:[NSNumber class]]) {
            _hasAlbumReplayGain = YES;
            _albumReplayGain = [albumGain doubleValue];
            id albumPeak = dict[@"albumPeakAmplitude"];
            _albumPeakAmplitude = [albumPeak isKindOfClass:[NSNumber class]] ? [albumPeak doubleValue] : 1.0;
        }

        // Parse manifest
        _manifestMimeType = dict[@"manifestMimeType"];
        _manifest = dict[@"manifest"];

        // A tier-gated or unsubscribed track answers HTTP 200 with a ~30s
        // sample. Nothing downstream can tell that from a full track -- the
        // metadata overlay stamps the catalogue duration over the decoder's
        // real length -- so it has to be caught here. Absent is treated as
        // PREVIEW so a response shape change fails closed, not silently short.
        NSString *presentation = JLTidalIsString(dict[@"assetPresentation"])
            ? dict[@"assetPresentation"] : nil;
        _previewOnly = ![presentation isEqualToString:@"FULL"];
        _previewReason = JLTidalIsString(dict[@"previewReason"]) ? dict[@"previewReason"] : nil;
        if (_previewOnly) {
            tidal::logInfo([[NSString stringWithFormat:
                             @"Track %@ returned a %@ asset (reason: %@)",
                             trackID, presentation ?: @"(absent)",
                             _previewReason ?: @"none given"] UTF8String]);
        }

        tidal::logDebug([[NSString stringWithFormat:@"Playback info: quality=%@, codec=%@, manifestType=%@",
                          audioQuality ?: @"(nil)", _codec ?: @"(nil)", _manifestMimeType ?: @"(nil)"] UTF8String]);

        // Check for DRM and extract stream URL / DASH template.
        // Parsing lives in JLTidalManifestParser (pure, unit-tested).
        _drmProtected = NO;
        if (_manifest) {
            JLTidalManifestResult *parsed = [JLTidalManifestParser parseManifest:_manifest
                                                                        mimeType:_manifestMimeType];
            _rawDASHManifest = parsed.rawDASHManifest;
            _drmProtected = parsed.drmProtected;
            _streamURL = parsed.streamURL;
            _dashMediaTemplate = parsed.dashMediaTemplate;
            _dashSegmentCount = parsed.dashSegmentCount;
            _dashTotalDuration = parsed.dashTotalDuration;
            _dashTimescale = parsed.dashTimescale;
            if (parsed.normalizedCodec) {
                _codec = parsed.normalizedCodec;
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
        // %.1f, not integer division: 44100 and 88200 otherwise render as
        // "44kHz" and "88kHz" right next to fb2k's own correct sample rate.
        case JLTidalQualityHiResLossless:
            return [NSString stringWithFormat:@"HiFi Plus (%ld-bit/%.1fkHz)",
                    (long)_bitDepth, _sampleRate / 1000.0];
        case JLTidalQualityHiRes:
            // Retired tier; only reachable when the server still answers
            // HI_RES. Reported as plain hi-res, not as MQA.
            return [NSString stringWithFormat:@"HiFi (%ld-bit/%.1fkHz)",
                    (long)_bitDepth, _sampleRate / 1000.0];
        case JLTidalQualityLossless:
            return _sampleRate > 0
                ? [NSString stringWithFormat:@"Lossless (%ld-bit/%.1fkHz)",
                   (long)(_bitDepth > 0 ? _bitDepth : 16), _sampleRate / 1000.0]
                : @"Lossless (16-bit/44.1kHz)";
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
