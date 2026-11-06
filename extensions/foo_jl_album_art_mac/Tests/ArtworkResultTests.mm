//
//  ArtworkResultTests.mm
//  foo_jl_album_art_mac
//
//  Unit tests for ArtworkResult (value semantics, dedup identity, hashing).
//

#import "TestHarness.h"
#import "../src/Core/ArtworkResult.h"

static ArtworkResult *MakeResult(NSString *fullURL, NSString *hash) {
    return [[ArtworkResult alloc] initWithSourceIdentifier:@"test"
                                                sourceName:@"Test"
                                              thumbnailURL:[NSURL URLWithString:@"https://x/t.jpg"]
                                         fullResolutionURL:[NSURL URLWithString:fullURL]
                                                resolution:CGSizeMake(1200, 1200)
                                               artworkType:RemoteArtworkTypeFront
                                                 imageHash:hash
                                                  variants:nil];
}

static void testImageHash(void) {
    TEST_CONTEXT("ArtworkImageHash");

    // SHA-256("abc") is a well-known vector
    NSData *abc = [@"abc" dataUsingEncoding:NSUTF8StringEncoding];
    CHECK_STR_EQ(ArtworkImageHash(abc),
                 @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                 "sha256 of 'abc'");

    NSData *nilData = nil;
    CHECK_NIL(ArtworkImageHash(nilData), "nil data");
    CHECK_NIL(ArtworkImageHash([NSData data]), "empty data");
}

static void testEquality(void) {
    TEST_CONTEXT("equality");

    // Same hash from different URLs: equal (cross-source duplicate)
    ArtworkResult *a = MakeResult(@"https://a/full.jpg", @"deadbeef");
    ArtworkResult *b = MakeResult(@"https://b/full.jpg", @"deadbeef");
    CHECK_TRUE([a isEqual:b], "same hash equal");

    // Different hashes: not equal even with same URL
    ArtworkResult *c = MakeResult(@"https://a/full.jpg", @"cafebabe");
    CHECK_FALSE([a isEqual:c], "different hash not equal");

    // No hashes: fall back to URL comparison
    ArtworkResult *d = MakeResult(@"https://a/full.jpg", nil);
    ArtworkResult *e = MakeResult(@"https://a/full.jpg", nil);
    ArtworkResult *f = MakeResult(@"https://b/full.jpg", nil);
    CHECK_TRUE([d isEqual:e], "same URL equal");
    CHECK_FALSE([d isEqual:f], "different URL not equal");
    CHECK_FALSE([d isEqual:@"not a result"], "different class not equal");
}

static void testDescriptions(void) {
    TEST_CONTEXT("descriptions");

    ArtworkResult *result = MakeResult(@"https://a/full.jpg", nil);
    CHECK_STR_EQ(result.resolutionDescription, @"1200x1200", "resolution string");
    CHECK_STR_EQ(result.typeDescription, @"Front Cover", "type without variants");

    ArtworkResult *unknownRes = [[ArtworkResult alloc]
        initWithSourceIdentifier:@"test"
                      sourceName:@"Test"
                    thumbnailURL:[NSURL URLWithString:@"https://x/t.jpg"]
               fullResolutionURL:[NSURL URLWithString:@"https://x/f.jpg"]
                      resolution:CGSizeZero
                     artworkType:RemoteArtworkTypeBack
                       imageHash:nil
                        variants:@[@"Vinyl", @"Limited Edition"]];
    CHECK_STR_EQ(unknownRes.resolutionDescription, @"Unknown", "unknown resolution");
    CHECK_STR_EQ(unknownRes.typeDescription, @"Back Cover (Vinyl, Limited Edition)", "type with variants");
}

static void testHashCopy(void) {
    TEST_CONTEXT("resultWithImageHash");

    ArtworkResult *original = MakeResult(@"https://a/full.jpg", nil);
    ArtworkResult *hashed = [original resultWithImageHash:@"deadbeef"];
    CHECK_STR_EQ(hashed.imageHash, @"deadbeef", "hash set");
    CHECK_STR_EQ(hashed.fullResolutionURL.absoluteString,
                 original.fullResolutionURL.absoluteString, "URL preserved");
    CHECK_EQ(hashed.artworkType, original.artworkType, "type preserved");
}

int main(void) {
    @autoreleasepool {
        testImageHash();
        testEquality();
        testDescriptions();
        testHashCopy();
    }
    return test_summary("ArtworkResultTests");
}
