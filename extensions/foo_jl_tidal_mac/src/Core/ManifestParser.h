//
//  ManifestParser.h
//  foo_jl_tidal_mac
//
//  Pure parsing of Tidal playbackinfo manifests (BTS/JSON and DASH MPD).
//  Foundation-only — no foobar2000 SDK, no config, no network — so it
//  compiles standalone and is unit-tested (Tests/ManifestParserTests.mm).
//  Keep it that way: host concerns (config gates, console dumps) belong
//  to the caller (JLTidalPlaybackInfo).
//
//  DASH semantics mirror python-tidal DashInfo (tidalapi/media.py):
//    - Segment count = 1 + 1 (init + first media) + sum(r ?: 1) over
//      SegmentTimeline <S> elements
//    - $Number$ iterates from 0; media[$Number$=0] IS the init segment
//

#pragma once

#import <Foundation/Foundation.h>
#import "../API/TidalConstants.h"

NS_ASSUME_NONNULL_BEGIN

/// Result of decoding one base64 playbackinfo manifest. Always non-nil;
/// fields stay at their defaults when the manifest is undecodable.
@interface JLTidalManifestResult : NSObject

@property (nonatomic, copy, nullable) NSURL *streamURL;
@property (nonatomic) BOOL drmProtected;

/// DASH SegmentTemplate media URL template (contains $Number$), with the
/// total segment count including the init segment at $Number$=0.
@property (nonatomic, copy, nullable) NSString *dashMediaTemplate;
@property (nonatomic) NSInteger dashSegmentCount;

/// Canonical codec (FLAC/MP4A/EAC3/AC4) normalized from the DASH
/// Representation codecs attribute; nil when absent or unrecognized.
@property (nonatomic, copy, nullable) NSString *normalizedCodec;

/// Decoded MPD XML, populated only for DASH manifests (for diagnostics).
@property (nonatomic, copy, nullable) NSString *rawDASHManifest;

@end

@interface JLTidalManifestParser : NSObject

/// Decode and parse a manifest. base64Manifest is the "manifest" field of
/// the playbackinfo response, mimeType its "manifestMimeType".
+ (JLTidalManifestResult *)parseManifest:(NSString *)base64Manifest
                                mimeType:(nullable NSString *)mimeType;

/// Map an API audioQuality string to the quality enum; returns fallback
/// when the string is nil or unrecognized.
+ (JLTidalQuality)qualityFromString:(nullable NSString *)audioQuality
                           fallback:(JLTidalQuality)fallback;

@end

NS_ASSUME_NONNULL_END
