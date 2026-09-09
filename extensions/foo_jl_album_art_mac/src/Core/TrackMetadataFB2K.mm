//
//  TrackMetadataFB2K.mm
//  foo_jl_album_art_mac
//
//  SDK-dependent metadata extraction
//

#import "TrackMetadata+FB2K.h"

static NSString *RequiredField(const file_info &info, const char *field) {
    const char *value = info.meta_get(field, 0);
    if (value && value[0] != '\0') {
        return [NSString stringWithUTF8String:value];
    }
    return @"";
}

static NSString *_Nullable OptionalField(const file_info &info, NSArray<NSString *> *fields) {
    for (NSString *field in fields) {
        const char *value = info.meta_get([field UTF8String], 0);
        if (value && value[0] != '\0') {
            return [NSString stringWithUTF8String:value];
        }
    }
    return nil;
}

@implementation TrackMetadata (FB2K)

+ (nullable instancetype)metadataFromTrack:(metadb_handle_ptr)track {
    if (!track.is_valid()) {
        return nil;
    }

    const char *path = track->get_path();
    NSString *trackPath = (path && path[0] != '\0') ? [NSString stringWithUTF8String:path] : nil;

    metadb_info_container::ptr infoPtr;
    if (!track->get_info_ref(infoPtr) || !infoPtr.is_valid()) {
        return [[TrackMetadata alloc] initWithArtist:@""
                                         albumArtist:@""
                                               album:@""
                                               title:@""
                                musicBrainzReleaseID:nil
                           musicBrainzReleaseGroupID:nil
                                    discogsReleaseID:nil
                                           trackPath:trackPath];
    }

    const file_info &info = infoPtr->info();

    NSString *artist = RequiredField(info, "ARTIST");
    NSString *albumArtist = OptionalField(info, @[@"ALBUM ARTIST", @"ALBUMARTIST"]) ?: @"";

    return [[TrackMetadata alloc] initWithArtist:artist
                                     albumArtist:albumArtist
                                           album:RequiredField(info, "ALBUM")
                                           title:RequiredField(info, "TITLE")
                            musicBrainzReleaseID:OptionalField(info, @[@"MUSICBRAINZ_RELEASEID",
                                                                       @"MUSICBRAINZ RELEASE ID",
                                                                       @"MUSICBRAINZ_ALBUMID",
                                                                       @"MUSICBRAINZ ALBUM ID"])
                       musicBrainzReleaseGroupID:OptionalField(info, @[@"MUSICBRAINZ_RELEASEGROUPID",
                                                                       @"MUSICBRAINZ RELEASE GROUP ID",
                                                                       @"MUSICBRAINZ_ALBUMGROUPID"])
                                discogsReleaseID:OptionalField(info, @[@"DISCOGS_RELEASE_ID",
                                                                       @"DISCOGS RELEASE ID",
                                                                       @"DISCOGSID"])
                                       trackPath:trackPath];
}

@end
