//
//  ScrobbleService.h
//  foo_scrobble_mac
//
//  Main scrobbling service - coordinates queue processing and API calls
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ScrobbleTrack;

/// Service state machine
typedef NS_ENUM(NSInteger, ScrobbleServiceState) {
    ScrobbleServiceStateUnauthenticated,  // No session - cannot scrobble
    ScrobbleServiceStateIdle,             // Ready, no pending work
    ScrobbleServiceStateProcessing,       // Request in flight
    ScrobbleServiceStateSleeping,         // Rate limited - waiting to retry
    ScrobbleServiceStateSuspended,        // API key issue - paused
    ScrobbleServiceStateShuttingDown,     // Graceful shutdown in progress
    ScrobbleServiceStateShutDown          // Component unloaded
};

/// Notifications
extern NSNotificationName const ScrobbleServiceStateDidChangeNotification;
extern NSNotificationName const ScrobbleServiceDidScrobbleNotification;
extern NSNotificationName const ScrobbleServiceDidFailNotification;

@interface ScrobbleService : NSObject

/// Shared service instance
+ (instancetype)shared;

/// Current service state
@property (nonatomic, readonly) ScrobbleServiceState state;

/// Number of pending scrobbles
@property (nonatomic, readonly) NSUInteger pendingCount;

/// Number of scrobbles in flight
@property (nonatomic, readonly) NSUInteger inFlightCount;

/// Total scrobbles submitted this session
@property (nonatomic, readonly) NSUInteger sessionScrobbleCount;

#pragma mark - Lifecycle

/// Start the service (call on component init)
- (void)start;

/// Stop the service gracefully (call on component quit)
- (void)stop;

#pragma mark - Scrobbling

/// Queue a track for scrobbling
- (void)queueTrack:(ScrobbleTrack*)track;

/// Queue a track and write the queue to disk before returning, without
/// submitting it. For playback stopping at shutdown: queueTrack: submits
/// asynchronously, which does not finish before the process exits, and a
/// track already handed to a submission is not part of the saved queue.
/// The track is submitted on the next launch. Safe to call from any thread.
- (void)queueTrackForShutdown:(ScrobbleTrack*)track;

/// Process pending queue now (if possible)
- (void)processQueue;

#pragma mark - Now Playing

/// Send Now Playing notification
- (void)sendNowPlaying:(ScrobbleTrack*)track;

/// Clear Now Playing state (call on playback stop)
- (void)clearNowPlaying;

@end

NS_ASSUME_NONNULL_END
