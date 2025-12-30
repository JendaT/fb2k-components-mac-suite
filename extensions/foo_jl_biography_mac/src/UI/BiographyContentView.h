//
//  BiographyContentView.h
//  foo_jl_biography_mac
//
//  Main content view displaying biography and artist image
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class BiographyData;

@interface BiographyContentView : NSView

/// Update the view with new biography data
- (void)updateWithBiographyData:(BiographyData *)data;

/// Clear the view
- (void)clear;

@end

NS_ASSUME_NONNULL_END
