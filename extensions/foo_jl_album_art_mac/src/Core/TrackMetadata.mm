//
//  TrackMetadata.mm
//  foo_jl_album_art_mac
//
//  Immutable metadata snapshot implementation (Foundation-only)
//

#import "TrackMetadata.h"

@implementation TrackMetadata

- (instancetype)initWithArtist:(NSString *)artist
                   albumArtist:(NSString *)albumArtist
                         album:(NSString *)album
                         title:(NSString *)title
          musicBrainzReleaseID:(nullable NSString *)mbReleaseID
     musicBrainzReleaseGroupID:(nullable NSString *)mbReleaseGroupID
              discogsReleaseID:(nullable NSString *)discogsReleaseID
                     trackPath:(nullable NSString *)trackPath {
    self = [super init];
    if (self) {
        _artist = [artist copy] ?: @"";
        _albumArtist = albumArtist.length > 0 ? [albumArtist copy] : _artist;
        _album = [album copy] ?: @"";
        _title = [title copy] ?: @"";
        _musicBrainzReleaseID = [mbReleaseID copy];
        _musicBrainzReleaseGroupID = [mbReleaseGroupID copy];
        _discogsReleaseID = [discogsReleaseID copy];
        _fileURL = [TrackMetadata fileURLFromFB2KPath:trackPath];
        _folderURL = [_fileURL URLByDeletingLastPathComponent];
    }
    return self;
}

+ (nullable NSURL *)fileURLFromFB2KPath:(nullable NSString *)path {
    if (path.length == 0) {
        return nil;
    }

    NSString *nativePath = path;

    NSRange schemeRange = [path rangeOfString:@"://"];
    if (schemeRange.location != NSNotFound) {
        NSString *scheme = [[path substringToIndex:schemeRange.location] lowercaseString];
        if (![scheme isEqualToString:@"file"]) {
            return nil;  // Stream / remote track - no local file
        }
        // foobar2000 emits "file://" + unencoded native path, so strip the
        // prefix and treat the remainder as a plain path. NSURL URLWithString:
        // would return nil for paths containing spaces.
        nativePath = [path substringFromIndex:NSMaxRange(schemeRange)];
    }

    if (nativePath.length == 0 || ![nativePath hasPrefix:@"/"]) {
        return nil;
    }

    return [NSURL fileURLWithPath:nativePath];
}

- (BOOL)isSearchable {
    // Need at least artist and album to search
    return self.artist.length > 0 && self.album.length > 0;
}

- (BOOL)hasMusicBrainzIDs {
    return self.musicBrainzReleaseID.length > 0 ||
           self.musicBrainzReleaseGroupID.length > 0;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<TrackMetadata: %@ - %@ [MBID: %@]>",
            self.albumArtist, self.album,
            self.musicBrainzReleaseID ?: @"none"];
}

@end
