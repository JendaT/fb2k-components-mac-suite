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

static BOOL JLTidalIsString(id obj) {
    return [obj isKindOfClass:[NSString class]];
}

@implementation JLTidalFolderListing

- (instancetype)initWithFolders:(NSArray<JLTidalPlaylistFolder *> *)folders
                  playlistUUIDs:(NSArray<NSString *> *)playlistUUIDs
                         cursor:(NSString *)cursor
             malformedItemCount:(NSInteger)malformedItemCount {
    self = [super init];
    if (self) {
        _folders = [folders copy];
        _playlistUUIDs = [playlistUUIDs copy];
        _cursor = [cursor copy];
        _malformedItemCount = malformedItemCount;
    }
    return self;
}

@end

@implementation JLTidalResponseParser

+ (NSArray<NSString *> *)trackIDsFromJSONAPIData:(id)data {
    if (![data isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    for (id entry in (NSArray *)data) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        id identifier = ((NSDictionary *)entry)[@"id"];
        if (JLTidalIsString(identifier) && ((NSString *)identifier).length > 0) {
            [ids addObject:identifier];
        }
    }
    return [ids copy];
}

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
    NSString *username = JLTidalIsString(user[@"username"]) ? user[@"username"] : nil;
    NSString *email = JLTidalIsString(user[@"email"]) ? user[@"email"] : nil;
    NSString *countryCode = JLTidalIsString(user[@"countryCode"]) ? user[@"countryCode"] : nil;

    return [[JLTidalSession alloc] initWithAccessToken:accessToken
                                          refreshToken:refreshToken
                                             expiresIn:expiresIn.doubleValue
                                                userId:userId
                                              username:username
                                                 email:email
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
                                                     email:currentSession.email
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

#pragma mark - v2 folders listing

static BOOL JLTidalItemHasType(NSDictionary *item, NSString *itemType) {
    id type = item[@"itemType"];
    return JLTidalIsString(type) && [type isEqualToString:itemType];
}

// UUID of a PLAYLIST listing item: data.uuid, else the "trn:playlist:<uuid>"
// suffix. A playlist item's data keys were not captured live, hence the
// fallback. nil when neither yields a value.
static NSString *JLTidalPlaylistUUIDFromFolderItem(NSDictionary *item) {
    id data = item[@"data"];
    if (JLTidalIsDictionary(data)) {
        id uuid = ((NSDictionary *)data)[@"uuid"];
        if (JLTidalIsString(uuid) && [uuid length] > 0) return uuid;
    }
    static NSString * const kPlaylistTRNPrefix = @"trn:playlist:";
    id trn = item[@"trn"];
    if (JLTidalIsString(trn) && [trn hasPrefix:kPlaylistTRNPrefix] &&
        [trn length] > kPlaylistTRNPrefix.length) {
        return [trn substringFromIndex:kPlaylistTRNPrefix.length];
    }
    return nil;
}

+ (NSArray<JLTidalPlaylistFolder *> *)foldersFromItems:(NSArray *)items {
    NSMutableArray<JLTidalPlaylistFolder *> *folders = [NSMutableArray array];
    for (NSDictionary *item in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(item) || !JLTidalItemHasType(item, @"FOLDER")) continue;
        JLTidalPlaylistFolder *folder = [[JLTidalPlaylistFolder alloc] initWithDictionary:item];
        if (folder) {
            [folders addObject:folder];
        }
    }
    return [folders copy];
}

+ (NSArray<NSString *> *)playlistUUIDsFromFolderItems:(NSArray *)items {
    NSMutableArray<NSString *> *uuids = [NSMutableArray array];
    for (NSDictionary *item in JLTidalSafeItemsArray(items)) {
        if (!JLTidalIsDictionary(item) || !JLTidalItemHasType(item, @"PLAYLIST")) continue;
        NSString *uuid = JLTidalPlaylistUUIDFromFolderItem(item);
        if (uuid) [uuids addObject:uuid];
    }
    return [uuids copy];
}

+ (JLTidalFolderListing *)folderListingFromResponse:(id)json {
    if (!JLTidalIsDictionary(json)) return nil;
    id items = ((NSDictionary *)json)[@"items"];
    if (![items isKindOfClass:[NSArray class]]) return nil;

    NSArray<JLTidalPlaylistFolder *> *folders = [self foldersFromItems:items];
    NSArray<NSString *> *uuids = [self playlistUUIDsFromFolderItems:items];

    NSInteger folderItems = 0, playlistItems = 0;
    for (id item in (NSArray *)items) {
        if (!JLTidalIsDictionary(item)) continue;
        if (JLTidalItemHasType(item, @"FOLDER")) folderItems++;
        else if (JLTidalItemHasType(item, @"PLAYLIST")) playlistItems++;
    }
    NSInteger malformed = (folderItems - (NSInteger)folders.count) +
                          (playlistItems - (NSInteger)uuids.count);

    // A number cursor is still a cursor; NSNull, "" and absence end the list.
    id rawCursor = ((NSDictionary *)json)[@"cursor"];
    NSString *cursor = nil;
    if (JLTidalIsString(rawCursor)) {
        cursor = rawCursor;
    } else if ([rawCursor isKindOfClass:[NSNumber class]]) {
        cursor = [rawCursor stringValue];
    }
    if (cursor.length == 0) cursor = nil;

    return [[JLTidalFolderListing alloc] initWithFolders:folders
                                           playlistUUIDs:uuids
                                                  cursor:cursor
                                      malformedItemCount:malformed];
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
