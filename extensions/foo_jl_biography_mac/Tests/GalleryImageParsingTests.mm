//
//  GalleryImageParsingTests.mm
//  foo_jl_biography_mac
//
//  Unit tests for GalleryImageParsing (AudioDB/Fanart.tv/Deezer JSON -> ArtistImage).
//  Foundation+CoreGraphics only, compiled standalone; gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/GalleryImageParsing.h"
#import "../src/Core/ArtistImage.h"

#include <string>

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

static ArtistImage *imageWithURLString(NSArray<ArtistImage *> *images, NSString *urlString) {
    for (ArtistImage *image in images) {
        if ([image.url.absoluteString isEqualToString:urlString]) return image;
    }
    return nil;
}

static void testAudioDbParsing() {
    g_context = "imagesFromAudioDbArtist";

    NSDictionary *artist = @{
        @"strArtist": @"Muse",
        @"strArtistFanart": @"http://adb/fanart1.jpg",
        @"strArtistFanart2": @"http://adb/fanart2.jpg",
        @"strArtistFanart3": [NSNull null],
        @"strArtistFanart4": @"",
        @"strArtistThumb": @"http://adb/thumb.jpg",
        @"strArtistLogo": @"http://adb/logo.png",
        @"strArtistWideThumb": @"http://adb/wide.jpg",
        @"strArtistBanner": @"http://adb/banner.jpg",
        @"strArtistCutout": @"http://adb/cutout.png",
        @"strArtistClearart": @"http://adb/clear.png",
    };

    NSArray<ArtistImage *> *images = [GalleryImageParsing imagesFromAudioDbArtist:artist];
    CHECK(images.count == 8, "2 fanarts + thumb + logo + wide + banner + cutout + clearart");

    ArtistImage *fanart = imageWithURLString(images, @"http://adb/fanart1.jpg");
    CHECK(fanart != nil, "fanart1 parsed");
    CHECK(fanart.imageType == ArtistImageTypeBackground, "fanart is background");
    CHECK(fanart.source == BiographySourceAudioDb, "source is AudioDB");
    CHECK([fanart.thumbnailURL.absoluteString isEqualToString:@"http://adb/fanart1.jpg/preview"],
          "backgrounds get /preview thumbnail");

    ArtistImage *thumb = imageWithURLString(images, @"http://adb/thumb.jpg");
    CHECK(thumb.imageType == ArtistImageTypeThumbnail, "thumb type");
    CHECK(thumb.thumbnailURL == nil, "non-backgrounds have no preview thumb");
    CHECK(imageWithURLString(images, @"http://adb/logo.png").imageType == ArtistImageTypeLogo,
          "logo type");
    CHECK(imageWithURLString(images, @"http://adb/banner.jpg").imageType == ArtistImageTypeBanner,
          "banner type");
    CHECK(imageWithURLString(images, @"http://adb/cutout.png").imageType == ArtistImageTypeThumbnail,
          "cutout used as thumbnail");
    CHECK(imageWithURLString(images, @"http://adb/clear.png").imageType == ArtistImageTypeLogo,
          "clearart used as logo");

    CHECK([GalleryImageParsing imagesFromAudioDbArtist:@{}].count == 0, "empty artist yields none");
    CHECK([GalleryImageParsing imagesFromAudioDbArtist:@{@"strArtistThumb": @123}].count == 0,
          "non-string value rejected");
}

