//
//  NetworkReachability.h
//  shared
//
//  Network reachability monitoring singleton using NWPathMonitor
//  Thread-safe wrapper for detecting offline/online state
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Notification posted when network reachability changes
/// userInfo contains @"isReachable": NSNumber(BOOL)
extern NSNotificationName const JLNetworkReachabilityChangedNotification;

/// Thread-safe singleton for monitoring network reachability
/// Uses NWPathMonitor internally for accurate status detection
@interface JLNetworkReachability : NSObject

/// Shared singleton instance
@property (class, readonly, strong) JLNetworkReachability *sharedInstance;

/// Current reachability status (thread-safe).
/// Fails open: reports YES until the path monitor delivers its first update,
/// so a query immediately after startup may optimistically report reachable.
@property (nonatomic, readonly, getter=isReachable) BOOL reachable;

/// Whether the connection is expensive (cellular/hotspot)
@property (nonatomic, readonly, getter=isExpensive) BOOL expensive;

/// Whether the connection is constrained (Low Data Mode)
@property (nonatomic, readonly, getter=isConstrained) BOOL constrained;

/// Start monitoring network changes
/// Automatically called on first access to sharedInstance
- (void)startMonitoring;

/// Stop monitoring network changes
- (void)stopMonitoring;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
