//
//  BiographyLoadingView.h
//  foo_jl_biography_mac
//
//  Loading state view with spinner
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface BiographyLoadingView : NSView

/// Set the artist name being loaded
- (void)setArtistName:(nullable NSString *)name;

/// Start the loading animation
- (void)startAnimating;

/// Stop the loading animation
- (void)stopAnimating;

@end

NS_ASSUME_NONNULL_END
