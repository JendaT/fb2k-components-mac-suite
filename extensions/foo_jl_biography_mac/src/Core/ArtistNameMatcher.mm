//
//  ArtistNameMatcher.mm
//  foo_jl_biography_mac
//
//  Artist-name disambiguation rules shared by the API clients
//

#import "ArtistNameMatcher.h"

@implementation ArtistNameMatcher

+ (BOOL)name:(NSString *)returnedName matchesRequested:(NSString *)requestedName {
    if (!returnedName || !requestedName) return NO;

    // Case-insensitive comparison
    NSString *normalizedReturned = [returnedName lowercaseString];
    NSString *normalizedRequested = [requestedName lowercaseString];

    // Exact match
    if ([normalizedReturned isEqualToString:normalizedRequested]) {
        return YES;
    }

    // QUAL-16: Only use containsString for names >= 4 chars to avoid false positives
    if (normalizedRequested.length >= 4 && normalizedReturned.length >= 4) {
        if ([normalizedReturned containsString:normalizedRequested] ||
            [normalizedRequested containsString:normalizedReturned]) {
            return YES;
        }
    }

    // Remove common prefixes and compare
    NSArray *prefixes = @[@"the ", @"a ", @"an "];
    NSString *strippedReturned = normalizedReturned;
    NSString *strippedRequested = normalizedRequested;

    for (NSString *prefix in prefixes) {
        if ([strippedReturned hasPrefix:prefix]) {
            strippedReturned = [strippedReturned substringFromIndex:prefix.length];
        }
        if ([strippedRequested hasPrefix:prefix]) {
            strippedRequested = [strippedRequested substringFromIndex:prefix.length];
        }
    }

    return [strippedReturned isEqualToString:strippedRequested];
}

+ (NSDictionary *)bestMatchInResults:(NSArray *)results
                             forName:(NSString *)requestedName
                             nameKey:(NSString *)nameKey {
    if (![results isKindOfClass:[NSArray class]] || results.count == 0) return nil;

    NSString *searchLower = [requestedName lowercaseString];

    // Exact case-insensitive match wins
    for (NSDictionary *item in results) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = item[nameKey];
        if ([name isKindOfClass:[NSString class]] &&
            [[name lowercaseString] isEqualToString:searchLower]) {
            return item;
        }
    }

    // SEC-9: Only accept exact match or close match (not arbitrary first result)
    NSDictionary *firstResult = results.firstObject;
    if (![firstResult isKindOfClass:[NSDictionary class]]) return nil;
    NSString *firstName = firstResult[nameKey];
    if ([firstName isKindOfClass:[NSString class]] &&
        [[firstName lowercaseString] containsString:searchLower] &&
        searchLower.length >= 4) {
        return firstResult;
    }

    return nil;
}

@end
