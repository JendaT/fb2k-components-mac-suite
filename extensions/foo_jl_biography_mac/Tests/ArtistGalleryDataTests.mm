//
//  ArtistGalleryDataTests.mm
//  foo_jl_biography_mac
//
//  Unit tests for ArtistGalleryDataBuilder (URL dedup + preference sort) and
//  ArtistGalleryData filters. Includes a naive-comparator oracle over a
//  deterministic randomized sweep. Gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/ArtistGalleryData.h"
#import "../src/Core/ArtistImage.h"

#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>

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

static ArtistImage *makeImage(NSString *url, ArtistImageType type, BiographySource source, NSInteger likes) {
    return [[ArtistImage alloc] initWithURL:[NSURL URLWithString:url]
                               thumbnailURL:nil
                                  imageType:type
                                     source:source
                                      likes:likes];
}

// Independent naive reference for the preference order:
// FanartTV first, then Background > Thumbnail > Logo > Banner, then likes desc.
static int naiveTypeOrder(ArtistImageType type) {
    switch (type) {
        case ArtistImageTypeBackground: return 0;
        case ArtistImageTypeThumbnail: return 1;
        case ArtistImageTypeLogo: return 2;
        case ArtistImageTypeBanner: return 3;
    }
    return 4;
}

static bool naiveOrderedBefore(ArtistImage *a, ArtistImage *b) {
    int sa = (a.source == BiographySourceFanartTv) ? 0 : 1;
    int sb = (b.source == BiographySourceFanartTv) ? 0 : 1;
    if (sa != sb) return sa < sb;
    int ta = naiveTypeOrder(a.imageType), tb = naiveTypeOrder(b.imageType);
    if (ta != tb) return ta < tb;
    return a.likes > b.likes;
}

static void testDedup() {
    g_context = "dedup";

    ArtistGalleryDataBuilder *builder = [[ArtistGalleryDataBuilder alloc] initWithArtistName:@"Muse"];
    [builder addImages:@[
        makeImage(@"http://x/1.jpg", ArtistImageTypeBackground, BiographySourceFanartTv, 3),
        makeImage(@"http://x/2.jpg", ArtistImageTypeThumbnail, BiographySourceAudioDb, 0),
    ]];
    // Same URL again from another source must be dropped
    [builder addImages:@[
        makeImage(@"http://x/1.jpg", ArtistImageTypeThumbnail, BiographySourceAudioDb, 0),
        makeImage(@"http://x/3.jpg", ArtistImageTypeLogo, BiographySourceDeezer, 0),
    ]];
    CHECK(builder.images.count == 3, "duplicate URL dropped across addImages calls");
    CHECK(builder.images[0].source == BiographySourceFanartTv, "first occurrence wins");

    // setImages resets seen-URLs and dedups within the new array
    builder.images = @[
        makeImage(@"http://y/1.jpg", ArtistImageTypeBackground, BiographySourceAudioDb, 0),
        makeImage(@"http://y/1.jpg", ArtistImageTypeBackground, BiographySourceAudioDb, 0),
        makeImage(@"http://x/1.jpg", ArtistImageTypeBackground, BiographySourceFanartTv, 1),
    ];
    CHECK(builder.images.count == 2, "setImages dedups within input");
    // URL from before the reset must be addable... it IS present in the new set,
    // so adding it again is still a duplicate
    [builder addImages:@[makeImage(@"http://x/1.jpg", ArtistImageTypeLogo, BiographySourceDeezer, 0)]];
    CHECK(builder.images.count == 2, "seen set rebuilt by setImages");
    [builder addImages:@[makeImage(@"http://x/2.jpg", ArtistImageTypeLogo, BiographySourceDeezer, 0)]];
    CHECK(builder.images.count == 3, "URL dropped by setImages reset is addable again");
}

static void testSortEdgeCases() {
    g_context = "sortImagesByPreference";

    ArtistGalleryDataBuilder *builder = [[ArtistGalleryDataBuilder alloc] initWithArtistName:@"Muse"];
    [builder addImages:@[
        makeImage(@"http://a/banner-adb.jpg", ArtistImageTypeBanner, BiographySourceAudioDb, 0),
        makeImage(@"http://a/logo-ftv.png", ArtistImageTypeLogo, BiographySourceFanartTv, 2),
        makeImage(@"http://a/bg-adb.jpg", ArtistImageTypeBackground, BiographySourceAudioDb, 99),
        makeImage(@"http://a/bg-ftv-low.jpg", ArtistImageTypeBackground, BiographySourceFanartTv, 1),
        makeImage(@"http://a/bg-ftv-high.jpg", ArtistImageTypeBackground, BiographySourceFanartTv, 50),
        makeImage(@"http://a/thumb-dz.jpg", ArtistImageTypeThumbnail, BiographySourceDeezer, 0),
    ]];
    [builder sortImagesByPreference];

    NSArray<ArtistImage *> *sorted = builder.images;
    CHECK([sorted[0].url.absoluteString isEqualToString:@"http://a/bg-ftv-high.jpg"],
          "FanartTV background with most likes first");
    CHECK([sorted[1].url.absoluteString isEqualToString:@"http://a/bg-ftv-low.jpg"],
          "FanartTV background with fewer likes second");
    CHECK([sorted[2].url.absoluteString isEqualToString:@"http://a/logo-ftv.png"],
          "FanartTV logo before any non-FanartTV image");
    CHECK([sorted[3].url.absoluteString isEqualToString:@"http://a/bg-adb.jpg"],
          "AudioDB background leads the non-FanartTV group despite likes");
    CHECK([sorted[4].url.absoluteString isEqualToString:@"http://a/thumb-dz.jpg"],
          "Deezer thumbnail before AudioDB banner");
    CHECK([sorted[5].url.absoluteString isEqualToString:@"http://a/banner-adb.jpg"],
          "banner last");
}

