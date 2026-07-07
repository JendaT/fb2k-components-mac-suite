//
//  ResponseParser.mm
//  foo_jl_tidal_mac
//

#import "ResponseParser.h"
#include "TidalLog.h"

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
    NSDictionary *user = json[@"user"];
    NSString *userId = [user[@"userId"] description];
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
    for (NSDictionary *trackDict in items) {
        JLTidalTrack *track = [[JLTidalTrack alloc] initWithDictionary:trackDict];
        if (track) {
            [tracks addObject:track];
        }
    }
    return [tracks copy];
}

+ (NSArray<JLTidalAlbum *> *)albumsFromItems:(NSArray *)items {
    NSMutableArray<JLTidalAlbum *> *albums = [NSMutableArray array];
    for (NSDictionary *albumDict in items) {
        JLTidalAlbum *album = [[JLTidalAlbum alloc] initWithDictionary:albumDict];
        if (album) {
            [albums addObject:album];
        }
    }
    return [albums copy];
}

+ (NSArray<JLTidalArtist *> *)artistsFromItems:(NSArray *)items {
    NSMutableArray<JLTidalArtist *> *artists = [NSMutableArray array];
    for (NSDictionary *artistDict in items) {
        JLTidalArtist *artist = [[JLTidalArtist alloc] initWithDictionary:artistDict];
        if (artist) {
            [artists addObject:artist];
        }
    }
    return [artists copy];
}

+ (NSArray<JLTidalPlaylist *> *)playlistsFromItems:(NSArray *)items {
    NSMutableArray<JLTidalPlaylist *> *playlists = [NSMutableArray array];
    for (NSDictionary *playlistDict in items) {
        JLTidalPlaylist *playlist = [[JLTidalPlaylist alloc] initWithDictionary:playlistDict];
        if (playlist) {
            [playlists addObject:playlist];
        }
    }
    return [playlists copy];
}

+ (NSArray<JLTidalTrack *> *)tracksFromWrappedItems:(NSArray *)items {
    NSMutableArray<JLTidalTrack *> *tracks = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSDictionary *trackDict = item[@"item"];
        if (!trackDict) trackDict = item;

        JLTidalTrack *track = [[JLTidalTrack alloc] initWithDictionary:trackDict];
        if (track) {
            [tracks addObject:track];
        }
    }
    return [tracks copy];
}

+ (NSArray<JLTidalAlbum *> *)albumsFromWrappedItems:(NSArray *)items {
    NSMutableArray<JLTidalAlbum *> *albums = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSDictionary *albumDict = item[@"item"];
        if (!albumDict) albumDict = item;

        JLTidalAlbum *album = [[JLTidalAlbum alloc] initWithDictionary:albumDict];
        if (album) {
            [albums addObject:album];
        }
    }
    return [albums copy];
}

+ (NSArray<JLTidalPlaylistFolder *> *)foldersFromItems:(NSArray *)items {
    NSMutableArray<JLTidalPlaylistFolder *> *folders = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSString *type = item[@"type"];
        if ([type isEqualToString:@"FOLDER"]) {
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
    for (NSDictionary *trackDict in items) {
        JLTidalTrack *track = [[JLTidalTrack alloc] initWithDictionary:trackDict];
        // Match ISRC exactly
        if (track && [track.isrc isEqualToString:isrc]) {
            [matches addObject:track];
        }
    }
    return [matches copy];
}

@end
