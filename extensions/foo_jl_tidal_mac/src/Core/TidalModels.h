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
@property (nonatomic, copy, readonly, nullable) NSString *albumArtist;
@property (nonatomic, readonly) NSInteger duration;  // seconds
@property (nonatomic, readonly) NSInteger trackNumber;
@property (nonatomic, readonly) NSInteger discNumber;
@property (nonatomic, copy, readonly, nullable) NSURL *albumArtURL;
@property (nonatomic, copy, readonly, nullable) NSString *coverID;
@property (nonatomic, readonly) BOOL isExplicit;
@property (nonatomic, copy, readonly, nullable) NSString *audioQuality;
@property (nonatomic, copy, readonly, nullable) NSString *isrc;
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
