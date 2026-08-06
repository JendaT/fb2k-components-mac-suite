//
//  SimPlaylistNotifications.mm
//  foo_simplaylist_mac
//

#import "SimPlaylistNotifications.h"

// The string values are unchanged from when they were scattered literals, so a
// build mixing old and new object files still routes correctly.
NSString *const SimPlaylistSettingsChangedNotification = @"SimPlaylistSettingsChanged";
NSString *const SimPlaylistRedrawNeededNotification = @"SimPlaylistRedrawNeeded";
NSString *const SimPlaylistColumnsChangedNotification = @"SimPlaylistCustomColumnsChanged";
