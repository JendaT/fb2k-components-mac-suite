//
//  ManifestParser.mm
//  foo_jl_tidal_mac
//

#import "ManifestParser.h"
#include "TidalLog.h"

static NSRegularExpression *sharedDASHBaseURLRegex(void) {
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:
            @"<BaseURL>\\s*(https?://[^<]+?)\\s*</BaseURL>"
            options:0 error:nil];
    });
    return regex;
}

// Extract a single attribute value (e.g. initialization="...") from an XML tag.
static NSString *extractXMLAttr(NSString *tag, NSString *attr) {
    NSString *pattern = [NSString stringWithFormat:@"\\b%@\\s*=\\s*\"([^\"]*)\"", attr];
    NSError *err = nil;
    NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&err];
    if (!r) return nil;
    NSTextCheckingResult *m = [r firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (m && m.numberOfRanges > 1) {
        return [tag substringWithRange:[m rangeAtIndex:1]];
    }
    return nil;
}

// Walk every <S t=... d=... r=.../> element in a SegmentTimeline block and
// return the total segment count. Each S contributes (r ?: 1) segments; the
// caller adds the implicit init/first segment base of 2 (mirrors python-tidal
// DashInfo.get_urls).
static NSInteger countSegmentTimelineSElements(NSString *manifestStr) {
    if (manifestStr.length == 0) return 0;
    NSRange tlOpen = [manifestStr rangeOfString:@"<SegmentTimeline"];
    if (tlOpen.location == NSNotFound) return 0;
    NSRange tlClose = [manifestStr rangeOfString:@"</SegmentTimeline>"
                                          options:0
                                            range:NSMakeRange(tlOpen.location, manifestStr.length - tlOpen.location)];
    if (tlClose.location == NSNotFound) return 0;
    NSRange tlBody = NSMakeRange(NSMaxRange(tlOpen),
                                 tlClose.location - NSMaxRange(tlOpen));
    NSString *body = [manifestStr substringWithRange:tlBody];

    static NSRegularExpression *sElementRegex = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        sElementRegex = [NSRegularExpression regularExpressionWithPattern:@"<S\\b[^/>]*/?>"
                                                                  options:0
                                                                    error:nil];
    });
    __block NSInteger count = 0;
    [sElementRegex enumerateMatchesInString:body
                                    options:0
                                      range:NSMakeRange(0, body.length)
                                 usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        NSString *sTag = [body substringWithRange:m.range];
        NSString *rStr = extractXMLAttr(sTag, @"r");
        NSInteger r = rStr.length ? [rStr integerValue] : 0;
        count += (r > 0) ? r : 1;
    }];
    return count;
}

@implementation JLTidalManifestResult
@end

@implementation JLTidalManifestParser

+ (JLTidalQuality)qualityFromString:(NSString *)audioQuality
                           fallback:(JLTidalQuality)fallback {
    if ([audioQuality isEqualToString:@"HI_RES_LOSSLESS"]) return JLTidalQualityHiResLossless;
    if ([audioQuality isEqualToString:@"HI_RES"]) return JLTidalQualityHiRes;
    if ([audioQuality isEqualToString:@"LOSSLESS"]) return JLTidalQualityLossless;
    if ([audioQuality isEqualToString:@"HIGH"]) return JLTidalQualityHigh;
    if ([audioQuality isEqualToString:@"LOW"]) return JLTidalQualityLow;
    return fallback;
}

+ (JLTidalManifestResult *)parseManifest:(NSString *)base64Manifest
                                mimeType:(NSString *)mimeType {
    JLTidalManifestResult *result = [[JLTidalManifestResult alloc] init];

    // Both JSON (application/vnd.tidal.bts) and standard JSON manifests are
    // base64-encoded JSON with a "urls" array. DASH manifests are XML-based.
    BOOL isJSONManifest = !mimeType
        || [mimeType isEqualToString:@"application/vnd.tidal.bts"]
        || [mimeType containsString:@"json"];

    NSData *manifestData = [[NSData alloc] initWithBase64EncodedString:base64Manifest options:0];
    if (!manifestData) {
        tidal::logError([[NSString stringWithFormat:@"Failed to base64-decode manifest (type=%@)",
                          mimeType ?: @"(nil)"] UTF8String]);
        return result;
    }

    if (isJSONManifest) {
        [self parseJSONManifest:manifestData mimeType:mimeType into:result];
    } else if ([mimeType containsString:@"dash"] || [mimeType containsString:@"xml"]) {
        [self parseDASHManifest:manifestData into:result];
    } else {
        tidal::logError([[NSString stringWithFormat:@"Unknown manifest type: %@", mimeType] UTF8String]);
    }
    return result;
}

+ (void)parseJSONManifest:(NSData *)manifestData
                 mimeType:(NSString *)mimeType
                     into:(JLTidalManifestResult *)result {
    NSError *error;
    NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData
                                                                 options:0
                                                                   error:&error];
    if (!manifestDict) {
        tidal::logError([[NSString stringWithFormat:@"Failed to parse %@ manifest as JSON: %@",
                          mimeType, error.localizedDescription] UTF8String]);
        return;
    }

    // Check for actual DRM encryption; encryptionType "NONE" means no DRM.
    NSString *encryptionType = manifestDict[@"encryptionType"];
    NSString *keyId = manifestDict[@"keyId"];
    if (keyId.length > 0) {
        result.drmProtected = YES;
        tidal::logDebug([[NSString stringWithFormat:@"Manifest has DRM: keyId=%@", keyId] UTF8String]);
    } else if (encryptionType && ![encryptionType isEqualToString:@"NONE"]) {
        result.drmProtected = YES;
        tidal::logDebug([[NSString stringWithFormat:@"Manifest has DRM: encryptionType=%@", encryptionType] UTF8String]);
    } else {
        tidal::logDebug("Manifest: no DRM");
    }

    // Extract stream URL
    NSArray *urls = manifestDict[@"urls"];
    if ([urls isKindOfClass:[NSArray class]] && urls.count > 0) {
        NSString *urlStr = urls.firstObject;
        if ([urlStr isKindOfClass:[NSString class]]) {
            result.streamURL = [NSURL URLWithString:urlStr];
        }
    }

    if (!result.streamURL) {
        tidal::logError([[NSString stringWithFormat:@"No URLs in %@ manifest", mimeType] UTF8String]);
    }
}

