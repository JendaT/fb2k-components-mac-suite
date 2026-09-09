//
//  TidalModels.mm
//  foo_jl_tidal_mac
//
//  Data models implementation
//

#import "TidalModels.h"
#import "ManifestParser.h"
#include "TidalLog.h"

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

// String form of a JSON "id" value, or nil when the value is missing or
// NSNull — [NSNull description] would otherwise yield the literal "<null>"
// and flow into tidal://track/<null> URLs.
static NSString *stringIDFromValue(id value) {
    if (!value || value == [NSNull null]) return nil;
    return [value description];
}

@implementation JLTidalTrack

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

        // Audio quality (returned by search API per track)
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

        // Album - may be nested object
        id album = dict[@"album"];
        if ([album isKindOfClass:[NSDictionary class]]) {
            id albumTitle = album[@"title"];
            if ([albumTitle isKindOfClass:[NSString class]]) _album = albumTitle;

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

        // Parse manifest
        _manifestMimeType = dict[@"manifestMimeType"];
        _manifest = dict[@"manifest"];

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
