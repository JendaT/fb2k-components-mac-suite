//
//  WikipediaParsing.mm
//  foo_jl_biography_mac
//
//  Pure parsing of Wikidata sitelink and Wikipedia REST summary responses
//

#import "WikipediaParsing.h"

@implementation WikipediaParsing

+ (NSString *)enwikiTitleFromWikidataResponse:(NSDictionary *)response {
    if (![response isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *entities = response[@"entities"];
    if (![entities isKindOfClass:[NSDictionary class]]) return nil;

    // The single entity is keyed by its QID; iterate rather than assume the key
    for (id entity in entities.allValues) {
        if (![entity isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *sitelinks = entity[@"sitelinks"];
        if (![sitelinks isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *enwiki = sitelinks[@"enwiki"];
        if (![enwiki isKindOfClass:[NSDictionary class]]) continue;
        NSString *title = enwiki[@"title"];
        if ([title isKindOfClass:[NSString class]] && title.length > 0) {
            return title;
        }
    }

    return nil;
}

+ (NSString *)summaryExtractFromResponse:(NSDictionary *)response {
    if (![response isKindOfClass:[NSDictionary class]]) return nil;

    // Disambiguation pages are never a usable biography
    NSString *type = response[@"type"];
    if ([type isKindOfClass:[NSString class]] && [type isEqualToString:@"disambiguation"]) {
        return nil;
    }

    NSString *extract = response[@"extract"];
    if (![extract isKindOfClass:[NSString class]]) return nil;

    extract = [extract stringByTrimmingCharactersInSet:
               [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return extract.length > 0 ? extract : nil;
}

@end
