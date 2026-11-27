#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Spotify-style "Up Next" popover: what is playing, the foobar playback queue,
// and the upcoming items of the playing playlist ("Now Playing" when stopped).
// Rows from "Now Playing" can be reordered, removed and played; rows from any
// other playlist are read-only. Main thread only.
@interface UpNextPopoverController : NSObject

@property (nonatomic, readonly) BOOL isShown;

// Called whenever the popover opens or closes (used to highlight the bar button).
@property (nonatomic, copy, nullable) void (^visibilityChanged)(BOOL shown);

- (void)showRelativeToView:(NSView *)anchor;
- (void)close;

// Toggles the popover. Ignores a toggle that arrives right after a transient
// close caused by the same click on the anchor button.
- (void)toggleRelativeToView:(NSView *)anchor;

// Schedules one reload on the next run-loop turn. No-op while hidden.
- (void)setNeedsReload;

// The popover's window while shown (for shortcut scoping), else nil.
@property (nonatomic, readonly, nullable) NSWindow *popoverWindow;

@end

NS_ASSUME_NONNULL_END
