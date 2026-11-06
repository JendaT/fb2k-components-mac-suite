//
//  DashCachePolicyTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for the DASH prefetch cache helpers: segment-URL generation
//  ($Number$ substitution over 0..count-1) and byte-capped LRU eviction.
//

#import <Foundation/Foundation.h>
#import "../src/Core/DashCachePolicy.h"
#include "TestHarness.h"

typedef JLTidalDashCachePolicy Policy;

static void testSegmentURLs(void) {
    NSString *tpl = @"https://cdn.tidal.com/seg/$Number$.mp4?token=abc";
    NSArray<NSString *> *urls = [Policy segmentURLsForTemplate:tpl count:3];
    CHECK_EQ(urls.count, (NSUInteger)3, "3 segment URLs");
    CHECK_STREQ(urls[0], @"https://cdn.tidal.com/seg/0.mp4?token=abc", "segment 0 is the init segment");
    CHECK_STREQ(urls[1], @"https://cdn.tidal.com/seg/1.mp4?token=abc", "segment 1");
    CHECK_STREQ(urls[2], @"https://cdn.tidal.com/seg/2.mp4?token=abc", "segment 2");

    // Substitutes every occurrence (Tidal templates only have one, but be safe)
    NSArray<NSString *> *multi = [Policy segmentURLsForTemplate:@"a/$Number$/b/$Number$" count:2];
    CHECK_STREQ(multi[1], @"a/1/b/1", "all $Number$ occurrences replaced");

    // Degenerate inputs
    CHECK_EQ([Policy segmentURLsForTemplate:tpl count:0].count, (NSUInteger)0, "count 0 -> empty");
    CHECK_EQ([Policy segmentURLsForTemplate:tpl count:-5].count, (NSUInteger)0, "negative count -> empty");
    CHECK_EQ([Policy segmentURLsForTemplate:@"no placeholder" count:3].count, (NSUInteger)0,
             "template without $Number$ -> empty");
}

static void testEviction(void) {
    // Under cap -> nothing evicted
    NSArray *order = @[@"a", @"b", @"c"];
    NSDictionary *sizes = @{@"a": @100, @"b": @100, @"c": @100};
    CHECK_EQ([Policy evictionKeysForOrder:order sizes:sizes capBytes:1000].count, (NSUInteger)0,
             "under cap evicts nothing");

    // Over cap -> evict oldest first until fitting
    NSArray<NSString *> *evict = [Policy evictionKeysForOrder:order sizes:sizes capBytes:250];
    CHECK_EQ(evict.count, (NSUInteger)1, "evict 1 to fit 300 under 250");
    CHECK_STREQ(evict[0], @"a", "oldest evicted first");

    // Tighter cap evicts more, still oldest-first
    evict = [Policy evictionKeysForOrder:order sizes:sizes capBytes:150];
    CHECK_EQ(evict.count, (NSUInteger)2, "evict 2 to fit 300 under 150");
    CHECK_STREQ(evict[0], @"a", "first evicted is oldest");
    CHECK_STREQ(evict[1], @"b", "second evicted is next-oldest");

    // Never evicts the last (newest) entry even if it alone exceeds the cap
    evict = [Policy evictionKeysForOrder:@[@"only"] sizes:@{@"only": @999} capBytes:10];
    CHECK_EQ(evict.count, (NSUInteger)0, "single oversized blob is kept");

    evict = [Policy evictionKeysForOrder:order sizes:@{@"a": @100, @"b": @100, @"c": @999} capBytes:10];
    CHECK_EQ(evict.count, (NSUInteger)2, "evict all but the newest oversized blob");
    CHECK_STREQ(evict[0], @"a", "oldest first");
    CHECK_STREQ(evict[1], @"b", "then next");

    // Exactly at cap -> no eviction (cap is inclusive)
    CHECK_EQ([Policy evictionKeysForOrder:order sizes:sizes capBytes:300].count, (NSUInteger)0,
             "total == cap evicts nothing");
}

int main(void) {
    @autoreleasepool {
        testSegmentURLs();
        testEviction();
    }
    return testHarnessFinish("DashCachePolicy");
}
