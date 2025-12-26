//
//  MD5.h
//  foo_scrobble_mac
//
//  MD5 hash function for Last.fm API request signing
//  Note: MD5 is required by Last.fm API specification.
//

#pragma once

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>

NS_INLINE NSString* MD5Hash(NSString *input) {
    // Note: MD5 is required by Last.fm API specification.
    // Suppress deprecation warning - we have no choice here.
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"

    const char *cStr = [input UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);

    #pragma clang diagnostic pop

    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output;
}
