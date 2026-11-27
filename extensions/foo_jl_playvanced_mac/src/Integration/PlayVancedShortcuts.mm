//
//  PlayVancedShortcuts.mm
//  App-wide playback shortcuts via a local key-down monitor, scoped to the
//  window that hosts a PlayVanced bar (and its Up Next popover).
//
//    Space        play / pause   (not while a text field has focus)
//    ⌘→ / ⌘←      next / previous (not while a text field has focus)
//    ⌘↑ / ⌘↓      volume up / down (not while a text field has focus)
//    ⌘S           toggle shuffle
//    ⌘R           cycle repeat
//    ⌥⌘U          toggle the Up Next popover
//

#import "PlayVancedShortcuts.h"
#import "PlayVancedCallbacks.h"
#import "../UI/PlayVancedController.h"

static id g_keyMonitor = nil;

namespace {

enum : unsigned short {
    kKeyLeft  = 123,
    kKeyRight = 124,
    kKeyDown  = 125,
    kKeyUp    = 126,
};

PlayVancedController *controllerForWindow(NSWindow *window) {
    if (!window) return nil;
    for (PlayVancedController *c in PlayVancedCallbackManager_controllers()) {
        if ([c ownsWindow:window]) return c;
    }
    return nil;
}

bool textHasFocus(NSWindow *window) {
    NSResponder *fr = window.firstResponder;
    // NSText covers field editors (NSTextView) used by NSTextField / NSSearchField.
    return [fr isKindOfClass:[NSText class]];
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
    NSString *chars = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    const bool inText = textHasFocus(window);

    // Space: play / pause (starts playback when stopped).
    if (mods == 0 && [event.charactersIgnoringModifiers isEqualToString:@" "]) {
        if (inText) return NO;
        if (event.isARepeat) return YES;
        return runPlayback([](auto &pc) { pc->play_or_pause(); });
    }

    if (mods == NSEventModifierFlagCommand) {
        // Arrow shortcuts would steal text navigation (line/document start/end).
        switch (keyCode) {
            case kKeyRight:
                if (inText) return NO;
                return runPlayback([](auto &pc) { pc->start(playback_control::track_command_next); });
            case kKeyLeft:
                if (inText) return NO;
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
        if (event.isARepeat) return NO;
        if ([chars isEqualToString:@"s"]) { [controller toggleShuffle]; return YES; }
        if ([chars isEqualToString:@"r"]) { [controller cycleRepeat]; return YES; }
        return NO;
    }

    if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagOption)) {
        if (event.isARepeat) return NO;
        if ([chars isEqualToString:@"u"]) {
            [controller toggleUpNextPopover];
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
