//
//  TrackMatcherTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for matching local files to TIDAL tracks (jl_tidal_lookup):
//  ISRC normalisation, artist splitting, the search query, result picking
//  by artist/title/length, cache keys, and key notation.
//

#import <Foundation/Foundation.h>
#import "../src/Core/TrackMatcher.h"
#include "TestHarness.h"

typedef JLTidalTrackMatcher Matcher;

static JLTidalTrack *track(NSString *trackID, NSString *title, NSString *version,
                           NSArray<NSString *> *artists, NSInteger duration) {
    NSMutableArray *artistDicts = [NSMutableArray array];
    for (NSString *name in artists) [artistDicts addObject:@{@"name": name}];
    NSMutableDictionary *d = [@{
        @"id": trackID, @"title": title, @"duration": @(duration),
        @"artist": @{@"name": artists.firstObject}, @"artists": artistDicts,
    } mutableCopy];
    if (version) d[@"version"] = version;
    return [[JLTidalTrack alloc] initWithDictionary:d];
}

static void testISRC(void) {
    CHECK_STREQ([Matcher normalizedISRC:@"USAB12345678"], @"USAB12345678", "plain ISRC kept");
    CHECK_STREQ([Matcher normalizedISRC:@"us-ab1-23-45678"], @"USAB12345678", "hyphens dropped, upper-cased");
    CHECK([Matcher normalizedISRC:@"USAB1234567"] == nil, "11 characters is not an ISRC");
    CHECK([Matcher normalizedISRC:@"12AB12345678"] == nil, "country code must be letters");
    CHECK([Matcher normalizedISRC:nil] == nil, "nil -> nil");
}

static void testArtistNames(void) {
    NSArray *names = [Matcher artistNamesFromTagValues:@[@"Simon & Garfunkel"]];
    CHECK([names containsObject:@"simon & garfunkel"], "whole value kept, folded");
    CHECK([names containsObject:@"simon"] && [names containsObject:@"garfunkel"], "split on &");

    names = [Matcher artistNamesFromTagValues:@[@"Björk feat. Thom Yorke", @"Extra"]];
    CHECK([names containsObject:@"bjork"], "diacritics folded, split on feat.");
    CHECK([names containsObject:@"thom yorke"], "featured artist split out");
    CHECK([names containsObject:@"extra"], "every tag value used");

    names = [Matcher artistNamesFromTagValues:@[@"Defeated Sanity"]];
    CHECK_EQ(names.count, (NSUInteger)1, "'feat' inside a word is not a separator");
    names = [Matcher artistNamesFromTagValues:@[@"Junus Orca x Vatta"]];
    CHECK([names containsObject:@"vatta"], "split on a standalone x");
}

static void testSearchQuery(void) {
    CHECK_STREQ([Matcher searchQueryForArtist:@"Artist" title:@"Song (Original Mix)"], @"Artist Song",
                "trailing version group left out of the query");
    CHECK_STREQ([Matcher searchQueryForArtist:@"Artist" title:@"Song [Remastered] (Live)"], @"Artist Song",
                "every trailing group removed");
    CHECK_STREQ([Matcher searchQueryForArtist:@"Artist" title:@"(Intro)"], @"Artist (Intro)",
                "a title that is all group is kept whole");
}

static void testBestMatch(void) {
    NSArray *artists = [Matcher artistNamesFromTagValues:@[@"Artist"]];
    NSArray *candidates = @[
        track(@"1", @"Song", nil, @[@"Someone Else"], 300),      // wrong artist
        track(@"2", @"Song", @"Radio Edit", @[@"Artist"], 200),  // wrong length
        track(@"3", @"Song", @"Original Mix", @[@"Artist"], 301),
        track(@"4", @"Song", @"Original Mix", @[@"Artist"], 300),
    ];
    JLTidalTrack *m = [Matcher bestMatchIn:candidates artists:artists title:@"Song (Original Mix)" length:300.4];
    CHECK_STREQ(m.trackID, @"4", "title + version, shared artist, closest length");

    m = [Matcher bestMatchIn:candidates artists:artists title:@"song [original mix]" length:302];
    CHECK_STREQ(m.trackID, @"3", "case and bracket style ignored; 1 s beats 2 s");

    m = [Matcher bestMatchIn:candidates artists:artists title:@"Song" length:300];
    CHECK_STREQ(m.trackID, @"4", "title alone matches a track that has a version");

    m = [Matcher bestMatchIn:candidates artists:artists title:@"Song (Original Mix)" length:310];
    CHECK(m == nil, "10 s off is a different recording");

    m = [Matcher bestMatchIn:candidates artists:artists title:@"Song (Original Mix)" length:0];
    CHECK(m == nil, "unknown local length never matches");

    m = [Matcher bestMatchIn:candidates artists:artists title:@"Other Song" length:300];
    CHECK(m == nil, "different title never matches");

    NSArray *collab = @[track(@"9", @"Duet", nil, @[@"Lead", @"Guest"], 240)];
    m = [Matcher bestMatchIn:collab artists:[Matcher artistNamesFromTagValues:@[@"Guest"]] title:@"Duet" length:241];
    CHECK_STREQ(m.trackID, @"9", "any shared credited artist is enough");
}

static void testCacheKey(void) {
    NSArray *artists = [Matcher artistNamesFromTagValues:@[@"Artist"]];
    CHECK_STREQ([Matcher cacheKeyForTrackID:@"123" isrc:@"USAB12345678" artists:artists title:@"T" length:10],
                @"id:123", "tidal:// track id wins");
    CHECK_STREQ([Matcher cacheKeyForTrackID:nil isrc:@"us-ab1-23-45678" artists:artists title:@"T" length:10],
                @"isrc:USAB12345678", "ISRC next, normalised");
    CHECK_STREQ([Matcher cacheKeyForTrackID:nil isrc:@"junk" artists:artists title:@"The  Song" length:200.6],
                @"search:artist\tthe song\t201", "malformed ISRC falls through to the search key");
    CHECK([Matcher cacheKeyForTrackID:nil isrc:nil artists:@[] title:@"T" length:10] == nil,
          "no ISRC and no artist -> nothing to match on");
    CHECK([Matcher cacheKeyForTrackID:nil isrc:nil artists:artists title:@"T" length:0] == nil,
          "no length -> nothing to match on");
}

static void testKeyName(void) {
    CHECK_STREQ([Matcher keyNameForKey:@"FSharp" scale:@"MINOR"], @"F#m", "sharp minor");
    CHECK_STREQ([Matcher keyNameForKey:@"Eb" scale:@"MAJOR"], @"Eb", "flat major");
    CHECK_STREQ([Matcher keyNameForKey:@"D" scale:@"DORIAN"], @"D Dorian", "mode spelled out");
    CHECK_STREQ([Matcher keyNameForKey:@"A" scale:@"HARMONIC_MINOR"], @"A Harmonic Minor", "multi-word mode");
    CHECK_STREQ([Matcher keyNameForKey:@"C" scale:nil], @"C", "unknown scale -> tonic only");
    CHECK_STREQ([Matcher keyNameForKey:@"UNKNOWN" scale:@"MINOR"], @"", "unknown key -> empty");
    CHECK_STREQ([Matcher keyNameForKey:nil scale:nil], @"", "nil -> empty");
}

int main(void) {
    @autoreleasepool {
        testISRC();
        testArtistNames();
        testSearchQuery();
        testBestMatch();
        testCacheKey();
        testKeyName();
    }
    return testHarnessFinish("TrackMatcher");
}
