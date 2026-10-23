//
//  RemoteServer.h
//  foo_jl_remote_mac
//
//  HTTP listener (Network.framework) that serves the web UI and the JSON API.
//  One request per connection; requests are parsed and access-checked on the
//  server queue, player work runs on the main thread (PlayerBridge).
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main thread whenever statusText changes.
extern NSString* const RemoteServerStatusChangedNotification;

@interface RemoteServer : NSObject

+ (instancetype)shared;

// Starts, restarts or stops the listener to match the current config.
// Main thread only.
- (void)applyConfig;

// Stops the listener. Main thread only.
- (void)stop;

// Stops the listener for good at app quit; requests still in flight are
// answered with 503 instead of touching playback services. Main thread only.
- (void)shutdown;

// Human-readable listener state, e.g. "Listening on port 8890".
@property (nonatomic, readonly, copy) NSString *statusText;

// True while the listener is accepting connections.
@property (nonatomic, readonly) BOOL isListening;

// http:// URLs a phone on the local network can open, one per active
// private IPv4 interface address of this Mac.
- (NSArray<NSString *> *)localURLs;

@end

NS_ASSUME_NONNULL_END
