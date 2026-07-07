//
//  RecentTrack.h
//  foo_jl_scrobble_mac
//
//  Data model for Last.fm recent track (user.getRecentTracks)
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ScrobbleTrack;

@interface RecentTrack : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy, nullable) NSString *albumName;
@property (nonatomic, copy, nullable) NSURL *imageURL;
@property (nonatomic, copy, nullable) NSURL *lastfmURL;
@property (nonatomic, strong, nullable) NSDate *scrobbleDate;
@property (nonatomic, assign) BOOL isNowPlaying;

/// Create from user.getRecentTracks track dictionary
+ (nullable instancetype)trackFromDictionary:(NSDictionary *)dict;

/// Create a synthetic now-playing entry from local playback data
+ (instancetype)trackFromScrobbleTrack:(ScrobbleTrack *)scrobbleTrack;

/// Human-readable relative time string (e.g., "now", "2m ago", "1h ago", "3d ago")
- (NSString *)relativeTimeString;

/// Same as relativeTimeString, computed against an explicit reference date (testable)
- (NSString *)relativeTimeStringAtDate:(NSDate *)now;

@end

NS_ASSUME_NONNULL_END
