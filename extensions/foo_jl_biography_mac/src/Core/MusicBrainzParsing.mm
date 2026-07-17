//
//  MusicBrainzParsing.mm
//  foo_jl_biography_mac
//
//  Pure parsing of MusicBrainz ws/2 responses
//

#import "MusicBrainzParsing.h"
#import "ArtistNameMatcher.h"
#import "GalleryImageParsing.h"

// Below this search score MusicBrainz matches are too fuzzy to trust
static const NSInteger kMinAcceptableScore = 90;

@implementation MusicBrainzParsing

+ (NSString *)bestMBIDFromSearchResponse:(NSDictionary *)response
                           requestedName:(NSString *)requestedName {
    if (![response isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *artists = response[@"artists"];
    if (![artists isKindOfClass:[NSArray class]]) return nil;

    for (NSDictionary *artist in artists) {
        if (![artist isKindOfClass:[NSDictionary class]]) continue;

        id scoreValue = artist[@"score"];
        NSInteger score = [scoreValue respondsToSelector:@selector(integerValue)]
            ? [scoreValue integerValue] : 0;
        if (score < kMinAcceptableScore) continue;

        NSString *name = artist[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        if (![ArtistNameMatcher name:name matchesRequested:requestedName]) continue;

        NSString *mbid = artist[@"id"];
        if ([GalleryImageParsing isValidMBID:mbid]) {
            return mbid;
        }
    }

    return nil;
}

+ (NSString *)wikidataQIDFromArtistResponse:(NSDictionary *)response {
    if (![response isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *relations = response[@"relations"];
    if (![relations isKindOfClass:[NSArray class]]) return nil;

    for (NSDictionary *relation in relations) {
        if (![relation isKindOfClass:[NSDictionary class]]) continue;
        if (![relation[@"type"] isKindOfClass:[NSString class]]) continue;
        if (![relation[@"type"] isEqualToString:@"wikidata"]) continue;

        NSDictionary *urlDict = relation[@"url"];
        if (![urlDict isKindOfClass:[NSDictionary class]]) continue;
        NSString *resource = urlDict[@"resource"];
        if (![resource isKindOfClass:[NSString class]]) continue;

        // e.g. https://www.wikidata.org/wiki/Q11647
        NSString *qid = [[NSURL URLWithString:resource] lastPathComponent];
        if ([self isValidQID:qid]) {
            return qid;
        }
    }

    return nil;
}

+ (BOOL)isValidQID:(NSString *)qid {
    if (![qid isKindOfClass:[NSString class]] || qid.length < 2) return NO;
    if (![qid hasPrefix:@"Q"]) return NO;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    NSString *digits = [qid substringFromIndex:1];
    return [digits rangeOfCharacterFromSet:nonDigits].location == NSNotFound;
}

@end
