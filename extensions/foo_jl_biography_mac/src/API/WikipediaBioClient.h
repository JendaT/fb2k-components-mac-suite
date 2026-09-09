//
//  WikipediaBioClient.h
//  foo_jl_biography_mac
//
//  Fetches an artist biography from Wikipedia, resolved accurately via a
//  Wikidata entity ID (obtained from MusicBrainz url-rels) rather than by
//  guessing article titles. No API key required.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BiographyRequest;

/// Error domain for Wikipedia biography errors
extern NSString * const WikipediaBioErrorDomain;

typedef NS_ENUM(NSInteger, WikipediaBioErrorCode) {
    WikipediaBioErrorCodeUnknown = 0,
    WikipediaBioErrorCodeNetworkError = 1,
    WikipediaBioErrorCodeInvalidResponse = 2,
    WikipediaBioErrorCodeNoArticle = 3,
    WikipediaBioErrorCodeCancelled = 4,
};

/// Completion with the plain-text summary of the artist's English Wikipedia article
typedef void (^WikipediaBioCompletion)(NSString * _Nullable bioText, NSError * _Nullable error);

@interface WikipediaBioClient : NSObject

+ (instancetype)shared;

/// Fetch the article summary for a Wikidata entity (e.g. "Q11647"):
/// Wikidata sitelinks -> enwiki title -> REST /page/summary extract.
- (void)fetchBioForWikidataQID:(NSString *)qid
                         token:(BiographyRequest *)token
                    completion:(WikipediaBioCompletion)completion;

/// Cancel all pending requests
- (void)cancelAllRequests;

@end

NS_ASSUME_NONNULL_END
