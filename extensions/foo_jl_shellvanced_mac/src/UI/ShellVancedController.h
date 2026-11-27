#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface ShellVancedController : NSViewController

// Layout params passed to ui_element_mac::instantiate (may be empty).
- (instancetype)initWithParams:(nullable NSDictionary<NSString*,NSString*>*)params;

@end

NS_ASSUME_NONNULL_END
