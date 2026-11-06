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
    static NSMutableDictionary<NSString *, NSRegularExpression *> *regexCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regexCache = [NSMutableDictionary dictionary];
    });
    NSRegularExpression *r;
    @synchronized (regexCache) {
        r = regexCache[attr];
        if (!r) {
            NSString *pattern = [NSString stringWithFormat:@"\\b%@\\s*=\\s*\"([^\"]*)\"", attr];
            r = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
            if (r) regexCache[attr] = r;
        }
    }
    if (!r) return nil;
    NSTextCheckingResult *m = [r firstMatchInString:tag options:0 range:NSMakeRange(0, tag.length)];
    if (m && m.numberOfRanges > 1) {
        return [tag substringWithRange:[m rangeAtIndex:1]];
    }
    return nil;
}

// Hard ceiling on the declared segment count. A hostile manifest with e.g.
// <S r="2000000000"/> would otherwise drive ~2 billion URL strings and one
// giant assembly buffer; real tracks are a few hundred segments at most.
static const NSInteger kMaxDASHSegmentCount = 10000;

// Walk every <S t=... d=... r=.../> element in a SegmentTimeline block and
// return the total segment count. Each S contributes (r ?: 1) segments; the
// caller adds the implicit init/first segment base of 2 (mirrors python-tidal
// DashInfo.get_urls). Counting stops once kMaxDASHSegmentCount is exceeded.
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
        // Per DASH (ISO/IEC 23009-1), an <S> describes r+1 segments: r is the
        // count of ADDITIONAL repeats, not the total. r="-1" means "repeat to
        // the end of the period", which a static Tidal manifest never uses and
        // cannot be resolved without a period duration -- treat it as one.
        if (r < 0) r = 0;
        // Clamp each contribution so a huge r cannot overflow the sum
        if (r > kMaxDASHSegmentCount) r = kMaxDASHSegmentCount + 1;
        count += r + 1;
        if (count > kMaxDASHSegmentCount) {
            *stop = YES;  // clamp: caller treats the manifest as invalid
        }
    }];
    return count;
}

// Total timeline length in timescale units: each <S> covers d*(r+1). Returns 0
// when any <S> lacks a usable d, since a partial sum would understate it.
static int64_t sumSegmentTimelineDuration(NSString *manifestStr) {
    NSRange tlOpen = [manifestStr rangeOfString:@"<SegmentTimeline>"];
    if (tlOpen.location == NSNotFound) return 0;
    NSRange tlClose = [manifestStr rangeOfString:@"</SegmentTimeline>"
                                         options:0
                                           range:NSMakeRange(NSMaxRange(tlOpen),
                                                             manifestStr.length - NSMaxRange(tlOpen))];
    if (tlClose.location == NSNotFound) return 0;
    NSString *body = [manifestStr substringWithRange:NSMakeRange(NSMaxRange(tlOpen),
                                                                 tlClose.location - NSMaxRange(tlOpen))];
    NSRegularExpression *sElement = [NSRegularExpression regularExpressionWithPattern:@"<S\\b[^/>]*/?>"
                                                                              options:0
                                                                                error:nil];
    __block int64_t total = 0;
    __block BOOL valid = YES;
    [sElement enumerateMatchesInString:body
                               options:0
                                 range:NSMakeRange(0, body.length)
                            usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
        NSString *sTag = [body substringWithRange:m.range];
        long long d = [extractXMLAttr(sTag, @"d") longLongValue];
        NSString *rStr = extractXMLAttr(sTag, @"r");
        long long r = rStr.length ? [rStr longLongValue] : 0;
        if (d <= 0 || r < 0 || r > kMaxDASHSegmentCount) {
            valid = NO;
            *stop = YES;
            return;
        }
        total += (int64_t)d * (int64_t)(r + 1);
    }];
    return valid ? total : 0;
}

// One codec vocabulary for both manifest flavours. Previously only the DASH
// branch normalised, so a BTS response left info.codec nil -- and the library
// export then wrote a FLAC stream to a .m4a file.
static NSString *normalizeCodecToken(NSString *token) {
    if (token.length == 0) return nil;
    NSString *lower = [token lowercaseString];
    if ([lower containsString:@"flac"]) return @"FLAC";
    if ([lower containsString:@"mp4a"] || [lower containsString:@"aac"] ||
        [lower containsString:@"m4a"]) return @"MP4A";
    if ([lower containsString:@"ec-3"] || [lower containsString:@"eac3"]) return @"EAC3";
    if ([lower containsString:@"ac-4"] || [lower containsString:@"ac4"]) return @"AC4";
    if ([lower containsString:@"alac"]) return @"ALAC";
    if ([lower containsString:@"mqa"]) return @"MQA";
    return nil;
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

    // The BTS manifest names its own codec; playbackinfopostpaywall does not
    // return a top-level "codec" key, so this is the only source for it.
    NSString *codecs = manifestDict[@"codecs"];
    if (![codecs isKindOfClass:[NSString class]]) codecs = nil;
    NSString *btsMime = manifestDict[@"mimeType"];
    if (![btsMime isKindOfClass:[NSString class]]) btsMime = nil;
    NSString *normalized = normalizeCodecToken(codecs) ?: normalizeCodecToken(btsMime);
    if (normalized) {
        result.normalizedCodec = normalized;
        tidal::logDebug([[NSString stringWithFormat:@"BTS manifest codec: %@ -> %@",
                          codecs ?: btsMime, normalized] UTF8String]);
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

                    // URL count = 1 init segment (Tidal serves it at $Number$=0)
                    // plus every media segment the timeline describes.
                    //
                    // The previous formula added `r` rather than `r+1` per <S>
                    // and compensated with a base of 2. That is exact only when
                    // exactly one <S> carries r>0 -- the ordinary shape, which
                    // is why it survived. With none (a track shorter than about
                    // two segments, so every <S> stands alone) it asked for one
                    // URL too many: the extra GET 404s and the whole assembled
                    // blob was discarded, failing short tracks deterministically.
                    // With two or more it asked for too few and silently
                    // truncated the tail.
                    NSInteger segCount = 1 + countSegmentTimelineSElements(manifestStr);

                    if (segCount > kMaxDASHSegmentCount) {
                        tidal::logError([[NSString stringWithFormat:
                            @"DASH manifest declares more than %ld segments; treating as invalid",
                            (long)kMaxDASHSegmentCount] UTF8String]);
                        segCount = 0;  // falls through to the incomplete branch below
                    }

                    // segCount == 1 means a template with no timeline behind it
                    // (nothing but the init segment), which is not playable.
                    if (mediaTpl.length && [mediaTpl containsString:@"$Number$"] && segCount > 1) {
                        result.dashMediaTemplate = mediaTpl;
                        result.dashSegmentCount = segCount;
                        result.dashTimescale = [extractXMLAttr(tplTag, @"timescale") integerValue];
                        result.dashTotalDuration = sumSegmentTimelineDuration(manifestStr);
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
                    NSString *normalizedDash = normalizeCodecToken(dashCodec);
                    if (normalizedDash) result.normalizedCodec = normalizedDash;
                }
            }
        }

        if (!result.streamURL && result.dashSegmentCount == 0) {
            tidal::logDebug("DASH manifest: no playable URL or SegmentTemplate, will fall back");
        }
    }
}

@end
