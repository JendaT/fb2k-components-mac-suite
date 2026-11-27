//
//  PlayVancedShortcuts.mm
//  App-wide playback shortcuts via a local key-down monitor, scoped to the
//  window that hosts a PlayVanced bar (and its Up Next popover).
//
//    Space        play / pause; when stopped, starts "Now Playing" at its
//                 focus (not while a text field has focus)
//    ⌘→ / ⌘←      next / previous (not while a text field has focus)
//    ⌘↑ / ⌘↓      volume up / down (not while a text field has focus)
//    ⌘S           toggle shuffle
//    ⌘R           cycle repeat
//    ⌥⌘U          toggle the Up Next popover
//

#import "PlayVancedShortcuts.h"
#import "PlayVancedCallbacks.h"
#import "../UI/PlayVancedController.h"
#import "../../../../shared/UpNext.h"

static id g_keyMonitor = nil;

namespace {

enum : unsigned short {
    kKeyLeft  = 123,
    kKeyRight = 124,
    kKeyDown  = 125,
    kKeyUp    = 126,
    // Physical key positions (ANSI): fallback for non-Latin layouts only.
    kKeyS     = 1,
    kKeyR     = 15,
    kKeyU     = 32,
};

PlayVancedController *controllerForWindow(NSWindow *window) {
    if (!window) return nil;
    for (PlayVancedController *c in PlayVancedCallbackManager_controllers()) {
        if ([c ownsWindow:window]) return c;
    }
    return nil;
}

// Focus is somewhere keys mean typing or activating a control.
bool textHasFocus(NSWindow *window) {
    NSResponder *fr = window.firstResponder;
    // NSText covers field editors (NSTextView) used by NSTextField / NSSearchField.
    if ([fr isKindOfClass:[NSText class]]) return true;
    if ([fr conformsToProtocol:@protocol(NSTextInputClient)] &&
        ![fr isKindOfClass:[NSTableView class]] &&
        ![fr isKindOfClass:[NSCollectionView class]]) {   // NSOutlineView is an NSTableView
        return true;
    }
    return false;
}

bool controlHasFocus(NSWindow *window) {
    NSResponder *fr = window.firstResponder;
    return [fr isKindOfClass:[NSButton class]] ||        // includes NSPopUpButton, checkboxes
           [fr isKindOfClass:[NSPopUpButton class]] ||
           [fr isKindOfClass:[NSSegmentedControl class]];
}

// Letter shortcut match: the layout's character when it is a single ASCII
// character (so Dvorak/AZERTY users get the letter printed on the key), else
// the ANSI key position (non-Latin layouts such as Cyrillic or Greek).
bool matchesLetter(NSEvent *event, unichar letter, unsigned short fallbackKeyCode) {
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length == 1) {
        unichar c = [chars characterAtIndex:0];
        if (c < 128) {
            if (c >= 'A' && c <= 'Z') c = (unichar)(c - 'A' + 'a');
            return c == letter;
        }
    }
    return event.keyCode == fallbackKeyCode;
}

template <typename F>
bool runPlayback(F &&f) {
    try {
        auto pc = playback_control::get();
        if (!pc.is_valid()) return false;
        f(pc);
        return true;
    } catch (...) {
        return false;
    }
}

// Returns YES when the event was handled (and should be consumed).
BOOL handleKeyDown(NSEvent *event) {
    NSWindow *window = event.window;
    PlayVancedController *controller = controllerForWindow(window);
    if (!controller) return NO;

    const NSEventModifierFlags mods = event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagOption |
         NSEventModifierFlagControl | NSEventModifierFlagShift);
    const unsigned short keyCode = event.keyCode;
    const bool inText = textHasFocus(window);

    // Space: play / pause (starts playback when stopped).
    if (mods == 0 && [event.charactersIgnoringModifiers isEqualToString:@" "]) {
        if (inText || controlHasFocus(window)) return NO;
        if (event.isARepeat) return YES;
        // Stopped + non-empty Now Playing: start Now Playing at its focus.
        return runPlayback([](auto &pc) {
            if (!upnext::fb::startNowPlayingIfStopped()) pc->play_or_pause();
        });
    }

    if (mods == NSEventModifierFlagCommand) {
        // Arrow shortcuts would steal text navigation (line/document start/end).
        switch (keyCode) {
            case kKeyRight:
                if (inText) return NO;
                if (event.isARepeat) return YES;   // holding must not skip many tracks
                return runPlayback([](auto &pc) { pc->start(playback_control::track_command_next); });
            case kKeyLeft:
                if (inText) return NO;
                if (event.isARepeat) return YES;
                return runPlayback([](auto &pc) { pc->start(playback_control::track_command_prev); });
            case kKeyUp:
                if (inText) return NO;
                return runPlayback([](auto &pc) { pc->volume_up(); });
            case kKeyDown:
                if (inText) return NO;
                return runPlayback([](auto &pc) { pc->volume_down(); });
            default:
                break;
        }
        // Repeats of our own shortcuts are swallowed (not passed on to e.g. Save).
        if (matchesLetter(event, 's', kKeyS)) {
            if (!event.isARepeat) [controller toggleShuffle];
            return YES;
        }
        if (matchesLetter(event, 'r', kKeyR)) {
            if (!event.isARepeat) [controller cycleRepeat];
            return YES;
        }
        return NO;
    }

    if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagOption)) {
        if (matchesLetter(event, 'u', kKeyU)) {
            if (!event.isARepeat) [controller toggleUpNextPopover];
            return YES;
        }
    }

    return NO;
}

} // namespace

void PlayVancedShortcuts_install(void) {
    if (g_keyMonitor) return;
    g_keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                         handler:^NSEvent *(NSEvent *event) {
        @autoreleasepool {
            return handleKeyDown(event) ? nil : event;
        }
    }];
}

void PlayVancedShortcuts_uninstall(void) {
    if (!g_keyMonitor) return;
    [NSEvent removeMonitor:g_keyMonitor];
    g_keyMonitor = nil;
}
