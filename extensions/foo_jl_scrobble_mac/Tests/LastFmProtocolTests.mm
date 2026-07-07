//
//  LastFmProtocolTests.mm
//  foo_jl_scrobble_mac
//
//  Unit tests for LastFmRequestBuilder (signing, encoding, param
//  assembly), LastFmResponseParser (per-endpoint JSON parsing), and
//  ScrobblePolicy (error action + backoff). Compiled standalone
//  (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/LastFm/LastFmRequestBuilder.h"
#import "../src/LastFm/LastFmResponseParser.h"
#import "../src/Services/ScrobblePolicy.h"
#import "../src/Core/ScrobbleTrack.h"
#import "../src/Core/TopAlbum.h"

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

static ScrobbleTrack *makeTrack(void) {
    ScrobbleTrack *t = [[ScrobbleTrack alloc] initWithArtist:@"Cher & Co" title:@"Believe" duration:222];
    t.timestamp = 1751000000;
    return t;
}

int main(void) {
    @autoreleasepool {

    // --- Signature: golden vector (precomputed MD5) ---
    {
        g_context = "signature-golden";
        NSDictionary *params = @{
            @"method": @"track.scrobble",
            @"api_key": @"KEY123",
            @"sk": @"SESSION",
            @"artist": @"Cher & Co",
            @"track": @"Believe",
            @"get-token[0]": @"v=1",
            @"format": @"json",        // excluded from signature
            @"callback": @"cb",        // excluded from signature
        };
        // Base string: api_keyKEY123artistCher & Coget-token[0]v=1
        //              methodtrack.scrobbleskSESSIONtrackBelievemysecret
        NSString *sig = [LastFmRequestBuilder signatureForParameters:params secret:@"mysecret"];
        CHECK_EQSTR(sig, @"1fb3586c1796e18e4d7ffb4dad934442", "matches precomputed MD5");

        NSMutableDictionary *without = [params mutableCopy];
        [without removeObjectsForKeys:@[@"format", @"callback"]];
        CHECK_EQSTR([LastFmRequestBuilder signatureForParameters:without secret:@"mysecret"],
                    sig, "format/callback do not affect the signature");

        CHECK(![sig isEqualToString:[LastFmRequestBuilder signatureForParameters:params
                                                                          secret:@"othersecret"]],
              "secret changes the signature");
    }

    // --- urlEncode: escapes the form-body specials beyond query-allowed ---
    {
        g_context = "urlEncode";
        CHECK_EQSTR([LastFmRequestBuilder urlEncode:@"a&b=c+d#e"], @"a%26b%3Dc%2Bd%23e",
                    "& = + # all escaped");
        CHECK_EQSTR([LastFmRequestBuilder urlEncode:@"hello world"], @"hello%20world",
                    "space escaped");
        CHECK_EQSTR([LastFmRequestBuilder urlEncode:@"plain"], @"plain", "plain passes through");
    }

    // --- postBody: key=value pairs joined by & (verify as a set) ---
    {
        g_context = "postBody";
        NSString *body = [LastFmRequestBuilder postBodyFromParameters:@{
            @"artist": @"AC/DC",
            @"track": @"Back In Black",
        }];
        NSSet *pairs = [NSSet setWithArray:[body componentsSeparatedByString:@"&"]];
        NSSet *expected = [NSSet setWithArray:@[@"artist=AC/DC", @"track=Back%20In%20Black"]];
        CHECK([pairs isEqualToSet:expected], "encoded pairs present");
    }

    // --- Now-playing params: optional fields only when set ---
    {
        g_context = "nowPlayingParams";
        ScrobbleTrack *t = makeTrack();
        t.album = @"Believe";
        t.trackNumber = 0;  // omitted
        NSDictionary *p = [LastFmRequestBuilder nowPlayingParamsForTrack:t sessionKey:@"SK"];
        CHECK_EQSTR(p[@"method"], @"track.updateNowPlaying", "method");
        CHECK_EQSTR(p[@"sk"], @"SK", "session key");
        CHECK_EQSTR(p[@"artist"], @"Cher & Co", "artist");
        CHECK_EQSTR(p[@"track"], @"Believe", "track");
        CHECK_EQSTR(p[@"album"], @"Believe", "album included");
        CHECK_EQSTR(p[@"duration"], @"222", "duration included");
        CHECK(p[@"trackNumber"] == nil, "zero trackNumber omitted");
        CHECK(p[@"timestamp"] == nil, "now-playing has no timestamp");
    }

    // --- Scrobble batch params: indexed keys ---
    {
        g_context = "scrobbleParams";
        ScrobbleTrack *a = makeTrack();
        ScrobbleTrack *b = [[ScrobbleTrack alloc] initWithArtist:@"B" title:@"Two" duration:100];
        b.timestamp = 1751000500;
        b.albumArtist = @"Various";
        NSDictionary *p = [LastFmRequestBuilder scrobbleParamsForTracks:@[a, b] sessionKey:@"SK"];
        CHECK_EQSTR(p[@"method"], @"track.scrobble", "method");
        CHECK_EQSTR(p[@"artist[0]"], @"Cher & Co", "artist[0]");
        CHECK_EQSTR(p[@"timestamp[0]"], @"1751000000", "timestamp[0]");
        CHECK_EQSTR(p[@"artist[1]"], @"B", "artist[1]");
        CHECK_EQSTR(p[@"track[1]"], @"Two", "track[1]");
        CHECK_EQSTR(p[@"timestamp[1]"], @"1751000500", "timestamp[1]");
        CHECK_EQSTR(p[@"albumArtist[1]"], @"Various", "albumArtist[1]");
        CHECK(p[@"album[1]"] == nil, "missing album omitted");
        CHECK(p[@"artist[2]"] == nil, "no phantom third track");
    }

    // --- Scrobble response: accepted/ignored, malformed shapes ---
    {
        g_context = "scrobbleResponse";
        NSInteger accepted = -1, ignored = -1;
        [LastFmResponseParser scrobbleResponse:@{
            @"scrobbles": @{@"@attr": @{@"accepted": @"48", @"ignored": @"2"}}
        } accepted:&accepted ignored:&ignored];
        CHECK(accepted == 48 && ignored == 2, "string counts parsed");

        [LastFmResponseParser scrobbleResponse:@{@"scrobbles": @"nope"}
                                      accepted:&accepted ignored:&ignored];
        CHECK(accepted == 0 && ignored == 0, "malformed shape yields zeros");
    }

    // --- Token / now-playing confirmation ---
    {
        g_context = "token-nowplaying";
        CHECK_EQSTR([LastFmResponseParser tokenFromResponse:@{@"token": @"abc"}], @"abc", "token");
        CHECK([LastFmResponseParser tokenFromResponse:@{@"token": @""}] == nil, "empty token nil");
        CHECK([LastFmResponseParser tokenFromResponse:@{}] == nil, "missing token nil");
        CHECK([LastFmResponseParser nowPlayingConfirmedInResponse:@{@"nowplaying": @{}}],
              "nowplaying present");
        CHECK(![LastFmResponseParser nowPlayingConfirmedInResponse:@{}], "nowplaying absent");
    }

    // --- User info: name + image size preference ---
    {
        g_context = "userInfo";
        NSDictionary *resp = @{@"user": @{
            @"name": @"jenda",
            @"image": @[
                @{@"size": @"large", @"#text": @"https://img/l.png"},
                @{@"size": @"extralarge", @"#text": @"https://img/xl.png"},
            ],
        }};
        CHECK_EQSTR([LastFmResponseParser usernameFromUserInfoResponse:resp], @"jenda", "name");
        CHECK_EQSTR([LastFmResponseParser userImageURLFromUserInfoResponse:resp].absoluteString,
                    @"https://img/xl.png", "prefers extralarge");

        NSDictionary *largeOnly = @{@"user": @{
            @"image": @[@{@"size": @"large", @"#text": @"https://img/l.png"}],
        }};
        CHECK_EQSTR([LastFmResponseParser userImageURLFromUserInfoResponse:largeOnly].absoluteString,
                    @"https://img/l.png", "falls back to large");
        CHECK([LastFmResponseParser usernameFromUserInfoResponse:@{}] == nil, "missing user");
    }

    // --- Recent tracks: array vs single-object normalization ---
    {
        g_context = "recentTracks";
        NSDictionary *multi = @{@"recenttracks": @{
            @"track": @[@{@"name": @"One"}, @{@"name": @"Two"}],
            @"@attr": @{@"totalPages": @"7", @"total": @"1234"},
        }};
        CHECK([LastFmResponseParser recentTrackDictsFromResponse:multi].count == 2, "array kept");
        CHECK([LastFmResponseParser totalPagesFromRecentTracksResponse:multi] == 7, "totalPages");
        CHECK([LastFmResponseParser totalFromRecentTracksResponse:multi] == 1234, "total");

        NSDictionary *single = @{@"recenttracks": @{@"track": @{@"name": @"Solo"}}};
        NSArray *tracks = [LastFmResponseParser recentTrackDictsFromResponse:single];
        CHECK(tracks.count == 1, "single object normalized to array");
        CHECK_EQSTR(tracks[0][@"name"], @"Solo", "single track content");

        CHECK([LastFmResponseParser recentTrackDictsFromResponse:@{}].count == 0, "missing root");
        CHECK([LastFmResponseParser totalPagesFromRecentTracksResponse:@{}] == 0, "no pages");
    }

    // --- Now-playing filter for day checks ---
    {
        g_context = "actualScrobbles";
        NSArray *onlyNowPlaying = @[@{@"name": @"X", @"@attr": @{@"nowplaying": @"true"}}];
        CHECK(![LastFmResponseParser containsActualScrobbles:onlyNowPlaying],
              "now-playing alone is not a scrobble");
        NSArray *mixed = @[
            @{@"name": @"X", @"@attr": @{@"nowplaying": @"true"}},
            @{@"name": @"Y", @"date": @{@"uts": @"1751000000"}},
        ];
        CHECK([LastFmResponseParser containsActualScrobbles:mixed], "real scrobble detected");
        CHECK(![LastFmResponseParser containsActualScrobbles:@[]], "empty day");
    }

    // --- Top items: albums vs artists ---
    {
        g_context = "topItems";
        NSDictionary *resp = @{@"topartists": @{@"artist": @[
            @{@"name": @"Radiohead", @"playcount": @"99"},
        ]}};
        NSArray<TopAlbum *> *artists = [LastFmResponseParser topItemsFromResponse:resp
                                                                          rootKey:@"topartists"
                                                                          itemKey:@"artist"
                                                                        asArtists:YES];
        CHECK(artists.count == 1, "artist parsed");
        CHECK_EQSTR(artists[0].artist, @"Radiohead", "artist name mirrored into artist field");

        CHECK([LastFmResponseParser topItemsFromResponse:resp
                                                 rootKey:@"topalbums"
                                                 itemKey:@"album"
                                               asArtists:NO].count == 0, "wrong root -> empty");
    }

    // --- Album / track info ---
    {
        g_context = "albumTrackInfo";
        NSDictionary *albumResp = @{@"album": @{
            @"image": @[@{@"size": @"large", @"#text": @"https://img/cover.png"}],
        }};
        CHECK_EQSTR([LastFmResponseParser albumImageURLFromAlbumInfoResponse:albumResp].absoluteString,
                    @"https://img/cover.png", "album cover");

        NSString *albumName = @"sentinel";
        NSURL *imageURL = nil;
        [LastFmResponseParser trackInfoFromResponse:@{@"track": @{
            @"album": @{@"title": @"OK Computer",
                        @"image": @[@{@"size": @"medium", @"#text": @"https://img/m.png"}]},
        }} albumName:&albumName imageURL:&imageURL];
        CHECK_EQSTR(albumName, @"OK Computer", "track's album title");
        CHECK_EQSTR(imageURL.absoluteString, @"https://img/m.png", "track's album image");

        [LastFmResponseParser trackInfoFromResponse:@{} albumName:&albumName imageURL:&imageURL];
        CHECK(albumName == nil && imageURL == nil, "missing track info yields nils");
    }

    // --- ScrobblePolicy: error code -> action ---
    {
        g_context = "policy-actions";
        CHECK(ScrobbleActionForErrorCode(LastFmErrorInvalidSessionKey) == ScrobbleErrorActionReauth,
              "invalid session -> reauth");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorAuthenticationFailed) == ScrobbleErrorActionReauth,
              "auth failed -> reauth");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorTokenExpired) == ScrobbleErrorActionReauth,
              "token expired -> reauth");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorSuspendedApiKey) == ScrobbleErrorActionSuspend,
              "suspended key -> suspend");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorInvalidApiKey) == ScrobbleErrorActionSuspend,
              "invalid key -> suspend");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorServiceOffline) == ScrobbleErrorActionRetry,
              "offline -> retry");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorRateLimitExceeded) == ScrobbleErrorActionRetry,
              "rate limit -> retry");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorOperationFailed) == ScrobbleErrorActionRetry,
              "operation failed -> retry");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorServiceUnavailable) == ScrobbleErrorActionRetry,
              "unavailable -> retry");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorInvalidParameters) == ScrobbleErrorActionDrop,
              "bad params -> drop");
        CHECK(ScrobbleActionForErrorCode(LastFmErrorInvalidMethod) == ScrobbleErrorActionDrop,
              "bad method -> drop");
    }

    // --- ScrobblePolicy: backoff doubles, capped at 5 minutes ---
    {
        g_context = "policy-backoff";
        NSTimeInterval b = kScrobbleInitialBackoff;
        CHECK(b == 5.0, "initial 5s");
        b = ScrobbleNextBackoff(b);
        CHECK(b == 10.0, "5 -> 10");
        b = ScrobbleNextBackoff(b);
        CHECK(b == 20.0, "10 -> 20");
        for (int i = 0; i < 10; i++) b = ScrobbleNextBackoff(b);
        CHECK(b == 300.0, "capped at 300s");
        CHECK(ScrobbleNextBackoff(300.0) == 300.0, "stays at cap");
    }

    }  // autoreleasepool

    printf("LastFmProtocolTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
