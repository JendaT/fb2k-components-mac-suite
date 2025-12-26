//
//  ScrobbleTrack.h
//  foo_scrobble_mac
//
//  Track model for scrobbling
//

#pragma once

#import <Foundation/Foundation.h>

/// Status of a track in the scrobble queue
typedef NS_ENUM(NSInteger, ScrobbleTrackStatus) {
    ScrobbleTrackStatusQueued,      // Waiting to be submitted
    ScrobbleTrackStatusInFlight,    // Currently being submitted
    ScrobbleTrackStatusSubmitted,   // Successfully submitted
    ScrobbleTrackStatusFailed       // Submission failed
};

@interface ScrobbleTrack : NSObject <NSSecureCoding, NSCopying>

// Required fields
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *title;

// Optional fields
@property (nonatomic, copy, nullable) NSString *album;
@property (nonatomic, copy, nullable) NSString *albumArtist;
@property (nonatomic) NSInteger trackNumber;
@property (nonatomic, copy, nullable) NSString *mbTrackId;  // MusicBrainz Track ID

// Timing
@property (nonatomic) NSInteger duration;  // Track duration in seconds
@property (nonatomic) int64_t timestamp;   // Unix timestamp when playback started

// Submission tracking
@property (nonatomic, copy) NSString *submissionId;  // UUID for deduplication
@property (nonatomic) ScrobbleTrackStatus status;
@property (nonatomic) NSInteger retryCount;
@property (nonatomic, copy, nullable) NSString *lastError;

/// Initialize with required fields
- (instancetype)initWithArtist:(NSString *)artist
                         title:(NSString *)title
                      duration:(NSInteger)duration;

/// Check if track has valid required fields
- (BOOL)isValid;

/// Generate deduplication key (artist|title|timestamp)
- (NSString *)deduplicationKey;

/// Human-readable description (Artist - Title)
- (NSString *)displayDescription;

@end
