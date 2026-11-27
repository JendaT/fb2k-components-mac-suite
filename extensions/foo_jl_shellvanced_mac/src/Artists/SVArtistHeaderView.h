//
//  SVArtistHeaderView.h
//  foo_jl_shellvanced_mac
//
//  Artist page header: 128 pt round photo, name, "N albums · M tracks",
//  Play and Shuffle buttons.
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SVArtistHeaderView : NSView

/// Setting the name loads the photo and the counts.
@property (nonatomic, copy, nullable) NSString *artistName;
@property (nonatomic, copy, nullable) void (^onPlay)(void);
@property (nonatomic, copy, nullable) void (^onShuffle)(void);

/// Re-reads album/track counts (library index rebuilt).
- (void)refreshCounts;

@end

NS_ASSUME_NONNULL_END