// Deterministic PRNG so failures are reproducible.
static uint64_t g_rng = 0xB10B10;
static uint64_t nextRand() {
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 7;
    g_rng ^= g_rng << 17;
    return g_rng;
}

static void testSortRandomizedOracle() {
    g_context = "sort random oracle";

    BiographySource sources[] = {BiographySourceFanartTv, BiographySourceAudioDb, BiographySourceDeezer, BiographySourceLastFm};
    ArtistImageType types[] = {ArtistImageTypeBackground, ArtistImageTypeThumbnail, ArtistImageTypeLogo, ArtistImageTypeBanner};

    for (int iter = 0; iter < 300; iter++) {
        NSUInteger n = 1 + nextRand() % 20;
        NSMutableArray<ArtistImage *> *input = [NSMutableArray array];
        for (NSUInteger i = 0; i < n; i++) {
            NSString *url = [NSString stringWithFormat:@"http://r/%d-%lu.jpg", iter, (unsigned long)i];
            [input addObject:makeImage(url,
                                       types[nextRand() % 4],
                                       sources[nextRand() % 4],
                                       (NSInteger)(nextRand() % 100))];
        }

        ArtistGalleryDataBuilder *builder = [[ArtistGalleryDataBuilder alloc] initWithArtistName:@"R"];
        [builder addImages:input];
        [builder sortImagesByPreference];
        NSArray<ArtistImage *> *sorted = builder.images;

        // Invariant: same multiset (dedup can't fire - URLs unique)
        g_checks++;
        if (sorted.count != n) {
            g_failures++;
            printf("FAIL [%s] iter %d: count %lu != %lu\n", g_context.c_str(), iter,
                   (unsigned long)sorted.count, (unsigned long)n);
            continue;
        }

        // Invariant: every adjacent pair respects the naive order (no pair strictly inverted)
        BOOL orderOk = YES;
        for (NSUInteger i = 0; i + 1 < sorted.count; i++) {
            if (naiveOrderedBefore(sorted[i + 1], sorted[i])) {
                orderOk = NO;
                break;
            }
        }
        g_checks++;
        if (!orderOk) {
            g_failures++;
            printf("FAIL [%s] iter %d: adjacent pair violates preference order\n",
                   g_context.c_str(), iter);
        }
    }
}

static void testFiltersAndCoding() {
    g_context = "filters+coding";

    ArtistGalleryDataBuilder *builder = [[ArtistGalleryDataBuilder alloc] initWithArtistName:@"Muse"];
    builder.mbid = @"a74b1b7f-71a5-4011-9441-d0b5e4122711";
    [builder addImages:@[
        makeImage(@"http://f/bg.jpg", ArtistImageTypeBackground, BiographySourceFanartTv, 5),
        makeImage(@"http://f/logo.png", ArtistImageTypeLogo, BiographySourceFanartTv, 1),
        makeImage(@"http://a/thumb.jpg", ArtistImageTypeThumbnail, BiographySourceAudioDb, 0),
    ]];
    ArtistGalleryData *data = [builder build];

    CHECK(data.imageCount == 3 && !data.isEmpty, "count/isEmpty");
    CHECK([data imagesOfType:ArtistImageTypeLogo].count == 1, "imagesOfType");
    CHECK([data imagesFromSource:BiographySourceFanartTv].count == 2, "imagesFromSource");

    // Secure-coding roundtrip preserves everything
    NSError *error = nil;
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:data
                                             requiringSecureCoding:YES
                                                             error:&error];
    CHECK(archived != nil && error == nil, "archives without error");

    NSSet *classes = [NSSet setWithObjects:[ArtistGalleryData class], [ArtistImage class],
                      [NSArray class], [NSString class], [NSDate class], [NSURL class], nil];
    ArtistGalleryData *decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                     fromData:archived
                                                                        error:&error];
    CHECK(decoded != nil && error == nil, "unarchives without error");
    CHECK(decoded.imageCount == 3, "roundtrip image count");
    CHECK([decoded.artistName isEqualToString:@"Muse"], "roundtrip artist name");
    CHECK([decoded.mbid isEqualToString:data.mbid], "roundtrip mbid");
    CHECK([decoded.images.firstObject.url isEqual:data.images.firstObject.url], "roundtrip first URL");
}

int main() {
    @autoreleasepool {
        testDedup();
        testSortEdgeCases();
        testSortRandomizedOracle();
        testFiltersAndCoding();

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
