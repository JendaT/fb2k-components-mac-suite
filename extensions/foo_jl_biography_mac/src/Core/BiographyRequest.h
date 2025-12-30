//
//  BiographyRequest.h
//  foo_jl_biography_mac
//
//  Cancellation token for in-flight requests
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Cancellation token for in-flight biography requests.
/// Create one per fetch operation to enable cooperative cancellation.
@interface BiographyRequest : NSObject

/// The artist name this request is for
@property (nonatomic, copy, readonly) NSString *artistName;

/// Whether this request has been cancelled
@property (nonatomic, assign, readonly, getter=isCancelled) BOOL cancelled;

/// When this request was started
@property (nonatomic, strong, readonly) NSDate *startedAt;

/// Unique identifier for this request
@property (nonatomic, copy, readonly) NSString *requestId;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithArtistName:(NSString *)artistName NS_DESIGNATED_INITIALIZER;

/// Cancel this request. Safe to call multiple times.
/// All pending operations should check isCancelled and abort if true.
- (void)cancel;

/// Check if enough time has elapsed that this request is likely stale
/// @param timeout The timeout in seconds
- (BOOL)hasTimedOutWithTimeout:(NSTimeInterval)timeout;

/// Elapsed time since request started
@property (nonatomic, assign, readonly) NSTimeInterval elapsedTime;

@end

NS_ASSUME_NONNULL_END
