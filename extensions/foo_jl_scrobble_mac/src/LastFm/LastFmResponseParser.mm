//
//  LastFmResponseParser.mm
//  foo_jl_scrobble_mac
//
//  Pure parsing of Last.fm API JSON responses
//

#import "LastFmResponseParser.h"
#import "../Core/TopAlbum.h"

@implementation LastFmResponseParser

+ (void)scrobbleResponse:(NSDictionary *)response
                accepted:(NSInteger *)accepted
                 ignored:(NSInteger *)ignored {
    *accepted = 0;
    *ignored = 0;

    NSDictionary *scrobbles = response[@"scrobbles"];
    if (![scrobbles isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *attr = scrobbles[@"@attr"];
    if (![attr isKindOfClass:[NSDictionary class]]) return;

    *accepted = [attr[@"accepted"] integerValue];
    *ignored = [attr[@"ignored"] integerValue];
}

+ (BOOL)nowPlayingConfirmedInResponse:(NSDictionary *)response {
    return response[@"nowplaying"] != nil;
}

+ (NSString *)tokenFromResponse:(NSDictionary *)response {
    NSString *token = response[@"token"];
    if ([token isKindOfClass:[NSString class]] && token.length > 0) {
        return token;
    }
    return nil;
}

+ (NSString *)usernameFromUserInfoResponse:(NSDictionary *)response {
    NSDictionary *user = response[@"user"];
    if (![user isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = user[@"name"];
    return [name isKindOfClass:[NSString class]] ? name : nil;
}

+ (NSURL *)userImageURLFromUserInfoResponse:(NSDictionary *)response {
    NSDictionary *user = response[@"user"];
    if (![user isKindOfClass:[NSDictionary class]]) return nil;

    // Last.fm returns an array of sizes; we want "large" (174x174),
    // upgraded to "extralarge" (300x300) when present
    NSURL *imageURL = nil;
    NSArray *images = user[@"image"];
    if ([images isKindOfClass:[NSArray class]]) {
        for (NSDictionary *img in images) {
            if (![img isKindOfClass:[NSDictionary class]]) continue;
            NSString *size = img[@"size"];
            NSString *urlStr = img[@"#text"];
            if ([size isEqualToString:@"large"] || [size isEqualToString:@"extralarge"]) {
                if ([urlStr isKindOfClass:[NSString class]] && urlStr.length > 0) {
                    imageURL = [NSURL URLWithString:urlStr];
                    if ([size isEqualToString:@"extralarge"]) {
                        break;  // Prefer extralarge
                    }
                }
            }
        }
    }
    return imageURL;
}

+ (NSArray<NSDictionary *> *)recentTrackDictsFromResponse:(NSDictionary *)response {
    NSDictionary *recentTracks = response[@"recenttracks"];
    if (![recentTracks isKindOfClass:[NSDictionary class]]) return @[];

    id trackData = recentTracks[@"track"];
    if ([trackData isKindOfClass:[NSArray class]]) {
        NSMutableArray *tracks = [NSMutableArray array];
        for (id trackDict in (NSArray *)trackData) {
            if ([trackDict isKindOfClass:[NSDictionary class]]) {
                [tracks addObject:trackDict];
            }
        }
        return tracks;
    }
    if ([trackData isKindOfClass:[NSDictionary class]]) {
        // Single track is returned as object, not array
        return @[trackData];
    }
    return @[];
}

+ (NSInteger)totalPagesFromRecentTracksResponse:(NSDictionary *)response {
    NSDictionary *recentTracks = response[@"recenttracks"];
    if (![recentTracks isKindOfClass:[NSDictionary class]]) return 0;
    NSDictionary *attr = recentTracks[@"@attr"];
    if (![attr isKindOfClass:[NSDictionary class]]) return 0;
    return [attr[@"totalPages"] integerValue];
}

+ (NSInteger)totalFromRecentTracksResponse:(NSDictionary *)response {
    NSDictionary *recentTracks = response[@"recenttracks"];
    if (![recentTracks isKindOfClass:[NSDictionary class]]) return 0;
    NSDictionary *attr = recentTracks[@"@attr"];
    if (![attr isKindOfClass:[NSDictionary class]]) return 0;
    return [attr[@"total"] integerValue];
}

+ (BOOL)containsActualScrobbles:(NSArray<NSDictionary *> *)trackDicts {
    for (NSDictionary *track in trackDicts) {
        if (![track isKindOfClass:[NSDictionary class]]) continue;
        if (track[@"@attr"][@"nowplaying"] == nil) {
            return YES;
        }
    }
    return NO;
}

+ (NSArray<TopAlbum *> *)topItemsFromResponse:(NSDictionary *)response
                                      rootKey:(NSString *)rootKey
                                      itemKey:(NSString *)itemKey
                                    asArtists:(BOOL)asArtists {
    NSMutableArray<TopAlbum *> *items = [NSMutableArray array];

    NSDictionary *root = response[rootKey];
    if (![root isKindOfClass:[NSDictionary class]]) return items;
    NSArray *itemArray = root[itemKey];
    if (![itemArray isKindOfClass:[NSArray class]]) return items;

    for (NSDictionary *itemDict in itemArray) {
        TopAlbum *item = [TopAlbum albumFromDictionary:itemDict];
        if (item) {
            if (asArtists) {
                // For artists, the item IS the artist
                item.artist = item.name;
            }
            [items addObject:item];
        }
    }
    return items;
}

+ (NSURL *)albumImageURLFromAlbumInfoResponse:(NSDictionary *)response {
    NSDictionary *albumInfo = response[@"album"];
    if (![albumInfo isKindOfClass:[NSDictionary class]]) return nil;
    return [TopAlbum bestImageURLFromArray:albumInfo[@"image"]];
}

+ (void)trackInfoFromResponse:(NSDictionary *)response
                    albumName:(NSString **)albumName
                     imageURL:(NSURL **)imageURL {
    *albumName = nil;
    *imageURL = nil;

    NSDictionary *trackInfo = response[@"track"];
    if (![trackInfo isKindOfClass:[NSDictionary class]]) return;

    NSDictionary *albumDict = trackInfo[@"album"];
    if ([albumDict isKindOfClass:[NSDictionary class]]) {
        NSString *title = albumDict[@"title"];
        if ([title isKindOfClass:[NSString class]]) {
            *albumName = title;
        }
        *imageURL = [TopAlbum bestImageURLFromArray:albumDict[@"image"]];
    }
}

@end
