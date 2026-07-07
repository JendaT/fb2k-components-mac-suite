//
//  ManifestParserTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for JLTidalManifestParser — BTS/JSON manifests, DASH MPD
//  SegmentTimeline math, DRM detection, and codec normalization. These pin
//  the v0.3.1 DASH semantics (python-tidal parity): segment count =
//  2 + sum(r ?: 1), media[$Number$=0] is the init segment.
//

#import <Foundation/Foundation.h>
#import "../src/Core/ManifestParser.h"
#include "TestHarness.h"

static NSString *b64(NSString *s) {
    return [[s dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
}

static JLTidalManifestResult *parse(NSString *manifest, NSString *mime) {
    return [JLTidalManifestParser parseManifest:b64(manifest) mimeType:mime];
}

static NSString *mpdWithTimeline(NSString *timeline, NSString *codecs, NSString *media) {
    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        @"<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"static\" "
        @"mediaPresentationDuration=\"PT212.0S\">"
        @"<Period id=\"0\"><AdaptationSet id=\"0\" contentType=\"audio\">"
        @"<Representation id=\"0\" codecs=\"%@\" bandwidth=\"1000000\">"
        @"<SegmentTemplate initialization=\"https://cdn.tidal.com/init.mp4\" "
        @"media=\"%@\" startNumber=\"1\" timescale=\"44100\">"
        @"<SegmentTimeline>%@</SegmentTimeline>"
        @"</SegmentTemplate>"
        @"</Representation></AdaptationSet></Period></MPD>",
        codecs, media, timeline];
}

static void testJSONManifests(void) {
    // Plain BTS manifest, no DRM, one URL
    JLTidalManifestResult *r = parse(
        @"{\"mimeType\":\"audio/flac\",\"urls\":[\"https://cdn.tidal.com/x.flac\"],"
        @"\"encryptionType\":\"NONE\"}",
        @"application/vnd.tidal.bts");
    CHECK_STREQ(r.streamURL.absoluteString, @"https://cdn.tidal.com/x.flac", "BTS url extracted");
    CHECK(!r.drmProtected, "encryptionType NONE is not DRM");
    CHECK_EQ(r.dashSegmentCount, (NSInteger)0, "BTS has no DASH segments");
    CHECK(r.dashMediaTemplate == nil, "BTS has no DASH template");
    CHECK(r.rawDASHManifest == nil, "BTS has no raw MPD");

    // nil mimeType is treated as JSON
    r = parse(@"{\"urls\":[\"https://cdn.tidal.com/y.m4a\"]}", nil);
    CHECK_STREQ(r.streamURL.absoluteString, @"https://cdn.tidal.com/y.m4a", "nil mime treated as JSON");
    CHECK(!r.drmProtected, "absent encryption fields are not DRM");

    // keyId present -> DRM
    r = parse(@"{\"urls\":[\"https://cdn.tidal.com/z.m4a\"],\"keyId\":\"abc123\"}",
              @"application/vnd.tidal.bts");
    CHECK(r.drmProtected, "keyId flags DRM");
    CHECK_STREQ(r.streamURL.absoluteString, @"https://cdn.tidal.com/z.m4a", "url still extracted with DRM");

    // Non-NONE encryptionType -> DRM
    r = parse(@"{\"urls\":[\"https://cdn.tidal.com/w.m4a\"],\"encryptionType\":\"OLD_AES\"}",
              @"application/vnd.tidal.bts");
    CHECK(r.drmProtected, "encryptionType OLD_AES flags DRM");

    // Missing urls array
    r = parse(@"{\"encryptionType\":\"NONE\"}", @"application/json");
    CHECK(r.streamURL == nil, "no urls -> nil streamURL");

    // urls present but not strings
    r = parse(@"{\"urls\":[42]}", nil);
    CHECK(r.streamURL == nil, "non-string url ignored");

    // Malformed JSON
    r = parse(@"{not json", @"application/vnd.tidal.bts");
    CHECK(r.streamURL == nil && !r.drmProtected, "malformed JSON -> empty result");
}

static void testInvalidBase64(void) {
    JLTidalManifestResult *r = [JLTidalManifestParser parseManifest:@"!!!not-base64!!!"
                                                           mimeType:@"application/vnd.tidal.bts"];
    CHECK(r != nil, "parser never returns nil");
    CHECK(r.streamURL == nil && !r.drmProtected && r.dashSegmentCount == 0,
          "undecodable manifest -> empty result");
}

static void testDASHSegmentCounting(void) {
    // r=139 contributes 139, S without r contributes 1, base of 2 => 142
    NSString *mpd = mpdWithTimeline(@"<S t=\"0\" d=\"176128\" r=\"139\"/><S d=\"171136\"/>",
                                    @"flac", @"https://cdn.tidal.com/seg_$Number$.mp4");
    JLTidalManifestResult *r = parse(mpd, @"application/dash+xml");
    CHECK_EQ(r.dashSegmentCount, (NSInteger)142, "segment count 2 + 139 + 1, got %ld", (long)r.dashSegmentCount);
    CHECK_STREQ(r.dashMediaTemplate, @"https://cdn.tidal.com/seg_$Number$.mp4", "media template extracted");
    CHECK(r.streamURL == nil, "segmented manifest has no direct URL");
    CHECK(!r.drmProtected, "no ContentProtection -> no DRM");
    CHECK(r.rawDASHManifest != nil, "raw MPD exposed for diagnostics");

    // r=0 and missing r each contribute 1: 2 + 1 + 1 + 1 = 5
    mpd = mpdWithTimeline(@"<S t=\"0\" d=\"100\" r=\"0\"/><S d=\"100\"/><S d=\"100\"/>",
                          @"flac", @"https://cdn.tidal.com/s_$Number$.mp4");
    r = parse(mpd, @"application/dash+xml");
    CHECK_EQ(r.dashSegmentCount, (NSInteger)5, "r=0 counts as 1, got %ld", (long)r.dashSegmentCount);

    // Single S with r=10: 2 + 10 = 12. Also exercise the xml mime alias.
    mpd = mpdWithTimeline(@"<S t=\"0\" d=\"100\" r=\"10\"/>",
                          @"flac", @"https://cdn.tidal.com/s_$Number$.mp4");
    r = parse(mpd, @"text/xml");
    CHECK_EQ(r.dashSegmentCount, (NSInteger)12, "xml mime routed to DASH, got %ld", (long)r.dashSegmentCount);

    // Empty timeline -> count stays 2, which fails the (> 2) sanity gate
    mpd = mpdWithTimeline(@"", @"flac", @"https://cdn.tidal.com/s_$Number$.mp4");
    r = parse(mpd, @"application/dash+xml");
    CHECK_EQ(r.dashSegmentCount, (NSInteger)0, "empty timeline rejected");
    CHECK(r.dashMediaTemplate == nil, "empty timeline -> no template");
}

static void testDASHTemplateValidation(void) {
    // media without $Number$ is rejected
    NSString *mpd = mpdWithTimeline(@"<S t=\"0\" d=\"100\" r=\"5\"/>",
                                    @"flac", @"https://cdn.tidal.com/static.mp4");
    JLTidalManifestResult *r = parse(mpd, @"application/dash+xml");
    CHECK(r.dashMediaTemplate == nil, "template without $Number$ rejected");
    CHECK_EQ(r.dashSegmentCount, (NSInteger)0, "no count without valid template");
}

static void testDASHDRM(void) {
    NSString *mpd = [NSString stringWithFormat:
        @"<?xml version=\"1.0\"?><MPD><Period><AdaptationSet>"
        @"<ContentProtection schemeIdUri=\"urn:uuid:widevine\"/>"
        @"<Representation codecs=\"flac\">"
        @"<SegmentTemplate media=\"https://cdn/s_$Number$.mp4\">"
        @"<SegmentTimeline><S d=\"100\" r=\"5\"/></SegmentTimeline>"
        @"</SegmentTemplate></Representation>"
        @"</AdaptationSet></Period></MPD>"];
    JLTidalManifestResult *r = parse(mpd, @"application/dash+xml");
    CHECK(r.drmProtected, "ContentProtection flags DRM");
    CHECK(r.dashMediaTemplate == nil, "DRM manifest skips SegmentTemplate extraction");
    CHECK(r.normalizedCodec == nil, "DRM manifest skips codec normalization");
}

static void testDASHBaseURL(void) {
    NSString *mpd =
        @"<?xml version=\"1.0\"?><MPD><Period><AdaptationSet><Representation>"
        @"<BaseURL> https://cdn.tidal.com/direct.flac </BaseURL>"
        @"</Representation></AdaptationSet></Period></MPD>";
    JLTidalManifestResult *r = parse(mpd, @"application/dash+xml");
    CHECK_STREQ(r.streamURL.absoluteString, @"https://cdn.tidal.com/direct.flac",
                "BaseURL extracted and trimmed");
    CHECK_EQ(r.dashSegmentCount, (NSInteger)0, "BaseURL path skips SegmentTemplate");
}

static void testCodecNormalization(void) {
    struct { NSString *raw; NSString *expected; } cases[] = {
        { @"flac",      @"FLAC" },
        { @"mp4a.40.2", @"MP4A" },
        { @"mp4a.40.5", @"MP4A" },
        { @"ec-3",      @"EAC3" },
        { @"ac-4",      @"AC4"  },
        { @"opus",      nil     },  // unrecognized stays nil
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        NSString *mpd = mpdWithTimeline(@"<S d=\"100\" r=\"3\"/>",
                                        cases[i].raw, @"https://cdn/s_$Number$.mp4");
        JLTidalManifestResult *r = parse(mpd, @"application/dash+xml");
        CHECK_STREQ(r.normalizedCodec, cases[i].expected,
                    "codec %s -> %s", cases[i].raw.UTF8String,
                    cases[i].expected ? cases[i].expected.UTF8String : "(nil)");
    }
}

static void testUnknownMimeType(void) {
    JLTidalManifestResult *r = parse(@"whatever", @"application/octet-stream");
    CHECK(r.streamURL == nil && r.dashSegmentCount == 0 && !r.drmProtected,
          "unknown mime -> empty result");
}

static void testQualityFromString(void) {
    CHECK_EQ([JLTidalManifestParser qualityFromString:@"HI_RES_LOSSLESS" fallback:JLTidalQualityLow],
             JLTidalQualityHiResLossless, "HI_RES_LOSSLESS");
    CHECK_EQ([JLTidalManifestParser qualityFromString:@"HI_RES" fallback:JLTidalQualityLow],
             JLTidalQualityHiRes, "HI_RES");
    CHECK_EQ([JLTidalManifestParser qualityFromString:@"LOSSLESS" fallback:JLTidalQualityLow],
             JLTidalQualityLossless, "LOSSLESS");
    CHECK_EQ([JLTidalManifestParser qualityFromString:@"HIGH" fallback:JLTidalQualityLow],
             JLTidalQualityHigh, "HIGH");
    CHECK_EQ([JLTidalManifestParser qualityFromString:@"LOW" fallback:JLTidalQualityHigh],
             JLTidalQualityLow, "LOW");
    CHECK_EQ([JLTidalManifestParser qualityFromString:@"MQA_MAGIC" fallback:JLTidalQualityHigh],
             JLTidalQualityHigh, "unknown string falls back");
    CHECK_EQ([JLTidalManifestParser qualityFromString:nil fallback:JLTidalQualityLossless],
             JLTidalQualityLossless, "nil falls back");
}

int main(void) {
    @autoreleasepool {
        testJSONManifests();
        testInvalidBase64();
        testDASHSegmentCounting();
        testDASHTemplateValidation();
        testDASHDRM();
        testDASHBaseURL();
        testCodecNormalization();
        testUnknownMimeType();
        testQualityFromString();
    }
    return testHarnessFinish("ManifestParser");
}
