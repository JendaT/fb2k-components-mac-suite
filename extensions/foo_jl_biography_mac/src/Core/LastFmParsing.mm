//
//  LastFmParsing.mm
//  foo_jl_biography_mac
//
//  Pure parsing/sanitization of Last.fm artist.getinfo responses
//

#import "LastFmParsing.h"
#import "BiographyData.h"
#import "../API/BiographyAPIConstants.h"

@implementation LastFmParsing

+ (NSDictionary *)parseArtistInfoResponse:(NSDictionary *)response {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    // Artist name (may be corrected)
    result[@"name"] = response[@"name"] ?: @"";

    // MusicBrainz ID
    if (response[@"mbid"] && [response[@"mbid"] length] > 0) {
        result[@"mbid"] = response[@"mbid"];
    }

    // Biography
    NSDictionary *bio = response[@"bio"];
    if (bio) {
        NSString *content = bio[@"content"];
        NSString *summary = bio[@"summary"];

        // Clean up HTML from biography
        if (content.length > 0) {
            result[@"biography"] = [self cleanBiographyText:content];
        }
        if (summary.length > 0) {
            result[@"biographySummary"] = [self cleanBiographyText:summary];
        }
    }

    // Tags (SEC-6: guard intermediate access)
    NSDictionary *tagsContainer = response[@"tags"];
    NSArray *tags = [tagsContainer isKindOfClass:[NSDictionary class]] ? tagsContainer[@"tag"] : nil;
    if ([tags isKindOfClass:[NSArray class]] && tags.count > 0) {
        NSMutableArray *tagNames = [NSMutableArray array];
        for (NSDictionary *tag in tags) {
            if ([tag isKindOfClass:[NSDictionary class]] && tag[@"name"]) {
                [tagNames addObject:tag[@"name"]];
            }
        }
        result[@"tags"] = [tagNames copy];
    }

    // Images (get largest available)
    NSArray *images = response[@"image"];
    if ([images isKindOfClass:[NSArray class]]) {
        NSURL *imageURL = nil;
        for (NSDictionary *image in [images reverseObjectEnumerator]) {
            NSString *urlString = image[@"#text"];
            if (urlString.length > 0) {
                imageURL = [NSURL URLWithString:urlString];
                if (imageURL) break;
            }
        }
        if (imageURL) {
            result[@"imageURL"] = imageURL;
        }
    }

    // Stats
    NSDictionary *stats = response[@"stats"];
    if (stats) {
        result[@"listeners"] = @([stats[@"listeners"] integerValue]);
        result[@"playcount"] = @([stats[@"playcount"] integerValue]);
    }

    // Similar artists (if included) (SEC-6: guard intermediate access)
    NSDictionary *similarContainer = response[@"similar"];
    NSArray *similar = [similarContainer isKindOfClass:[NSDictionary class]] ? similarContainer[@"artist"] : nil;
    if ([similar isKindOfClass:[NSArray class]]) {
        result[@"similarArtists"] = similar;
    }

    return [result copy];
}

+ (NSString *)cleanBiographyText:(NSString *)text {
    if (!text) return nil;

    // SEC-8: Cap text length to prevent oversized API responses from filling cache
    static const NSUInteger kMaxBiographyLength = 50000;
    if (text.length > kMaxBiographyLength) {
        text = [text substringToIndex:kMaxBiographyLength];
    }

    // Cache regex (PERF-8)
    static NSRegularExpression *htmlRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        htmlRegex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>"
                                                             options:0
                                                               error:nil];
    });

    // Decode HTML entities FIRST, then strip tags (SEC-4: prevents &lt;script&gt; bypass)
    NSString *decoded = text;
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
    decoded = [decoded stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];

    // Remove HTML tags after entity decode
    NSString *cleaned = [htmlRegex stringByReplacingMatchesInString:decoded
                                                            options:0
                                                              range:NSMakeRange(0, decoded.length)
                                                       withTemplate:@""];

    // Trim whitespace
    cleaned = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Remove "Read more on Last.fm" suffix
    NSRange readMoreRange = [cleaned rangeOfString:@"Read more on Last.fm"
                                           options:NSCaseInsensitiveSearch | NSBackwardsSearch];
    if (readMoreRange.location != NSNotFound) {
        cleaned = [[cleaned substringToIndex:readMoreRange.location]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    return cleaned;
}

+ (BiographyData *)biographyDataFromArtistInfoResponse:(NSDictionary *)response
                                            artistName:(NSString *)artistName {

    NSDictionary *parsed = [self parseArtistInfoResponse:response];

    BiographyDataBuilder *builder = [[BiographyDataBuilder alloc] initWithArtistName:artistName];

    // Use corrected name if available
    if ([parsed[@"name"] length] > 0) {
        builder.artistName = parsed[@"name"];
    }

    builder.musicBrainzId = parsed[@"mbid"];
    builder.biography = parsed[@"biography"];
    builder.biographySummary = parsed[@"biographySummary"];
    builder.biographySource = BiographySourceLastFm;
    builder.language = @"en";

    // Image URL (will need to be downloaded separately)
    // Skip Last.fm default placeholder (star icon) - hash 2a96cbd8b46e442fc41c2b86b821562f
    NSURL *imageURL = parsed[@"imageURL"];
    if (imageURL && ![imageURL.absoluteString containsString:kLastFmPlaceholderHash]) {
        builder.artistImageURL = imageURL;
        builder.imageSource = BiographySourceLastFm;
        builder.imageType = BiographyImageTypeThumb;
    }

    // Tags
    builder.tags = parsed[@"tags"];

    // Stats
    builder.listeners = [parsed[@"listeners"] unsignedIntegerValue];
    builder.playcount = [parsed[@"playcount"] unsignedIntegerValue];

    // Similar artists
    NSArray *similarRaw = parsed[@"similarArtists"];
    if (similarRaw.count > 0) {
        NSMutableArray<SimilarArtistRef *> *similar = [NSMutableArray array];
        for (NSDictionary *artistDict in similarRaw) {
            NSString *name = artistDict[@"name"];
            if (name.length > 0) {
                NSURL *thumbURL = nil;
                NSArray *images = artistDict[@"image"];
                if ([images isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *img in images) {
                        if ([img[@"size"] isEqualToString:@"medium"]) {
                            NSString *urlStr = img[@"#text"];
                            if (urlStr.length > 0) {
                                thumbURL = [NSURL URLWithString:urlStr];
                            }
                            break;
                        }
                    }
                }

                SimilarArtistRef *ref = [[SimilarArtistRef alloc] initWithName:name
                                                                  thumbnailURL:thumbURL
                                                                 musicBrainzId:artistDict[@"mbid"]];
                [similar addObject:ref];
            }
        }
        builder.similarArtists = [similar copy];
    }

    builder.fetchedAt = [NSDate date];
    builder.isFromCache = NO;
    builder.isStale = NO;

    return [builder build];
}

@end
