//
//  RecentTrack.mm
//  foo_jl_scrobble_mac
//
//  Data model for Last.fm recent track (user.getRecentTracks)
//

#import "RecentTrack.h"
#import "ScrobbleTrack.h"
#import "TopAlbum.h"

@implementation RecentTrack

+ (nullable instancetype)trackFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;

    NSString *name = dict[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return nil;

    RecentTrack *track = [[RecentTrack alloc] init];
    track.name = name;

    // Recent tracks uses {"artist": {"#text": "...", "mbid": "..."}} format
    id artistObj = dict[@"artist"];
    if ([artistObj isKindOfClass:[NSDictionary class]]) {
        track.artist = artistObj[@"#text"] ?: @"";
    } else if ([artistObj isKindOfClass:[NSString class]]) {
        track.artist = artistObj;
    } else {
        track.artist = @"";
    }

    // Album name
    id albumObj = dict[@"album"];
    if ([albumObj isKindOfClass:[NSDictionary class]]) {
        track.albumName = albumObj[@"#text"];
    } else if ([albumObj isKindOfClass:[NSString class]]) {
        track.albumName = albumObj;
    }

    // Image URL - reuse TopAlbum's fallback chain
    NSArray *images = dict[@"image"];
    if ([images isKindOfClass:[NSArray class]]) {
        track.imageURL = [TopAlbum bestImageURLFromArray:images];
    }

    // Last.fm URL
    NSString *urlStr = dict[@"url"];
    if ([urlStr isKindOfClass:[NSString class]] && urlStr.length > 0) {
        track.lastfmURL = [NSURL URLWithString:urlStr];
    }

    // Now playing flag
    NSDictionary *attr = dict[@"@attr"];
    if ([attr isKindOfClass:[NSDictionary class]] && attr[@"nowplaying"]) {
        track.isNowPlaying = YES;
        track.scrobbleDate = nil;
    } else {
        // Scrobble date from UTS timestamp
        NSDictionary *dateDict = dict[@"date"];
        if ([dateDict isKindOfClass:[NSDictionary class]]) {
            NSString *uts = dateDict[@"uts"];
            if ([uts isKindOfClass:[NSString class]]) {
                NSTimeInterval ts = [uts doubleValue];
                if (ts > 0) {
                    track.scrobbleDate = [NSDate dateWithTimeIntervalSince1970:ts];
                }
            }
        }
    }

    return track;
}

+ (instancetype)trackFromScrobbleTrack:(ScrobbleTrack *)scrobbleTrack {
    RecentTrack *track = [[RecentTrack alloc] init];
    track.name = scrobbleTrack.title;
    track.artist = scrobbleTrack.artist;
    track.albumName = scrobbleTrack.album;
    track.isNowPlaying = YES;
    track.scrobbleDate = nil;
    // No imageURL available from local metadata -- placeholder shown until API refresh
    return track;
}

- (NSString *)relativeTimeString {
    return [self relativeTimeStringAtDate:[NSDate date]];
}

- (NSString *)relativeTimeStringAtDate:(NSDate *)now {
    if (self.isNowPlaying || !self.scrobbleDate) {
        return @"Now Playing";
    }

    NSTimeInterval elapsed = [now timeIntervalSinceDate:self.scrobbleDate];
    if (elapsed < 60) {
        return @"now";
    } else if (elapsed < 3600) {
        NSInteger minutes = (NSInteger)(elapsed / 60);
        return [NSString stringWithFormat:@"%ldm ago", (long)minutes];
    } else if (elapsed < 86400) {
        NSInteger hours = (NSInteger)(elapsed / 3600);
        return [NSString stringWithFormat:@"%ldh ago", (long)hours];
    } else {
        NSInteger days = (NSInteger)(elapsed / 86400);
        return [NSString stringWithFormat:@"%ldd ago", (long)days];
    }
}

@end
