//
//  ScrobbleWidgetController.h
//  foo_jl_scrobble_mac
//
//  Controller for the Last.fm stats layout widget (ui_element_mac)
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ScrobbleWidgetView;

@interface ScrobbleWidgetController : NSViewController

// Initialize with optional layout parameters
- (instancetype)initWithParameters:(nullable NSDictionary<NSString*, NSString*>*)params;

// Manual refresh (e.g., from context menu)
- (void)refreshStats;

@end

NS_ASSUME_NONNULL_END
