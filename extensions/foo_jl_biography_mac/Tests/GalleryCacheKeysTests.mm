//
//  GalleryCacheKeysTests.mm
//  foo_jl_biography_mac
//
//  Unit tests for GalleryCacheKeys (SHA-256 cache key derivation).
//  Gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/GalleryCacheKeys.h"

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

int main() {
    @autoreleasepool {
        g_context = "keyForImageURL";

        NSURL *url = [NSURL URLWithString:@"https://example.com/image.jpg"];
        NSString *thumbKey = [GalleryCacheKeys keyForImageURL:url thumbnail:YES];
        NSString *fullKey = [GalleryCacheKeys keyForImageURL:url thumbnail:NO];

        CHECK([thumbKey hasSuffix:@"_thumb"], "thumbnail suffix");
        CHECK([fullKey hasSuffix:@"_full"], "full suffix");
        CHECK(thumbKey.length == 64 + 6 && fullKey.length == 64 + 5,
              "hex sha256 (64 chars) + suffix");
        CHECK([[thumbKey substringToIndex:64] isEqualToString:[fullKey substringToIndex:64]],
              "same URL same hash");

        // Known vector: sha256("https://example.com/image.jpg")
        // printf '%s' 'https://example.com/image.jpg' | shasum -a 256
        CHECK([[fullKey substringToIndex:64] isEqualToString:
               @"e5db82b5bf63d49d80c5533616892d3386f43955369520986d67653c700fc53c"],
              "matches independent sha256 vector");

        NSURL *other = [NSURL URLWithString:@"https://example.com/other.jpg"];
        CHECK(![[GalleryCacheKeys keyForImageURL:other thumbnail:NO] isEqualToString:fullKey],
              "different URLs differ");

        g_context = "keyForArtist";

        NSString *museKey = [GalleryCacheKeys keyForArtist:@"Muse"];
        CHECK([museKey hasSuffix:@"_gallery"], "gallery suffix");
        CHECK([[GalleryCacheKeys keyForArtist:@"  MUSE \n"] isEqualToString:museKey],
              "case+whitespace normalized to same key");
        CHECK(![[GalleryCacheKeys keyForArtist:@"Muze"] isEqualToString:museKey],
              "different artists differ");

        // Known vector: sha256("muse")
        // printf '%s' 'muse' | shasum -a 256
        CHECK([[museKey substringToIndex:64] isEqualToString:
               @"4016c3db3bc3c731a4148022f43ebd6d4422b77976763135b9d9afcb9b71b2c1"],
              "matches independent sha256 vector");

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
