//
//  GalleryFetchStateTests.mm
//  foo_jl_biography_mac
//
//  Unit tests for GalleryFetchState (multi-source accumulation, completion
//  once-guard, all-failed detection, fallback decision). Includes a concurrent
//  sweep proving tryComplete wins exactly once under contention.
//  Gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/GalleryFetchState.h"
#import "../src/Core/ArtistGalleryData.h"
#import "../src/Core/ArtistImage.h"

#include <string>
#include <atomic>
#include <memory>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what) do { \
    g_checks++; \
    if (!(cond)) { \
        g_failures++; \
        printf("FAIL [%s] %s\n", g_context.c_str(), what); \
    } \
} while (0)

static ArtistImage *makeImage(NSString *url, BiographySource source) {
    return [[ArtistImage alloc] initWithURL:[NSURL URLWithString:url]
                               thumbnailURL:nil
                                  imageType:ArtistImageTypeThumbnail
                                     source:source
                                      likes:0];
}

static NSError *makeError(NSInteger code) {
    return [NSError errorWithDomain:@"test" code:code userInfo:nil];
}

// Matches kLastFmPlaceholderHash in BiographyAPIConstants.h
static NSString * const kPlaceholderURL =
    @"https://lastfm.freetls.fastly.net/i/u/2a96cbd8b46e442fc41c2b86b821562f.png";

static void testAccumulationAndDedup() {
    g_context = "accumulation";

    GalleryFetchState *state = [[GalleryFetchState alloc] initWithArtistName:@"Muse" mbid:@"m-1"];
    [state recordImages:@[makeImage(@"http://x/1.jpg", BiographySourceFanartTv)]
                  error:nil fromSource:BiographySourceFanartTv];
    [state recordImages:@[makeImage(@"http://x/1.jpg", BiographySourceAudioDb),
                          makeImage(@"http://x/2.jpg", BiographySourceAudioDb)]
                  error:nil fromSource:BiographySourceAudioDb];

    CHECK(state.imageCount == 2, "duplicate URL across sources deduped");
    CHECK(state.allSourcesFailed == NO, "successful sources are not failures");
    CHECK(state.firstError == nil, "no error recorded");

    ArtistGalleryData *data = [state buildGalleryDataWithFallbackURL:nil];
    CHECK(data.imageCount == 2, "built data has deduped images");
    CHECK([data.artistName isEqualToString:@"Muse"], "artist name carried");
    CHECK([data.mbid isEqualToString:@"m-1"], "mbid carried");
}

static void testCompletionOnceGuard() {
    g_context = "tryComplete";

    GalleryFetchState *state = [[GalleryFetchState alloc] initWithArtistName:@"Muse" mbid:nil];
    CHECK(state.isCompleted == NO, "starts incomplete");
    CHECK([state tryComplete], "first completer wins");
    CHECK([state tryComplete] == NO, "second completer loses");
    CHECK(state.isCompleted, "completed after first win");

    // Late results (source finishing after timeout fired) are ignored
    [state recordImages:@[makeImage(@"http://late/1.jpg", BiographySourceDeezer)]
                  error:nil fromSource:BiographySourceDeezer];
    CHECK(state.imageCount == 0, "record after completion ignored");
}

static void testConcurrentCompletion() {
    g_context = "concurrent tryComplete";

    // The exact race the coordinator has: timeout on one queue vs
    // group-notify on another. Exactly one caller may finish.
    for (int iter = 0; iter < 50; iter++) {
        GalleryFetchState *state = [[GalleryFetchState alloc] initWithArtistName:@"R" mbid:nil];
        auto wins = std::make_shared<std::atomic<int>>(0);
        dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
            [state recordImages:@[makeImage([NSString stringWithFormat:@"http://c/%zu.jpg", i],
                                            BiographySourceDeezer)]
                          error:nil fromSource:BiographySourceDeezer];
            if ([state tryComplete]) {
                wins->fetch_add(1);
            }
        });
        g_checks++;
        if (wins->load() != 1) {
            g_failures++;
            printf("FAIL [%s] iter %d: %d winners (want exactly 1)\n",
                   g_context.c_str(), iter, wins->load());
        }
    }
}

