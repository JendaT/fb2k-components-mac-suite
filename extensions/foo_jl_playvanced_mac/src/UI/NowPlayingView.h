#pragma once

#import <Cocoa/Cocoa.h>

@class TrackInfo;

NS_ASSUME_NONNULL_BEGIN

@protocol NowPlayingViewDelegate <NSObject>
- (void)nowPlayingViewDidPressPrevious;
- (void)nowPlayingViewDidPressPlayPause;
- (void)nowPlayingViewDidPressNext;
- (void)nowPlayingViewDidPressStop;
- (void)nowPlayingViewDidToggleShuffle;
- (void)nowPlayingViewDidCycleRepeat;
- (void)nowPlayingViewDidToggleMute;
- (void)nowPlayingViewDidSeekToPosition:(double)fraction;
- (void)nowPlayingViewDidChangeVolume:(float)volume;
- (void)nowPlayingViewDidReceiveDroppedPaths:(NSArray<NSString *> *)paths;
- (void)nowPlayingViewDidTapTrackInfo;
- (void)nowPlayingViewDidRequestSetRating:(NSInteger)rating;
@end

@interface NowPlayingView : NSView

@property (nonatomic, weak, nullable) id<NowPlayingViewDelegate> delegate;
@property (nonatomic, strong, nullable) NSImage *artworkImage;
@property (nonatomic, strong, nullable) TrackInfo *trackInfo;
@property (nonatomic, assign) double playbackPosition;
@property (nonatomic, assign) double trackDuration;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isPaused;
@property (nonatomic, assign) float volume;
// 0=Default, 1=RepeatAll, 2=RepeatOne, 3=Random, 4=Shuffle(tracks), 5=Shuffle(albums), 6=Shuffle(folders)
@property (nonatomic, assign) NSInteger playbackOrder;

- (void)clearDisplay;

@end

NS_ASSUME_NONNULL_END
