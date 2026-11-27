#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Playlist list structure or a visible playlist's item count changed.
// Coalesced: at most one per main-queue turn. No userInfo.
extern NSNotificationName const SVPlaylistsDidChangeNotification;

// A playlist was renamed. userInfo: @"old", @"new" (NSString). Posted before
// the matching SVPlaylistsDidChangeNotification.
extern NSNotificationName const SVPlaylistRenamedNotification;

// foobar's active playlist changed. Coalesced. No userInfo.
extern NSNotificationName const SVActivePlaylistDidChangeNotification;

// Reference-counted registration of the shared playlist_callback.
// Main thread only. Every Retain needs a matching Release.
void SVPlaylistCallbacksRetain(void);
void SVPlaylistCallbacksRelease(void);
/// Unregisters the playlist callback while foobar's services still exist (initquit::on_quit).
void SVPlaylistCallbacksShutdown(void);

NS_ASSUME_NONNULL_END
