//
//  TrackMatcher.mm
//  foo_jl_tidal_mac
//

#import "TrackMatcher.h"

#include <cmath>

const double JLTidalMatchLengthTolerance = 2.0;

// Case, diacritics and width folded, typographic quotes and square brackets
// unified, whitespace collapsed: tags and catalogue spell the same words with
// different bytes often enough that a literal compare misses real matches.
static NSString *normalized(NSString *s) {
    if (s.length == 0) return @"";
    NSMutableString *f = [[s stringByFoldingWithOptions:NSCaseInsensitiveSearch |
                                                        NSDiacriticInsensitiveSearch |
                                                        NSWidthInsensitiveSearch
                                                  locale:nil] mutableCopy];
    NSDictionary<NSString *, NSString *> *unify = @{
        @"\u2018": @"'", @"\u2019": @"'", @"\u201C": @"\"", @"\u201D": @"\"",
        @"[": @"(", @"]": @")",
    };
    for (NSString *from in unify) {
        [f replaceOccurrencesOfString:from withString:unify[from] options:0 range:NSMakeRange(0, f.length)];
    }
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *w in [f componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (w.length > 0) [words addObject:w];
    }
    return [words componentsJoinedByString:@" "];
}

@implementation JLTidalTrackMatcher

+ (NSString *)normalizedISRC:(NSString *)isrc {
    if (isrc.length == 0) return nil;
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *alnum = NSCharacterSet.alphanumericCharacterSet;
    for (NSUInteger i = 0; i < isrc.length; i++) {
        unichar c = [isrc characterAtIndex:i];
        if ([alnum characterIsMember:c]) [out appendFormat:@"%C", c];
    }
    NSString *upper = out.uppercaseString;
    // CC-XXX-YY-NNNNN: country, registrant, year, designation.
    static NSRegularExpression *shape;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shape = [NSRegularExpression regularExpressionWithPattern:@"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$"
                                                          options:0 error:nil];
    });
    if ([shape numberOfMatchesInString:upper options:0 range:NSMakeRange(0, upper.length)] != 1) return nil;
    return upper;
}

+ (NSArray<NSString *> *)artistNamesFromTagValues:(NSArray<NSString *> *)values {
    static NSRegularExpression *separators;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        separators = [NSRegularExpression regularExpressionWithPattern:
            @"\\s*(?:;|,|/|&|\\bfeat\\b\\.?|\\bfeaturing\\b|\\bft\\b\\.?|\\bvs\\b\\.?|\\bx\\b)\\s*"
                                                               options:0 error:nil];
    });
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    for (NSString *value in values) {
        NSString *whole = normalized(value);
        if (whole.length == 0) continue;
        [names addObject:whole];
        NSString *split = [separators stringByReplacingMatchesInString:whole options:0
                                                                 range:NSMakeRange(0, whole.length)
                                                          withTemplate:@"\u0001"];
        for (NSString *part in [split componentsSeparatedByString:@"\u0001"]) {
            NSString *name = normalized(part);
            if (name.length > 0) [names addObject:name];
        }
    }
    return names.array;
}

+ (NSString *)searchQueryForArtist:(NSString *)artist title:(NSString *)title {
    static NSRegularExpression *trailingGroup;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        trailingGroup = [NSRegularExpression regularExpressionWithPattern:@"\\s*[(\\[][^()\\[\\]]*[)\\]]\\s*$"
                                                                  options:0 error:nil];
    });
    NSString *bare = title ?: @"";
    for (;;) {
        NSString *next = [trailingGroup stringByReplacingMatchesInString:bare options:0
                                                                   range:NSMakeRange(0, bare.length)
                                                            withTemplate:@""];
        if ([next isEqualToString:bare]) break;
        bare = next;
    }
    if (bare.length == 0) bare = title ?: @"";
    NSString *query = [NSString stringWithFormat:@"%@ %@", artist ?: @"", bare];
    return [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

+ (JLTidalTrack *)bestMatchIn:(NSArray<JLTidalTrack *> *)candidates
                      artists:(NSArray<NSString *> *)artists
                        title:(NSString *)title
                       length:(double)seconds {
    if (seconds <= 0 || title.length == 0 || artists.count == 0) return nil;
    NSSet<NSString *> *localArtists = [NSSet setWithArray:artists];
    NSString *localTitle = normalized(title);

    JLTidalTrack *best = nil;
    double bestDiff = INFINITY;
    for (JLTidalTrack *c in candidates) {
        double diff = std::fabs((double)c.duration - seconds);
        if (c.duration <= 0 || diff > JLTidalMatchLengthTolerance) continue;

        NSArray<NSString *> *names = c.allArtists.count ? c.allArtists : (c.artist ? @[c.artist] : @[]);
        BOOL shared = NO;
        for (NSString *name in names) {
            if ([localArtists containsObject:normalized(name)]) { shared = YES; break; }
        }
        if (!shared) continue;

        BOOL sameTitle = [normalized(c.title) isEqualToString:localTitle];
        if (!sameTitle && c.version.length > 0) {
            NSString *full = [NSString stringWithFormat:@"%@ (%@)", c.title, c.version];
            sameTitle = [normalized(full) isEqualToString:localTitle];
        }
        if (!sameTitle) continue;

        if (diff < bestDiff) {
            best = c;
            bestDiff = diff;
        }
    }
    return best;
}

+ (NSString *)cacheKeyForTrackID:(NSString *)trackID
                            isrc:(NSString *)isrc
                         artists:(NSArray<NSString *> *)artists
                           title:(NSString *)title
                          length:(double)seconds {
    if (trackID.length > 0) return [@"id:" stringByAppendingString:trackID];
    NSString *code = [self normalizedISRC:isrc];
    if (code) return [@"isrc:" stringByAppendingString:code];
    NSString *t = normalized(title);
    if (artists.count == 0 || t.length == 0 || seconds <= 0) return nil;
    return [NSString stringWithFormat:@"search:%@\t%@\t%ld",
            [artists componentsJoinedByString:@";"], t, std::lround(seconds)];
}

+ (NSString *)keyNameForKey:(NSString *)key scale:(NSString *)scale {
    if (key.length == 0 || [key isEqualToString:@"UNKNOWN"]) return @"";
    NSString *tonic = key;
    if ([key hasSuffix:@"Sharp"]) {
        tonic = [[key substringToIndex:key.length - 5] stringByAppendingString:@"#"];
    } else if ([key hasSuffix:@"Flat"]) {
        tonic = [[key substringToIndex:key.length - 4] stringByAppendingString:@"b"];
    }
    if (scale.length == 0 || [scale isEqualToString:@"UNKNOWN"] || [scale isEqualToString:@"MAJOR"]) {
        return tonic;
    }
    if ([scale isEqualToString:@"MINOR"]) return [tonic stringByAppendingString:@"m"];
    NSString *mode = [[scale stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedString];
    return [NSString stringWithFormat:@"%@ %@", tonic, mode];
}

@end
