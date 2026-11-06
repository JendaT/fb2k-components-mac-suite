//
//  GalleryCacheKeys.mm
//  foo_jl_biography_mac
//
//  Cache-key derivation for the artist image cache
//

#import "GalleryCacheKeys.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *HexSHA256(NSString *input) {
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];

    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);

    NSMutableString *hashString = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hashString appendFormat:@"%02x", hash[i]];
    }
    return hashString;
}

@implementation GalleryCacheKeys

+ (NSString *)keyForImageURL:(NSURL *)url thumbnail:(BOOL)thumbnail {
    NSString *suffix = thumbnail ? @"_thumb" : @"_full";
    return [HexSHA256(url.absoluteString) stringByAppendingString:suffix];
}

+ (NSString *)keyForArtist:(NSString *)artistName {
    // Normalize artist name for cache key
    NSString *normalized = [[artistName lowercaseString]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [HexSHA256(normalized) stringByAppendingString:@"_gallery"];
}

@end
