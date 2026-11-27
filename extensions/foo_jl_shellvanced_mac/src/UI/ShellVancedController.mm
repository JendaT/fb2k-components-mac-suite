#import "ShellVancedController.h"
#import "../Integration/ElementHost.h"

#pragma mark - Key equivalent dump (spike, removed in Task 7)

static NSString* SVModifierString(NSEventModifierFlags flags) {
    NSMutableString* s = [NSMutableString string];
    if (flags & NSEventModifierFlagControl) [s appendString:@"ctrl+"];
    if (flags & NSEventModifierFlagOption)  [s appendString:@"opt+"];
    if (flags & NSEventModifierFlagShift)   [s appendString:@"shift+"];
    if (flags & NSEventModifierFlagCommand) [s appendString:@"cmd+"];
    if (flags & NSEventModifierFlagFunction) [s appendString:@"fn+"];
    return s;
}

static NSString* SVKeyString(NSString* key) {
    if (key.length != 1) return key;
    unichar c = [key characterAtIndex:0];
    switch (c) {
        case ' ':                       return @"Space";
        case '\r': case '\n':           return @"Return";
        case '\t':                      return @"Tab";
        case 0x1B:                      return @"Escape";
        case 0x08: case 0x7F:           return @"Delete";
        case NSDeleteFunctionKey:       return @"ForwardDelete";
        case NSUpArrowFunctionKey:      return @"Up";
        case NSDownArrowFunctionKey:    return @"Down";
        case NSLeftArrowFunctionKey:    return @"Left";
        case NSRightArrowFunctionKey:   return @"Right";
        case NSHomeFunctionKey:         return @"Home";
        case NSEndFunctionKey:          return @"End";
        case NSPageUpFunctionKey:       return @"PageUp";
        case NSPageDownFunctionKey:     return @"PageDown";
        default: break;
    }
    if (c >= NSF1FunctionKey && c <= NSF35FunctionKey) {
        return [NSString stringWithFormat:@"F%d", (int)(c - NSF1FunctionKey + 1)];
    }
    if (c < 0x20 || (c >= 0xF700 && c <= 0xF8FF)) {
        return [NSString stringWithFormat:@"U+%04X", c];
    }
    return key;
}

static void SVDumpMenu(NSMenu* menu, NSString* path) {
    for (NSMenuItem* item in menu.itemArray) {
        if (item.isSeparatorItem) continue;
        NSString* title = item.title.length ? item.title : @"(untitled)";
        NSString* itemPath = path.length ? [NSString stringWithFormat:@"%@ > %@", path, title] : title;
        if (item.keyEquivalent.length > 0) {
            NSString* line = [NSString stringWithFormat:@"[ShellVanced] key: %@ | %@%@",
                              itemPath,
                              SVModifierString(item.keyEquivalentModifierMask),
                              SVKeyString(item.keyEquivalent)];
            console::info(line.UTF8String);
        }
        if (item.submenu) {
            SVDumpMenu(item.submenu, itemPath);
        }
    }
}

static void SVDumpMainMenuKeyEquivalentsOnce() {
    static bool s_done = false;
    if (s_done) return;
    s_done = true;
    // Next run-loop turn so dynamically built menus exist.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMenu* mainMenu = NSApp.mainMenu;
        if (!mainMenu) {
            console::info("[ShellVanced] key: (no main menu)");
            return;
        }
        SVDumpMenu(mainMenu, @"");
    });
}

#pragma mark - Controller

@implementation ShellVancedController {
    NSDictionary<NSString*,NSString*>* _params;
    NSViewController* _hosted;
    NSTextField* _placeholder;
}

- (instancetype)initWithParams:(NSDictionary<NSString*,NSString*>*)params {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _params = [params copy] ?: @{};
    }
    return self;
}

- (instancetype)init {
    return [self initWithParams:nil];
}

- (void)loadView {
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 500)];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = container;

    SVDumpMainMenuKeyEquivalentsOnce();

    // Spike: host AlbumViewVanced filling the whole view.
    _hosted = SVInstantiateElement(kSVGuidAlbumViewVanced, @{});
    if (_hosted) {
        console::info("[ShellVanced] hosted AlbumViewVanced");
        [self addChildViewController:_hosted];
        NSView* child = _hosted.view;
        child.frame = container.bounds;
        child.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [container addSubview:child];
    } else {
        console::info("[ShellVanced] AlbumViewVanced not available");
        _placeholder = [NSTextField labelWithString:@"Install AlbumViewVanced to use this section"];
        _placeholder.textColor = [NSColor secondaryLabelColor];
        _placeholder.alignment = NSTextAlignmentCenter;
        _placeholder.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:_placeholder];
        [NSLayoutConstraint activateConstraints:@[
            [_placeholder.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
            [_placeholder.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
            [_placeholder.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:12],
            [_placeholder.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-12],
        ]];
    }
}

@end
