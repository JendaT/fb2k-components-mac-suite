//
//  LibraryLayoutTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for the music.hq path/naming logic: sanitization, release
//  folder naming, slot decisions (artist folder / [Releases] / [Compilations]),
//  track file names, collection scanning, ffmpeg remux arguments.
//

#import <Foundation/Foundation.h>
#import "../src/Core/LibraryLayout.h"
#include "TestHarness.h"

typedef JLTidalLibraryLayout Layout;

static NSDate *dateFromYMD(NSString *ymd) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd";
    fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [fmt dateFromString:ymd];
}

static void testSanitize(void) {
    CHECK_STREQ([Layout sanitizeComponent:@"AC/DC"], @"AC-DC", "slash replaced");
    CHECK_STREQ([Layout sanitizeComponent:@"Re:Creation"], @"Re-Creation", "colon replaced");
    CHECK_STREQ([Layout sanitizeComponent:@"What?"], @"What-", "question mark replaced");
    CHECK_STREQ([Layout sanitizeComponent:@"\"Heroes\""], @"'Heroes'", "quotes become apostrophes");
    CHECK_STREQ([Layout sanitizeComponent:@"a<b>c|d*e\\f"], @"a-b-c-d-e-f", "remaining forbidden chars replaced");
    CHECK_STREQ([Layout sanitizeComponent:@"  spaced   out  "], @"spaced out", "whitespace collapsed and trimmed");
    CHECK_STREQ([Layout sanitizeComponent:@"Vol. 2..."], @"Vol. 2", "trailing dots stripped");
    CHECK_STREQ([Layout sanitizeComponent:@"tab\there"], @"tab here", "tab collapses to space");
    CHECK_STREQ([Layout sanitizeComponent:nil], @"Unknown", "nil -> Unknown");
    CHECK_STREQ([Layout sanitizeComponent:@""], @"Unknown", "empty -> Unknown");
    CHECK_STREQ([Layout sanitizeComponent:@"///"], @"---", "all-forbidden input keeps replacements");
    CHECK_STREQ([Layout sanitizeComponent:@"..."], @"Unknown", "dots-only collapses to Unknown");
    CHECK_STREQ([Layout sanitizeComponent:@"Čajovna u Šamana"], @"Čajovna u Šamana", "diacritics preserved");

    // Length cap
    NSMutableString *longName = [NSMutableString string];
    for (int i = 0; i < 40; i++) [longName appendString:@"abcdefghij"];
    CHECK([Layout sanitizeComponent:longName].length <= 180, "long names capped");
}

static void testYearAndVA(void) {
    CHECK_STREQ([Layout yearStringFromDate:dateFromYMD(@"1997-06-30")], @"1997", "year extracted");
    CHECK_STREQ([Layout yearStringFromDate:dateFromYMD(@"2011-01-01")], @"2011", "Jan 1 stays in its year (UTC)");
    CHECK([Layout yearStringFromDate:nil] == nil, "nil date -> nil year");

    CHECK([Layout isVariousArtists:@"Various Artists"], "Various Artists");
    CHECK([Layout isVariousArtists:@"various artists"], "case-insensitive");
    CHECK([Layout isVariousArtists:@"VA"], "VA");
    CHECK([Layout isVariousArtists:@"V.A."], "V.A.");
    CHECK([Layout isVariousArtists:@"Various"], "Various");
    CHECK(![Layout isVariousArtists:@"Vangelis"], "Vangelis is not VA");
    CHECK(![Layout isVariousArtists:nil], "nil is not VA");
    CHECK(![Layout isVariousArtists:@""], "empty is not VA");
}

static void testReleaseFolderNames(void) {
    CHECK_STREQ([Layout releaseFolderNameForArtist:@"Carbon Based Lifeforms" year:@"2006" title:@"World of Sleepers"],
                @"Carbon Based Lifeforms [2006] World of Sleepers", "canonical release folder");
    CHECK_STREQ([Layout releaseFolderNameForArtist:@"Aes Dana" year:nil title:@"Pollen"],
                @"Aes Dana [0000] Pollen", "unknown year renders as [0000]");
    CHECK_STREQ([Layout releaseFolderNameForArtist:@"AC/DC" year:@"1980" title:@"Back in Black"],
                @"AC-DC [1980] Back in Black", "artist sanitized inside folder name");
    CHECK_STREQ([Layout compilationFolderNameForYear:@"2011" title:@"Freeflow"],
                @"VA [2011] Freeflow", "compilation folder prefixed VA");
    CHECK_STREQ([Layout compilationFolderNameForYear:nil title:@"Chill Out"],
                @"VA [0000] Chill Out", "compilation with unknown year");
}

