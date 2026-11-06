//
//  SimPlaylistNotifications.h
//  foo_simplaylist_mac
//
//  The component's three internal NSNotification names, in one place.
//
//  These were previously raw string literals at ~21 sites, with a single
//  constant declared in a *view* header that almost none of the posters used.
//  Poster and observer shared no symbol, so a name that no one listened for was
//  indistinguishable from one that worked: no compile error, no runtime error,
//  no log. That failure mode shipped twice — the grouping-preset switch and the
//  custom-column editor both posted into the void. Declaring the names here
//  makes an orphan a missing symbol at build time instead of silence at runtime.
//
//  This header is deliberately free of any SDK or AppKit-view dependency so the
//  preferences panes can import it without pulling in SimPlaylistView.h.
//
//  Channel contract:
//
//    SettingsChanged  — grouping, geometry or anything that invalidates the row
//                       layout. Observers re-read config and rebuild. Expensive.
//    RedrawNeeded     — appearance-only settings that leave the layout intact.
//                       Observers re-read config and redraw. Cheap.
//    ColumnsChanged   — the custom-column catalogue itself changed (added,
//                       removed, renamed). Observers re-read the column list and
//                       recompile their title-format scripts.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const SimPlaylistSettingsChangedNotification;
extern NSString *const SimPlaylistRedrawNeededNotification;
extern NSString *const SimPlaylistColumnsChangedNotification;

NS_ASSUME_NONNULL_END
