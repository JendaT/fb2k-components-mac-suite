//
//  TidalModels.h
//  foo_jl_tidal_mac
//
//  Data models for Tidal tracks and playback info
//

#pragma once

#import <Foundation/Foundation.h>
#import "../API/TidalConstants.h"

NS_ASSUME_NONNULL_BEGIN

/// Track metadata model
@interface JLTidalTrack : NSObject

@property (nonatomic, copy, readonly) NSString *trackID;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *artist;
@property (nonatomic, copy, readonly, nullable) NSString *album;
@property (nonatomic, copy, readonly, nullable) NSString *albumID;  // for "Go to Album"
@property (nonatomic, copy, readonly, nullable) NSString *albumArtist;
@property (nonatomic, readonly) NSInteger duration;  // seconds
@property (nonatomic, readonly) NSInteger trackNumber;
@property (nonatomic, readonly) NSInteger discNumber;
@property (nonatomic, copy, readonly, nullable) NSURL *albumArtURL;
@property (nonatomic, copy, readonly, nullable) NSString *coverID;
@property (nonatomic, readonly) BOOL isExplicit;

/// Availability, as reported by the catalogue. A region-restricted, withdrawn
/// or not-yet-released track is listed normally but cannot be streamed; every
/// other client gates on these before asking for a stream. Default YES so an
/// absent field never hides a playable track.
@property (nonatomic, readonly) BOOL allowStreaming;
@property (nonatomic, readonly) BOOL streamReady;

/// Edition suffix ("Live", "Remastered", "Kasper Bjorke Remix"...). Without
/// it "Song" and "Song (Live)" are indistinguishable in a playlist.
@property (nonatomic, copy, readonly, nullable) NSString *version;

/// The title as it should be shown and tagged: "Title (Version)", or just
/// the title when there is no version or the title already carries it. Every
/// remix on a remix album otherwise reads as the same song.
@property (nonatomic, copy, readonly) NSString *displayTitle;

/// Every credited artist, in response order. `artist` is just the first.
@property (nonatomic, copy, readonly, nullable) NSArray<NSString *> *allArtists;

/// Track-level ReplayGain from the catalogue (dB) and peak amplitude.
/// `hasReplayGain` is NO when the response carried neither.
@property (nonatomic, readonly) BOOL hasReplayGain;
@property (nonatomic, readonly) double replayGain;
@property (nonatomic, readonly) double peakAmplitude;
@property (nonatomic, copy, readonly, nullable) NSString *audioQuality;

/// Formats Tidal actually holds for this track ("LOSSLESS", "HIRES_LOSSLESS",
/// "MQA", ...). More truthful than audioQuality, which reports the release's
/// nominal quality even when only a lossy master is streamable. Nil when the
/// response carried no mediaMetadata at all.
@property (nonatomic, copy, readonly, nullable) NSArray<NSString *> *mediaTags;
@property (nonatomic, copy, readonly, nullable) NSString *isrc;
/// Tempo and key from the catalogue. bpm is 0 and key/keyScale nil when the
/// catalogue has none ("UNKNOWN" counts as none). key is TIDAL's spelling
/// ("C", "CSharp", "Eb"...), keyScale "MAJOR", "MINOR" or a mode name.
@property (nonatomic, readonly) double bpm;
@property (nonatomic, copy, readonly, nullable) NSString *key;
@property (nonatomic, copy, readonly, nullable) NSString *keyScale;
@property (nonatomic, copy, readonly, nullable) NSString *copyright;
@property (nonatomic, copy, readonly, nullable) NSDate *releaseDate;
@property (nonatomic, readonly) NSInteger totalTracks;  // from album.numberOfTracks

- (instancetype)initWithDictionary:(NSDictionary *)dict;

@end

/// Stream playback info model
@interface JLTidalPlaybackInfo : NSObject

@property (nonatomic, copy, readonly) NSString *trackID;
@property (nonatomic, copy, readonly) NSURL *streamURL;
@property (nonatomic, copy, readonly, nullable) NSString *manifestMimeType;
@property (nonatomic, copy, readonly, nullable) NSString *manifest;
@property (nonatomic, readonly) JLTidalQuality quality;
@property (nonatomic, readonly) NSInteger bitDepth;
@property (nonatomic, readonly) NSInteger sampleRate;
@property (nonatomic, copy, readonly, nullable) NSString *codec;
@property (nonatomic, readonly, getter=isDRMProtected) BOOL drmProtected;

