//
//  LastFmRequestBuilder.mm
//  foo_jl_scrobble_mac
//
//  Pure request construction for the Last.fm API
//

#import "LastFmRequestBuilder.h"
#import "../Core/MD5.h"
#import "../Core/ScrobbleTrack.h"

@implementation LastFmRequestBuilder

+ (NSString *)signatureForParameters:(NSDictionary<NSString *, NSString *> *)params
                              secret:(NSString *)secret {
    // Sort keys alphabetically, excluding "format" and "callback"
    NSMutableArray *sortedKeys = [[params.allKeys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    [sortedKeys removeObject:@"format"];
    [sortedKeys removeObject:@"callback"];

    // Build signature base: key1value1key2value2...secret
    NSMutableString *signatureBase = [NSMutableString string];
    for (NSString *key in sortedKeys) {
        [signatureBase appendString:key];
        [signatureBase appendString:params[key]];
    }
    [signatureBase appendString:secret];

    return MD5Hash(signatureBase);
}

+ (NSString *)urlEncode:(NSString *)string {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
        [set removeCharactersInString:@"&=+#"];
        allowed = [set copy];
    });
    return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

+ (NSString *)postBodyFromParameters:(NSDictionary<NSString *, NSString *> *)params {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *key in params) {
        NSString *encodedKey = [self urlEncode:key];
        NSString *encodedValue = [self urlEncode:params[key]];
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", encodedKey, encodedValue]];
    }
    return [pairs componentsJoinedByString:@"&"];
}

+ (NSDictionary<NSString *, NSString *> *)nowPlayingParamsForTrack:(ScrobbleTrack *)track
                                                        sessionKey:(NSString *)sessionKey {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"method"] = @"track.updateNowPlaying";
    params[@"sk"] = sessionKey;
    params[@"artist"] = track.artist;
    params[@"track"] = track.title;

    if (track.album.length > 0) {
        params[@"album"] = track.album;
    }
    if (track.albumArtist.length > 0) {
        params[@"albumArtist"] = track.albumArtist;
    }
    if (track.duration > 0) {
        params[@"duration"] = [NSString stringWithFormat:@"%ld", (long)track.duration];
    }
    if (track.trackNumber > 0) {
        params[@"trackNumber"] = [NSString stringWithFormat:@"%ld", (long)track.trackNumber];
    }
    return params;
}

+ (NSDictionary<NSString *, NSString *> *)scrobbleParamsForTracks:(NSArray<ScrobbleTrack *> *)tracks
                                                       sessionKey:(NSString *)sessionKey {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"method"] = @"track.scrobble";
    params[@"sk"] = sessionKey;

    for (NSUInteger i = 0; i < tracks.count; i++) {
        ScrobbleTrack *track = tracks[i];
        NSString *suffix = [NSString stringWithFormat:@"[%lu]", (unsigned long)i];

        params[[@"artist" stringByAppendingString:suffix]] = track.artist;
        params[[@"track" stringByAppendingString:suffix]] = track.title;
        params[[@"timestamp" stringByAppendingString:suffix]] =
            [NSString stringWithFormat:@"%lld", track.timestamp];

        if (track.album.length > 0) {
            params[[@"album" stringByAppendingString:suffix]] = track.album;
        }
        if (track.albumArtist.length > 0) {
            params[[@"albumArtist" stringByAppendingString:suffix]] = track.albumArtist;
        }
        if (track.duration > 0) {
            params[[@"duration" stringByAppendingString:suffix]] =
                [NSString stringWithFormat:@"%ld", (long)track.duration];
        }
        if (track.trackNumber > 0) {
            params[[@"trackNumber" stringByAppendingString:suffix]] =
                [NSString stringWithFormat:@"%ld", (long)track.trackNumber];
        }
    }
    return params;
}

@end
