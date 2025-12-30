//
//  BiographyErrorView.h
//  foo_jl_biography_mac
//
//  Error state view with retry option
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class BiographyErrorView;

@protocol BiographyErrorViewDelegate <NSObject>
- (void)errorViewDidTapRetry:(BiographyErrorView *)errorView;
@end

@interface BiographyErrorView : NSView

@property (nonatomic, weak, nullable) id<BiographyErrorViewDelegate> delegate;

/// Set the error message to display
- (void)setErrorMessage:(nullable NSString *)message;

/// Set a detailed error description
- (void)setErrorDetail:(nullable NSString *)detail;

@end

NS_ASSUME_NONNULL_END