static void testAllSourcesFailed() {
    g_context = "allSourcesFailed";

    // All reporting sources error, no images -> failed
    GalleryFetchState *state = [[GalleryFetchState alloc] initWithArtistName:@"X" mbid:nil];
    [state recordImages:nil error:makeError(1) fromSource:BiographySourceAudioDb];
    [state recordImages:nil error:makeError(2) fromSource:BiographySourceDeezer];
    CHECK(state.allSourcesFailed, "two errors, zero images");
    CHECK(state.firstError.code == 1, "first error preserved in order");

    // A skipped source (FanartTV without MBID) does not make it a failure by itself
    state = [[GalleryFetchState alloc] initWithArtistName:@"X" mbid:nil];
    [state recordSkippedSource:BiographySourceFanartTv];
    CHECK(state.allSourcesFailed == NO, "only skips, nothing reported");

    // One source succeeds with images -> not all failed
    state = [[GalleryFetchState alloc] initWithArtistName:@"X" mbid:nil];
    [state recordImages:nil error:makeError(1) fromSource:BiographySourceAudioDb];
    [state recordImages:@[makeImage(@"http://ok/1.jpg", BiographySourceDeezer)]
                  error:nil fromSource:BiographySourceDeezer];
    CHECK(state.allSourcesFailed == NO, "one success clears the failure state");

    // Errored but images arrived from the same batch (partial) -> not failed
    state = [[GalleryFetchState alloc] initWithArtistName:@"X" mbid:nil];
    [state recordImages:@[makeImage(@"http://p/1.jpg", BiographySourceAudioDb)]
                  error:makeError(3) fromSource:BiographySourceAudioDb];
    CHECK(state.allSourcesFailed == NO, "images collected means not a total failure");
}

static void testFallbackDecision() {
    g_context = "fallback";

    // Empty + real fallback URL -> fallback appended as Last.fm thumbnail
    GalleryFetchState *state = [[GalleryFetchState alloc] initWithArtistName:@"X" mbid:nil];
    ArtistGalleryData *data =
        [state buildGalleryDataWithFallbackURL:[NSURL URLWithString:@"http://lfm/artist.jpg"]];
    CHECK(data.imageCount == 1, "fallback used when empty");
    CHECK(data.images.firstObject.source == BiographySourceLastFm, "fallback source is Last.fm");
    CHECK(data.images.firstObject.imageType == ArtistImageTypeThumbnail, "fallback is a thumbnail");

    // Empty + placeholder fallback -> stays empty
    state = [[GalleryFetchState alloc] initWithArtistName:@"X" mbid:nil];
    data = [state buildGalleryDataWithFallbackURL:[NSURL URLWithString:kPlaceholderURL]];
    CHECK(data.isEmpty, "placeholder fallback skipped");

    // Empty + nil fallback -> stays empty
    state = [[GalleryFetchState alloc] initWithArtistName:@"X" mbid:nil];
    data = [state buildGalleryDataWithFallbackURL:nil];
    CHECK(data.isEmpty, "no fallback available");

    // Non-empty -> fallback never appended
    state = [[GalleryFetchState alloc] initWithArtistName:@"X" mbid:nil];
    [state recordImages:@[makeImage(@"http://api/1.jpg", BiographySourceAudioDb)]
                  error:nil fromSource:BiographySourceAudioDb];
    data = [state buildGalleryDataWithFallbackURL:[NSURL URLWithString:@"http://lfm/artist.jpg"]];
    CHECK(data.imageCount == 1, "fallback not added when API images exist");
    CHECK(data.images.firstObject.source == BiographySourceAudioDb, "API image kept");
}

static void testSortAppliedOnBuild() {
    g_context = "build sorts";

    GalleryFetchState *state = [[GalleryFetchState alloc] initWithArtistName:@"X" mbid:nil];
    [state recordImages:@[makeImage(@"http://d/thumb.jpg", BiographySourceDeezer)]
                  error:nil fromSource:BiographySourceDeezer];
    [state recordImages:@[makeImage(@"http://f/thumb.jpg", BiographySourceFanartTv)]
                  error:nil fromSource:BiographySourceFanartTv];

    ArtistGalleryData *data = [state buildGalleryDataWithFallbackURL:nil];
    CHECK(data.images.firstObject.source == BiographySourceFanartTv,
          "FanartTV sorted before Deezer regardless of arrival order");
}

int main() {
    @autoreleasepool {
        testAccumulationAndDedup();
        testCompletionOnceGuard();
        testConcurrentCompletion();
        testAllSourcesFailed();
        testFallbackDecision();
        testSortAppliedOnBuild();

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
