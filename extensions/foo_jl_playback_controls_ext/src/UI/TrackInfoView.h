//
//  TrackInfoView.h
//  foo_jl_playback_controls_ext
//
//  Two-row track info display with click-to-navigate
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class TrackInfoView;

@protocol TrackInfoViewDelegate <NSObject>
@optional
- (void)trackInfoViewDidClick:(TrackInfoView *)view;
@end

@interface TrackInfoView : NSView

@property (nonatomic, weak, nullable) id<TrackInfoViewDelegate> delegate;

// Display text
@property (nonatomic, copy) NSString *topRowText;
@property (nonatomic, copy) NSString *bottomRowText;

// Appearance
@property (nonatomic, strong) NSFont *topRowFont;
@property (nonatomic, strong) NSFont *bottomRowFont;
@property (nonatomic, strong) NSColor *topRowColor;
@property (nonatomic, strong) NSColor *bottomRowColor;

@end

NS_ASSUME_NONNULL_END
