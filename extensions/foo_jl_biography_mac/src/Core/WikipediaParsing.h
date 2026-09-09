//
//  WikipediaParsing.h
//  foo_jl_biography_mac
//
//  Pure parsing of Wikidata sitelink and Wikipedia REST summary responses.
//  Contains NO foobar2000 SDK dependency and NO networking code.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WikipediaParsing : NSObject

/// Extract the English Wikipedia article title from a wbgetentities response
/// (props=sitelinks&sitefilter=enwiki). Returns nil when no enwiki sitelink exists.
+ (nullable NSString *)enwikiTitleFromWikidataResponse:(NSDictionary *)response;

/// Extract the plain-text summary from a Wikipedia REST /page/summary response.
/// Rejects disambiguation pages and empty extracts.
+ (nullable NSString *)summaryExtractFromResponse:(NSDictionary *)response;

@end

NS_ASSUME_NONNULL_END
