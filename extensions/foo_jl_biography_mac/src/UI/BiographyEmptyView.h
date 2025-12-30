//
//  BiographyEmptyView.h
//  foo_jl_biography_mac
//
//  Empty state view when no track is playing
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface BiographyEmptyView : NSView

/// Set custom empty message
- (void)setMessage:(nullable NSString *)message;

@end

NS_ASSUME_NONNULL_END