+ (void)parseDASHManifest:(NSData *)manifestData
                     into:(JLTidalManifestResult *)result {
    NSString *manifestStr = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    result.rawDASHManifest = manifestStr;

    if (manifestStr && [manifestStr containsString:@"<ContentProtection"]) {
        result.drmProtected = YES;
        tidal::logDebug("DASH manifest has DRM (ContentProtection)");
    } else {
        tidal::logDebug("DASH manifest: no DRM");
    }

    if (manifestStr) {
        // 1) Try BaseURL — direct playable URL (oldest Tidal format)
        NSRegularExpression *regex = sharedDASHBaseURLRegex();
        NSTextCheckingResult *match = [regex firstMatchInString:manifestStr
            options:0 range:NSMakeRange(0, manifestStr.length)];
        if (match && match.numberOfRanges > 1) {
            NSString *urlStr = [manifestStr substringWithRange:[match rangeAtIndex:1]];
            result.streamURL = [NSURL URLWithString:urlStr];
            tidal::logDebug([[NSString stringWithFormat:@"DASH BaseURL: %@", urlStr] UTF8String]);
        }

        // 2) Try SegmentTemplate — segmented fMP4 (Tidal LOSSLESS / HiRes path).
        // Mirrors python-tidal DashInfo (tidalapi/media.py:824-859):
        //   - Segment count = 1 + 1 (init + first media) + sum(r ?: 1) over SegmentTimeline.S
        //   - $Number$ iterates from 0; media[0] IS the init segment (no separate download)
        if (!result.streamURL && !result.drmProtected) {
            NSRange tplRange = [manifestStr rangeOfString:@"<SegmentTemplate"];
            if (tplRange.location != NSNotFound) {
                NSRange endRange = [manifestStr rangeOfString:@"/>"
                                                       options:0
                                                         range:NSMakeRange(tplRange.location, manifestStr.length - tplRange.location)];
                if (endRange.location == NSNotFound) {
                    endRange = [manifestStr rangeOfString:@">"
                                                  options:0
                                                    range:NSMakeRange(tplRange.location, manifestStr.length - tplRange.location)];
                }
                if (endRange.location != NSNotFound) {
                    NSRange tagRange = NSMakeRange(tplRange.location,
                                                   endRange.location + endRange.length - tplRange.location);
                    NSString *tplTag = [manifestStr substringWithRange:tagRange];
                    NSString *mediaTpl = extractXMLAttr(tplTag, @"media");

                    // Segment count = base (2) + sum of SegmentTimeline S contributions.
                    NSInteger segCount = 1 + 1 + countSegmentTimelineSElements(manifestStr);

                    if (mediaTpl.length && [mediaTpl containsString:@"$Number$"] && segCount > 2) {
                        result.dashMediaTemplate = mediaTpl;
                        result.dashSegmentCount = segCount;
                        tidal::logInfo([[NSString stringWithFormat:
                            @"DASH SegmentTemplate: %ld segments (incl. init at $Number$=0)",
                            (long)segCount] UTF8String]);
                    } else {
                        tidal::logDebug([[NSString stringWithFormat:
                            @"DASH SegmentTemplate parse incomplete: media=%@ count=%ld",
                            mediaTpl ?: @"(nil)", (long)segCount] UTF8String]);
                    }
                }
            }

            // Normalise codec from <Representation codecs="..."> — Tidal reports
            // "flac", "mp4a.40.2", "mp4a.40.5" in DASH but FLAC/MP4A/MP4A as
            // simple names in BTS. We want one canonical form for downstream
            // MIME-type lookup. Mirrors python-tidal:644-655.
            NSRange repRange = [manifestStr rangeOfString:@"<Representation"];
            if (repRange.location != NSNotFound) {
                NSRange repEnd = [manifestStr rangeOfString:@">"
                                                    options:0
                                                      range:NSMakeRange(repRange.location, manifestStr.length - repRange.location)];
                if (repEnd.location != NSNotFound) {
                    NSString *repTag = [manifestStr substringWithRange:
                        NSMakeRange(repRange.location, repEnd.location + repEnd.length - repRange.location)];
                    NSString *dashCodec = extractXMLAttr(repTag, @"codecs");
                    if (dashCodec.length) {
                        NSString *lower = [dashCodec lowercaseString];
                        if ([lower containsString:@"flac"]) {
                            result.normalizedCodec = @"FLAC";
                        } else if ([lower hasPrefix:@"mp4a"]) {
                            result.normalizedCodec = @"MP4A";
                        } else if ([lower hasPrefix:@"ec-3"] || [lower hasPrefix:@"eac3"]) {
                            result.normalizedCodec = @"EAC3";
                        } else if ([lower hasPrefix:@"ac-4"] || [lower hasPrefix:@"ac4"]) {
                            result.normalizedCodec = @"AC4";
                        }
                    }
                }
            }
        }

        if (!result.streamURL && result.dashSegmentCount == 0) {
            tidal::logDebug("DASH manifest: no playable URL or SegmentTemplate, will fall back");
        }
    }
}

@end