static void testAlbumPathSlots(void) {
    // Existing artist folder wins
    CHECK_STREQ([Layout albumPathForArtist:@"Solar Fields" year:@"2005" albumTitle:@"Leaving Home"
                             isCompilation:NO artistFolder:@"Solar Fields"],
                @"Solar Fields/Solar Fields [2005] Leaving Home", "artist folder slot");
    // On-disk folder name (different case) is respected verbatim
    CHECK_STREQ([Layout albumPathForArtist:@"solar fields" year:@"2005" albumTitle:@"Leaving Home"
                             isCompilation:NO artistFolder:@"Solar Fields"],
                @"Solar Fields/solar fields [2005] Leaving Home", "existing folder casing kept for the directory");
    // No artist folder -> [Releases]
    CHECK_STREQ([Layout albumPathForArtist:@"H.U.V.A. Network" year:@"2004" albumTitle:@"Distances"
                             isCompilation:NO artistFolder:nil],
                @"[Releases]/H.U.V.A. Network [2004] Distances", "releases slot");
    // Compilation -> [Compilations], regardless of artist folder
    CHECK_STREQ([Layout albumPathForArtist:@"Various Artists" year:@"2011" albumTitle:@"Freeflow"
                             isCompilation:YES artistFolder:@"Various Artists"],
                @"[Compilations]/VA [2011] Freeflow", "compilations slot beats artist folder");
}

static void testTrackFileNames(void) {
    CHECK_STREQ([Layout trackFileNameForNumber:1 discNumber:1 title:@"Abiogenesis" extension:@"flac"],
                @"01 - Abiogenesis.flac", "two-digit track number");
    CHECK_STREQ([Layout trackFileNameForNumber:12 discNumber:0 title:@"MOS 6581" extension:@"flac"],
                @"12 - MOS 6581.flac", "disc 0 treated as single disc");
    CHECK_STREQ([Layout trackFileNameForNumber:3 discNumber:2 title:@"Epilog" extension:@"flac"],
                @"2-03 - Epilog.flac", "disc >= 2 gets disc prefix");
    CHECK_STREQ([Layout trackFileNameForNumber:0 discNumber:1 title:@"Untitled" extension:@"m4a"],
                @"Untitled.m4a", "track number 0 drops the prefix");
    CHECK_STREQ([Layout trackFileNameForNumber:7 discNumber:1 title:@"Fast/Forward" extension:@"flac"],
                @"07 - Fast-Forward.flac", "title sanitized");
}

static void testCollectionScanning(void) {
    NSArray *listing = @[@"[Psytrance & Goa]", @"[Ambient]", @"Solar Fields", @"[Releases]",
                         @"[Compilations]", @".DS_Store", @"loose file.txt", @"[Electronic & Berlin School]"];
    NSArray *collections = [Layout collectionNamesFromListing:listing];
    CHECK_EQ(collections.count, (NSUInteger)3, "three genre collections found");
    CHECK_STREQ(collections[0], @"[Ambient]", "sorted first");
    CHECK_STREQ(collections[1], @"[Electronic & Berlin School]", "sorted second");
    CHECK_STREQ(collections[2], @"[Psytrance & Goa]", "sorted third");
    CHECK_EQ([Layout collectionNamesFromListing:@[]].count, (NSUInteger)0, "empty listing");

    NSArray *inCollection = @[@"[Releases]", @"[Compilations]", @"Solar Fields", @"Aes Dana", @"cover.jpg"];
    CHECK_STREQ([Layout artistFolderInListing:inCollection artist:@"Solar Fields"],
                @"Solar Fields", "exact artist folder match");
    CHECK_STREQ([Layout artistFolderInListing:inCollection artist:@"solar FIELDS"],
                @"Solar Fields", "case-insensitive match returns on-disk name");
    CHECK([Layout artistFolderInListing:inCollection artist:@"Vibrasphere"] == nil, "no match -> nil");
    CHECK([Layout artistFolderInListing:inCollection artist:@"[Releases]"] == nil, "slot folders never match");
    CHECK([Layout artistFolderInListing:inCollection artist:nil] == nil, "nil artist -> nil");
    // Sanitized comparison: "AC/DC" matches an on-disk "AC-DC" folder
    CHECK_STREQ([Layout artistFolderInListing:@[@"AC-DC"] artist:@"AC/DC"],
                @"AC-DC", "match runs on the sanitized artist name");
}

static void testFfmpegArguments(void) {
    NSArray *args = [Layout ffmpegArgumentsForInput:@"/tmp/in.mp4" output:@"/lib/01 - T.flac"
                                           metadata:@{@"title": @"T", @"artist": @"A", @"date": @""}];
    NSArray *expected = @[@"-y", @"-i", @"/tmp/in.mp4", @"-map_metadata", @"-1", @"-vn",
                          @"-c:a", @"copy",
                          @"-metadata", @"artist=A",
                          @"-metadata", @"title=T",
                          @"/lib/01 - T.flac"];
    CHECK_EQ(args.count, expected.count, "argument count (empty value dropped)");
    for (NSUInteger i = 0; i < MIN(args.count, expected.count); i++) {
        CHECK_STREQ(args[i], expected[i], "ffmpeg arg matches");
    }

    NSArray *bare = [Layout ffmpegArgumentsForInput:@"a" output:@"b" metadata:@{}];
    CHECK_EQ(bare.count, (NSUInteger)9, "no metadata -> base args + output");
    CHECK_STREQ(bare.lastObject, @"b", "output is last");
}

int main(void) {
    @autoreleasepool {
        testSanitize();
        testYearAndVA();
        testReleaseFolderNames();
        testAlbumPathSlots();
        testTrackFileNames();
        testCollectionScanning();
        testFfmpegArguments();
    }
    return testHarnessFinish("LibraryLayout");
}