static void testFanartTvParsing() {
    g_context = "imagesFromFanartTvResponse";

    NSDictionary *response = @{
        @"artistbackground": @[
            @{@"url": @"http://ftv/bg1.jpg", @"likes": @"12"},
            @{@"url": @"http://ftv/bg2.jpg", @"likes": @5},
            @"not-a-dict",
            @{@"url": @123},
            @{@"nourl": @"x"},
        ],
        @"artistthumb": @[@{@"url": @"http://ftv/thumb.jpg"}],
        @"hdmusiclogo": @[@{@"url": @"http://ftv/hdlogo.png"}],
        @"musiclogo": @[@{@"url": @"http://ftv/logo.png"}],
        @"musicbanner": @[@{@"url": @"http://ftv/banner.jpg"}],
        @"unrelated": @[@{@"url": @"http://ftv/nope.jpg"}],
    };

    NSArray<ArtistImage *> *images = [GalleryImageParsing imagesFromFanartTvResponse:response];
    CHECK(images.count == 6, "2 backgrounds + thumb + 2 logos + banner (malformed skipped)");

    ArtistImage *bg1 = imageWithURLString(images, @"http://ftv/bg1.jpg");
    CHECK(bg1.likes == 12, "string likes parsed via integerValue");
    CHECK(imageWithURLString(images, @"http://ftv/bg2.jpg").likes == 5, "number likes parsed");
    CHECK(bg1.source == BiographySourceFanartTv, "source is FanartTV");
    CHECK(bg1.thumbnailURL == nil, "FanartTV provides no thumbs");
    CHECK(imageWithURLString(images, @"http://ftv/hdlogo.png").imageType == ArtistImageTypeLogo,
          "hd logo type");
    CHECK(imageWithURLString(images, @"http://ftv/nope.jpg") == nil, "unrelated category ignored");

    // Categories must be arrays
    CHECK([GalleryImageParsing imagesFromFanartTvResponse:@{@"artistbackground": @"zzz"}].count == 0,
          "non-array category rejected");
}

static void testDeezerParsing() {
    g_context = "imageFromDeezerArtist";

    // XL preferred, big as thumbnail
    ArtistImage *image = [GalleryImageParsing imageFromDeezerArtist:@{
        @"picture_xl": @"http://dz/xl.jpg",
        @"picture_big": @"http://dz/big.jpg",
        @"picture_medium": @"http://dz/med.jpg",
    }];
    CHECK([image.url.absoluteString isEqualToString:@"http://dz/xl.jpg"], "XL preferred");
    CHECK([image.thumbnailURL.absoluteString isEqualToString:@"http://dz/big.jpg"],
          "big used as thumbnail");
    CHECK(image.source == BiographySourceDeezer, "source is Deezer");
    CHECK(image.originalSize.width == 1000 && image.originalSize.height == 1000, "XL is 1000x1000");

    // Fallback chain
    image = [GalleryImageParsing imageFromDeezerArtist:@{@"picture_medium": @"http://dz/med.jpg"}];
    CHECK([image.url.absoluteString isEqualToString:@"http://dz/med.jpg"], "medium as last resort");

    // Placeholder (empty-string MD5 in URL) skipped
    image = [GalleryImageParsing imageFromDeezerArtist:@{
        @"picture_xl": @"https://cdn-images.dzcdn.net/images/artist/d41d8cd98f00b204e9800998ecf8427e/1000x1000.jpg"
    }];
    CHECK(image == nil, "default placeholder skipped");

    CHECK([GalleryImageParsing imageFromDeezerArtist:@{}] == nil, "no pictures yields nil");
    CHECK([GalleryImageParsing imageFromDeezerArtist:@{@"picture_xl": @42}] == nil,
          "non-string picture rejected");
}

static void testMBIDValidation() {
    g_context = "isValidMBID";

    CHECK([GalleryImageParsing isValidMBID:@"a74b1b7f-71a5-4011-9441-d0b5e4122711"], "valid lowercase");
    CHECK([GalleryImageParsing isValidMBID:@"A74B1B7F-71A5-4011-9441-D0B5E4122711"], "valid uppercase");
    CHECK([GalleryImageParsing isValidMBID:nil] == NO, "nil rejected");
    CHECK([GalleryImageParsing isValidMBID:@""] == NO, "empty rejected");
    CHECK([GalleryImageParsing isValidMBID:@"not-a-uuid"] == NO, "garbage rejected");
    CHECK([GalleryImageParsing isValidMBID:@"a74b1b7f-71a5-4011-9441-d0b5e412271"] == NO,
          "truncated rejected");
    CHECK([GalleryImageParsing isValidMBID:@"a74b1b7f-71a5-4011-9441-d0b5e4122711/../x"] == NO,
          "path injection rejected");
}

int main() {
    @autoreleasepool {
        testAudioDbParsing();
        testFanartTvParsing();
        testDeezerParsing();
        testMBIDValidation();

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
