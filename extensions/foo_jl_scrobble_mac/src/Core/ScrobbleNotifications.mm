//
//  ScrobbleNotifications.mm
//  foo_scrobble_mac
//
//  Typed notification name definitions
//

#import "ScrobbleNotifications.h"

// Authentication
NSNotificationName const LastFmAuthStateDidChangeNotification = @"LastFmAuthStateDidChange";
NSNotificationName const LastFmAuthDidSignInNotification = @"LastFmAuthDidSignIn";
NSNotificationName const LastFmAuthDidSignOutNotification = @"LastFmAuthDidSignOut";

// Scrobbling
NSNotificationName const ScrobbleServiceStateDidChangeNotification = @"ScrobbleServiceStateDidChange";
NSNotificationName const ScrobbleServiceDidScrobbleNotification = @"ScrobbleServiceDidScrobble";
NSNotificationName const ScrobbleServiceDidFailNotification = @"ScrobbleServiceDidFail";
NSNotificationName const ScrobbleServiceNowPlayingDidChangeNotification = @"ScrobbleServiceNowPlayingDidChange";

// Cache
NSNotificationName const ScrobbleCacheDidChangeNotification = @"ScrobbleCacheDidChange";

// Stats
NSNotificationName const ScrobbleStatsDidUpdateNotification = @"ScrobbleStatsDidUpdate";

// Settings
NSNotificationName const ScrobbleSettingsDidChangeNotification = @"ScrobbleSettingsDidChange";
