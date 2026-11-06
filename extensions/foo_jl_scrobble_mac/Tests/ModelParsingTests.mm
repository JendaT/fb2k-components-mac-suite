//
//  ModelParsingTests.mm
//  foo_jl_scrobble_mac
//
//  Unit tests for RecentTrack / TopAlbum Last.fm JSON parsing and
//  ScrobbleTrack validation. Compiled standalone (Foundation only);
//  gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/RecentTrack.h"
#import "../src/Core/TopAlbum.h"
#import "../src/Core/ScrobbleTrack.h"

#include <string>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what)                                                        \
    do {                                                                         \
        g_checks++;                                                             \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            printf("FAIL [%s] %s\n", g_context.c_str(), what);                  \
        }                                                                       \
    } while (0)

#define CHECK_EQSTR(got, want, what)                                             \
    do {                                                                         \
        g_checks++;                                                             \
        NSString *_g = (got);                                                   \
        NSString *_w = (want);                                                  \
        if (!((_g == nil && _w == nil) || [_g isEqualToString:_w])) {           \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got '%s', expected '%s'\n", g_context.c_str(),\
                   what, _g.UTF8String ?: "(nil)", _w.UTF8String ?: "(nil)");   \
        }                                                                       \
    } while (0)

int main(void) {
    @autoreleasepool {

    // --- RecentTrack: artist as {#text} object (user.getRecentTracks shape) ---
    {
        g_context = "RecentTrack-artist-object";
        RecentTrack *t = [RecentTrack trackFromDictionary:@{
            @"name": @"Karma Police",
            @"artist": @{@"#text": @"Radiohead", @"mbid": @"x"},
            @"album": @{@"#text": @"OK Computer"},
            @"url": @"https://www.last.fm/music/Radiohead/_/Karma+Police",
            @"date": @{@"uts": @"1751000000", @"#text": @"whenever"},
        }];
        CHECK(t != nil, "parses");
        CHECK_EQSTR(t.name, @"Karma Police", "name");
        CHECK_EQSTR(t.artist, @"Radiohead", "artist from #text");
        CHECK_EQSTR(t.albumName, @"OK Computer", "album from #text");
        CHECK(t.lastfmURL != nil, "url parsed");
        CHECK(!t.isNowPlaying, "not now-playing");
        CHECK(t.scrobbleDate != nil, "date parsed");
        CHECK([t.scrobbleDate timeIntervalSince1970] == 1751000000, "uts value");
    }

    // --- RecentTrack: artist as plain string, no album/date ---
    {
        g_context = "RecentTrack-artist-string";
        RecentTrack *t = [RecentTrack trackFromDictionary:@{
            @"name": @"Song",
            @"artist": @"Some Artist",
        }];
        CHECK(t != nil, "parses");
        CHECK_EQSTR(t.artist, @"Some Artist", "artist as string");
        CHECK(t.albumName == nil, "no album");
        CHECK(t.scrobbleDate == nil, "no date");
    }

    // --- RecentTrack: now-playing @attr wins over date ---
    {
        g_context = "RecentTrack-nowplaying";
        RecentTrack *t = [RecentTrack trackFromDictionary:@{
            @"name": @"Live One",
            @"artist": @{@"#text": @"Band"},
            @"@attr": @{@"nowplaying": @"true"},
            @"date": @{@"uts": @"1751000000"},
        }];
        CHECK(t.isNowPlaying, "now-playing flag");
        CHECK(t.scrobbleDate == nil, "date cleared when now-playing");
    }

    // --- RecentTrack: rejects malformed input ---
    {
        g_context = "RecentTrack-malformed";
        CHECK([RecentTrack trackFromDictionary:@{}] == nil, "empty dict rejected");
        CHECK([RecentTrack trackFromDictionary:@{@"name": @""}] == nil, "empty name rejected");
        CHECK([RecentTrack trackFromDictionary:@{@"name": @123}] == nil, "non-string name rejected");
        RecentTrack *t = [RecentTrack trackFromDictionary:@{@"name": @"X", @"artist": @42}];
        CHECK_EQSTR(t.artist, @"", "numeric artist becomes empty string");
    }

    // --- RecentTrack.relativeTimeStringAtDate: bucket boundaries ---
    {
        g_context = "relativeTimeString";
        NSDate *now = [NSDate dateWithTimeIntervalSince1970:2000000000];
        RecentTrack *t = [RecentTrack trackFromDictionary:@{@"name": @"X", @"artist": @"A"}];

        t.scrobbleDate = [now dateByAddingTimeInterval:-30];
        CHECK_EQSTR([t relativeTimeStringAtDate:now], @"now", "under 60s -> now");
        t.scrobbleDate = [now dateByAddingTimeInterval:-60];
        CHECK_EQSTR([t relativeTimeStringAtDate:now], @"1m ago", "exactly 60s");
        t.scrobbleDate = [now dateByAddingTimeInterval:-3599];
        CHECK_EQSTR([t relativeTimeStringAtDate:now], @"59m ago", "just under 1h");
        t.scrobbleDate = [now dateByAddingTimeInterval:-3600];
        CHECK_EQSTR([t relativeTimeStringAtDate:now], @"1h ago", "exactly 1h");
        t.scrobbleDate = [now dateByAddingTimeInterval:-86399];
        CHECK_EQSTR([t relativeTimeStringAtDate:now], @"23h ago", "just under 1d");
        t.scrobbleDate = [now dateByAddingTimeInterval:-86400];
        CHECK_EQSTR([t relativeTimeStringAtDate:now], @"1d ago", "exactly 1d");
        t.scrobbleDate = [now dateByAddingTimeInterval:-86400 * 10];
        CHECK_EQSTR([t relativeTimeStringAtDate:now], @"10d ago", "10 days");

        t.isNowPlaying = YES;
        CHECK_EQSTR([t relativeTimeStringAtDate:now], @"Now Playing", "now-playing text");
        t.isNowPlaying = NO;
        t.scrobbleDate = nil;
        CHECK_EQSTR([t relativeTimeStringAtDate:now], @"Now Playing", "nil date treated as now-playing");
    }

    // --- TopAlbum: full album dict (user.getTopAlbums shape) ---
    {
        g_context = "TopAlbum-full";
        TopAlbum *a = [TopAlbum albumFromDictionary:@{
            @"name": @"In Rainbows",
            @"artist": @{@"name": @"Radiohead"},
            @"playcount": @"137",
            @"@attr": @{@"rank": @"2"},
            @"url": @"https://www.last.fm/music/Radiohead/In+Rainbows",
            @"mbid": @"abc-123",
            @"image": @[
                @{@"size": @"small", @"#text": @"https://img/s.png"},
                @{@"size": @"extralarge", @"#text": @"https://img/xl.png"},
            ],
        }];
        CHECK(a != nil, "parses");
        CHECK_EQSTR(a.artist, @"Radiohead", "artist from object name");
        CHECK(a.playcount == 137, "playcount string coerced");
        CHECK(a.rank == 2, "rank from @attr string");
        CHECK_EQSTR(a.mbid, @"abc-123", "mbid");
        CHECK_EQSTR(a.imageURL.absoluteString, @"https://img/xl.png", "prefers extralarge");
    }

    // --- TopAlbum: numeric playcount/rank, artist as string ---
    {
        g_context = "TopAlbum-variants";
        TopAlbum *a = [TopAlbum albumFromDictionary:@{
            @"name": @"Album",
            @"artist": @"Artist",
            @"playcount": @42,
            @"@attr": @{@"rank": @7},
            @"album": @{@"#text": @"Parent Album"},
        }];
        CHECK_EQSTR(a.artist, @"Artist", "artist as string");
        CHECK(a.playcount == 42, "numeric playcount");
        CHECK(a.rank == 7, "numeric rank");
        CHECK_EQSTR(a.albumName, @"Parent Album", "track's parent album from #text");
        CHECK([TopAlbum albumFromDictionary:@{@"artist": @"A"}] == nil, "missing name rejected");
    }

    // --- TopAlbum.bestImageURLFromArray: fallback chain + placeholder ---
    {
        g_context = "bestImageURL";
        NSURL *u = [TopAlbum bestImageURLFromArray:@[
            @{@"size": @"small", @"#text": @"https://img/s.png"},
            @{@"size": @"medium", @"#text": @"https://img/m.png"},
        ]];
        CHECK_EQSTR(u.absoluteString, @"https://img/m.png", "falls back to medium");

        u = [TopAlbum bestImageURLFromArray:@[
            @{@"size": @"extralarge", @"#text": @""},
            @{@"size": @"large", @"#text": @"https://img/l.png"},
        ]];
        CHECK_EQSTR(u.absoluteString, @"https://img/l.png", "empty extralarge skipped entirely");

        u = [TopAlbum bestImageURLFromArray:@[
            @{@"size": @"extralarge",
              @"#text": @"https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png"},
        ]];
        CHECK(u == nil, "deprecated placeholder hash rejected");

        CHECK([TopAlbum bestImageURLFromArray:@[]] == nil, "empty array");
        CHECK([TopAlbum bestImageURLFromArray:(NSArray *)@"nope"] == nil, "non-array input");
    }

    // --- ScrobbleTrack.isValid: field/duration/timestamp validation ---
    {
        g_context = "ScrobbleTrack-isValid";
        ScrobbleTrack *t = [[ScrobbleTrack alloc] initWithArtist:@"A" title:@"T" duration:180];
        CHECK([t isValid], "well-formed track valid");

        t = [[ScrobbleTrack alloc] initWithArtist:@"" title:@"T" duration:180];
        CHECK(![t isValid], "empty artist invalid");
        t = [[ScrobbleTrack alloc] initWithArtist:@"A" title:@"T" duration:29];
        CHECK(![t isValid], "29s too short");
        t = [[ScrobbleTrack alloc] initWithArtist:@"A" title:@"T" duration:180];
        t.timestamp = 100;  // 1970 — before Last.fm existed
        CHECK(![t isValid], "pre-epoch timestamp invalid");

        t = [[ScrobbleTrack alloc] initWithArtist:@"A" title:@"T" duration:180];
        t.timestamp = 1751000000;
        CHECK_EQSTR([t deduplicationKey], @"A|T|1751000000", "dedup key format");
    }

    // --- ScrobbleTrack: NSSecureCoding round-trip ---
    {
        g_context = "ScrobbleTrack-coding";
        ScrobbleTrack *t = [[ScrobbleTrack alloc] initWithArtist:@"A" title:@"T" duration:180];
        t.album = @"Al";
        t.trackNumber = 3;
        t.status = ScrobbleTrackStatusFailed;
        t.retryCount = 2;

        NSError *err = nil;
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:t
                                             requiringSecureCoding:YES
                                                             error:&err];
        CHECK(data != nil && err == nil, "archives");
        ScrobbleTrack *r = [NSKeyedUnarchiver unarchivedObjectOfClass:[ScrobbleTrack class]
                                                             fromData:data
                                                                error:&err];
        CHECK(r != nil && err == nil, "unarchives");
        CHECK_EQSTR(r.artist, @"A", "artist round-trips");
        CHECK_EQSTR(r.album, @"Al", "album round-trips");
        CHECK(r.trackNumber == 3, "trackNumber round-trips");
        CHECK(r.status == ScrobbleTrackStatusFailed, "status round-trips");
        CHECK(r.retryCount == 2, "retryCount round-trips");
        CHECK(r.timestamp == t.timestamp, "timestamp round-trips");
        CHECK_EQSTR(r.submissionId, t.submissionId, "submissionId round-trips");
    }

    }  // autoreleasepool

    printf("ModelParsingTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