/// ReplayGain the stream response carries. fb2k normalises local files and
/// would otherwise leave TIDAL streams un-normalised in the same playlist.
@property (nonatomic, readonly) BOOL hasReplayGain;
@property (nonatomic, readonly) double trackReplayGain;
@property (nonatomic, readonly) double trackPeakAmplitude;
@property (nonatomic, readonly) BOOL hasAlbumReplayGain;
@property (nonatomic, readonly) double albumReplayGain;
@property (nonatomic, readonly) double albumPeakAmplitude;

/// YES when TIDAL returned a ~30s sample instead of the full track
/// (assetPresentation != "FULL"). Absent is treated as PREVIEW, matching
/// tidal-sdk-web: only an explicit FULL counts as the full asset.
@property (nonatomic, readonly, getter=isPreviewOnly) BOOL previewOnly;

/// Server's reason for a preview, e.g. "FULL_REQUIRES_SUBSCRIPTION". Nil
/// when the response carried none.
@property (nonatomic, copy, readonly, nullable) NSString *previewReason;

// DASH (segment-based streaming). Populated only when the API returns a DASH
// manifest with a SegmentTemplate (typically LOSSLESS/HiRes). When populated,
// streamURL will be nil — the decoder substitutes $Number$ = 0..(dashSegmentCount-1)
// into dashMediaTemplate to assemble a playable fMP4. Tidal's URL scheme treats
// media[$Number$=0] AS the initialization segment, so no separate init download
// is needed (see python-tidal DashInfo.get_urls).
@property (nonatomic, copy, readonly, nullable) NSString *dashMediaTemplate;  // contains $Number$
@property (nonatomic, readonly) NSInteger dashSegmentCount;
// Track length in dashTimescale units (the sample count, as Tidal sets the
// timescale to the sample rate); 0 when unknown.
@property (nonatomic, readonly) int64_t dashTotalDuration;
@property (nonatomic, readonly) NSInteger dashTimescale;

// Decoded MPD XML, populated only for DASH manifests. Diagnostics only —
// the resolver dumps it to the console when DASH is enabled in prefs.
@property (nonatomic, copy, readonly, nullable) NSString *rawDASHManifest;

- (instancetype)initWithDictionary:(NSDictionary *)dict
                           trackID:(NSString *)trackID
                   requestedQuality:(JLTidalQuality)requestedQuality;

/// Quality string for display/metadata
@property (nonatomic, copy, readonly) NSString *qualityDescription;

@end

/// Album metadata model
@interface JLTidalAlbum : NSObject

@property (nonatomic, copy, readonly) NSString *albumID;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *artist;
@property (nonatomic, copy, readonly, nullable) NSString *coverID;
@property (nonatomic, readonly) NSInteger numberOfTracks;
@property (nonatomic, readonly) NSInteger duration;  // total seconds
@property (nonatomic, copy, readonly, nullable) NSString *audioQuality;
@property (nonatomic, copy, readonly, nullable) NSDate *releaseDate;

- (instancetype)initWithDictionary:(NSDictionary *)dict;

@end

/// Artist metadata model
@interface JLTidalArtist : NSObject

@property (nonatomic, copy, readonly) NSString *artistID;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSString *pictureID;

- (instancetype)initWithDictionary:(NSDictionary *)dict;

@end

/// Playlist metadata model
@interface JLTidalPlaylist : NSObject

@property (nonatomic, copy, readonly) NSString *playlistUUID;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly, nullable) NSString *playlistDescription;
@property (nonatomic, readonly) NSInteger numberOfTracks;
@property (nonatomic, readonly) NSInteger duration;  // total seconds
@property (nonatomic, copy, readonly, nullable) NSString *coverID;
@property (nonatomic, copy, readonly, nullable) NSDate *lastUpdated;
@property (nonatomic, copy, nullable) NSString *etag;

- (instancetype)initWithDictionary:(NSDictionary *)dict;

@end

/// Playlist folder model (from v2 API)
@interface JLTidalPlaylistFolder : NSObject

@property (nonatomic, copy, readonly) NSString *folderID;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSString *parentFolderID;
@property (nonatomic, strong, readonly) NSMutableArray<JLTidalPlaylistFolder *> *subfolders;
@property (nonatomic, strong, readonly) NSMutableArray<NSString *> *playlistUUIDs;

- (instancetype)initWithDictionary:(NSDictionary *)dict;

@end

/// Cached stream entry
@interface JLTidalStreamCacheEntry : NSObject

@property (nonatomic, strong, readonly) JLTidalPlaybackInfo *playbackInfo;
@property (nonatomic, strong, readonly) NSDate *expiresAt;
@property (nonatomic, readonly, getter=isExpired) BOOL expired;

- (instancetype)initWithPlaybackInfo:(JLTidalPlaybackInfo *)info
                                 ttl:(NSTimeInterval)ttl;

@end

NS_ASSUME_NONNULL_END
