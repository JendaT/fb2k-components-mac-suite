//
//  ResponseParser.mm
//  foo_jl_tidal_mac
//

#import "ResponseParser.h"
#include "TidalLog.h"

// Server-controlled "items" payloads are consumed by fast enumeration that
// immediately subscripts elements; a non-array container or non-dictionary
// element (error payloads do this) would throw unrecognized selector.
// Guard both levels once, uniformly, in every ...FromItems: method.
static NSArray *JLTidalSafeItemsArray(NSArray *items) {
    return [items isKindOfClass:[NSArray class]] ? items : @[];
}

static BOOL JLTidalIsDictionary(id obj) {
    return [obj isKindOfClass:[NSDictionary class]];
}

@implementation JLTidalResponseParser

#pragma mark - OAuth token responses

+ (JLTidalSession *)sessionFromTokenResponse:(NSDictionary *)json {
    NSString *accessToken = json[@"access_token"];
    NSString *refreshToken = json[@"refresh_token"];
    NSNumber *expiresIn = json[@"expires_in"] ?: @(86400);

    if (!accessToken || !refreshToken) {
        return nil;
    }

    // Extract user info if present
    NSDictionary *user = JLTidalIsDictionary(json[@"user"]) ? json[@"user"] : nil;
    id rawUserId = user[@"userId"];
    NSString *userId = (rawUserId && rawUserId != [NSNull null]) ? [rawUserId description] : nil;
    NSString *username = user[@"username"];
    NSString *countryCode = user[@"countryCode"];

    return [[JLTidalSession alloc] initWithAccessToken:accessToken
                                          refreshToken:refreshToken
                                             expiresIn:expiresIn.doubleValue
                                                userId:userId
                                              username:username
                                           countryCode:countryCode];
}

+ (JLTidalSession *)sessionFromRefreshResponse:(NSDictionary *)json
                                currentSession:(JLTidalSession *)currentSession {
    NSString *accessToken = json[@"access_token"];
    NSString *newRefreshToken = json[@"refresh_token"];
    NSNumber *expiresIn = json[@"expires_in"] ?: @(86400);

    if (!accessToken) {
        return nil;
    }

    if (newRefreshToken.length > 0) {
        tidal::logDebug("Refresh token rotated");
        return [[JLTidalSession alloc] initWithAccessToken:accessToken
                                              refreshToken:newRefreshToken
                                                 expiresIn:expiresIn.doubleValue
                                                    userId:currentSession.userId
                                                  username:currentSession.username
                                               countryCode:currentSession.countryCode];
    }
    return [currentSession sessionByUpdatingAccessToken:accessToken
                                              expiresIn:expiresIn.doubleValue];
}

#pragma mark - Item lists

+ (NSArray<JLTidalTrack *> *)tracksFromItems:(NSArray *)items {
    NSMutableArray<JLTidalTrack *> *tracks = [NSMutableArray array];
    for (NSDictionary *trackDict in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(trackDict)) continue;
        JLTidalTrack *track = [[JLTidalTrack alloc] initWithDictionary:trackDict];
        if (track) {
            [tracks addObject:track];
        }
    }
    return [tracks copy];
}

+ (NSArray<JLTidalAlbum *> *)albumsFromItems:(NSArray *)items {
    NSMutableArray<JLTidalAlbum *> *albums = [NSMutableArray array];
    for (NSDictionary *albumDict in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(albumDict)) continue;
        JLTidalAlbum *album = [[JLTidalAlbum alloc] initWithDictionary:albumDict];
        if (album) {
            [albums addObject:album];
        }
    }
    return [albums copy];
}

+ (NSArray<JLTidalArtist *> *)artistsFromItems:(NSArray *)items {
    NSMutableArray<JLTidalArtist *> *artists = [NSMutableArray array];
    for (NSDictionary *artistDict in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(artistDict)) continue;
        JLTidalArtist *artist = [[JLTidalArtist alloc] initWithDictionary:artistDict];
        if (artist) {
            [artists addObject:artist];
        }
    }
    return [artists copy];
}

+ (NSArray<JLTidalPlaylist *> *)playlistsFromItems:(NSArray *)items {
    NSMutableArray<JLTidalPlaylist *> *playlists = [NSMutableArray array];
    for (NSDictionary *playlistDict in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(playlistDict)) continue;
        JLTidalPlaylist *playlist = [[JLTidalPlaylist alloc] initWithDictionary:playlistDict];
        if (playlist) {
            [playlists addObject:playlist];
        }
    }
    return [playlists copy];
}

+ (NSArray<JLTidalTrack *> *)tracksFromWrappedItems:(NSArray *)items {
    NSMutableArray<JLTidalTrack *> *tracks = [NSMutableArray array];
    for (NSDictionary *item in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(item)) continue;
        NSDictionary *trackDict = item[@"item"];
        if (!JLTidalIsDictionary(trackDict)) trackDict = item;

        JLTidalTrack *track = [[JLTidalTrack alloc] initWithDictionary:trackDict];
        if (track) {
            [tracks addObject:track];
        }
    }
    return [tracks copy];
}

+ (NSArray<JLTidalAlbum *> *)albumsFromWrappedItems:(NSArray *)items {
    NSMutableArray<JLTidalAlbum *> *albums = [NSMutableArray array];
    for (NSDictionary *item in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(item)) continue;
        NSDictionary *albumDict = item[@"item"];
        if (!JLTidalIsDictionary(albumDict)) albumDict = item;

        JLTidalAlbum *album = [[JLTidalAlbum alloc] initWithDictionary:albumDict];
        if (album) {
            [albums addObject:album];
        }
    }
    return [albums copy];
}

+ (NSArray<JLTidalPlaylistFolder *> *)foldersFromItems:(NSArray *)items {
    NSMutableArray<JLTidalPlaylistFolder *> *folders = [NSMutableArray array];
    for (NSDictionary *item in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(item)) continue;
        NSString *type = item[@"type"];
        if ([type isKindOfClass:[NSString class]] && [type isEqualToString:@"FOLDER"]) {
            JLTidalPlaylistFolder *folder = [[JLTidalPlaylistFolder alloc] initWithDictionary:item];
            if (folder) {
                [folders addObject:folder];
            }
        }
    }
    return [folders copy];
}

+ (NSArray<JLTidalTrack *> *)tracksFromItems:(NSArray *)items
                               matchingISRC:(NSString *)isrc {
    NSMutableArray<JLTidalTrack *> *matches = [NSMutableArray array];
    for (NSDictionary *trackDict in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(trackDict)) continue;
        JLTidalTrack *track = [[JLTidalTrack alloc] initWithDictionary:trackDict];
        // Match ISRC exactly
        if (track && [track.isrc isEqualToString:isrc]) {
            [matches addObject:track];
        }
    }
    return [matches copy];
}

@end
