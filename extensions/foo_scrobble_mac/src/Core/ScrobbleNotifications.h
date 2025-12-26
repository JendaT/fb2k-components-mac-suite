//
//  ScrobbleNotifications.h
//  foo_scrobble_mac
//
//  Typed notification names for thread-safe observer pattern
//

#pragma once

#import <Foundation/Foundation.h>

// Authentication
extern NSNotificationName const LastFmAuthStateDidChangeNotification;
extern NSNotificationName const LastFmAuthDidSignInNotification;
extern NSNotificationName const LastFmAuthDidSignOutNotification;

// Scrobbling
extern NSNotificationName const ScrobbleServiceStateDidChangeNotification;
extern NSNotificationName const ScrobbleServiceDidScrobbleNotification;
extern NSNotificationName const ScrobbleServiceDidFailNotification;
extern NSNotificationName const ScrobbleServiceNowPlayingDidChangeNotification;

// Cache
extern NSNotificationName const ScrobbleCacheDidChangeNotification;

// Stats
extern NSNotificationName const ScrobbleStatsDidUpdateNotification;

// Settings
extern NSNotificationName const ScrobbleSettingsDidChangeNotification;
