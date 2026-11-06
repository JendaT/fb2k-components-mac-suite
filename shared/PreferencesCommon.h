#pragma once

//
// Shared preferences UI utilities for all foobar2000 macOS components
// Provides consistent styling matching foobar2000's built-in preferences pages
//

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

//
// Flipped view pattern for top-to-bottom layout
// macOS coordinate system has y=0 at bottom; flipping makes y=0 at top
//
// Each extension must define its own uniquely-named FlippedView class to avoid
// Objective-C runtime conflicts when multiple components are loaded:
//
// @interface MyExtensionFlippedView : NSView
// @end
// @implementation MyExtensionFlippedView
// - (BOOL)isFlipped { return YES; }
// @end

//
// Standard preferences title (matches foobar2000 built-in style - 15pt, non-bold)
//
static inline NSTextField *JLCreatePreferencesTitle(NSString *title) {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:15 weight:NSFontWeightRegular];
    return label;
}

//
// Section header (lighter, smaller - for grouping controls)
//
static inline NSTextField *JLCreateSectionHeader(NSString *title) {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    label.textColor = [NSColor secondaryLabelColor];
    return label;
}

//
// Standard label for form fields
//
static inline NSTextField *JLCreateLabel(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:11];
    return label;
}

//
// Helper text (smaller, tertiary color)
//
static inline NSTextField *JLCreateHelperText(NSString *text) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:10];
    label.textColor = [NSColor tertiaryLabelColor];
    return label;
}

//
// Standard layout constants
//
static const CGFloat JLPrefsRowHeight = 24.0;
static const CGFloat JLPrefsSectionGap = 16.0;
static const CGFloat JLPrefsLeftMargin = 20.0;
static const CGFloat JLPrefsIndent = 16.0;
static const CGFloat JLPrefsLabelWidth = 120.0;
static const CGFloat JLPrefsControlWidth = 200.0;

//
// "?" button at the right end of the title row; its action should call
// JLShowComponentInfo. Pinned with constraints to the container's trailing
// edge and the title's center, so it works on frame-based and Auto Layout pages.
//
static inline NSButton *JLAddPreferencesInfoButton(NSView *container, NSView *title, id target, SEL action) {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.bezelStyle = NSBezelStyleHelpButton;
    button.title = @"";
    button.controlSize = NSControlSizeSmall;
    button.toolTip = @"Component details";
    button.target = target;
    button.action = action;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-JLPrefsLeftMargin],
        [button.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
    ]];
    return button;
}

//
// Label/value grid for the info popover. Values are selectable so names can be copied.
//
static inline NSView *JLCreateComponentInfoView(NSArray<NSArray<NSString *> *> *rows) {
    NSMutableArray<NSArray<NSView *> *> *cells = [NSMutableArray array];
    for (NSArray<NSString *> *row in rows) {
        NSTextField *label = [NSTextField labelWithString:row[0]];
        label.font = [NSFont systemFontOfSize:11];
        label.textColor = [NSColor secondaryLabelColor];
        NSTextField *value = [NSTextField wrappingLabelWithString:row[1]];
        value.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        value.selectable = YES;
        value.preferredMaxLayoutWidth = 280;
        [cells addObject:@[label, value]];
    }
    NSGridView *grid = [NSGridView gridViewWithViews:cells];
    grid.rowSpacing = 6;
    grid.columnSpacing = 12;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    [content addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
    ]];
    [content setFrameSize:content.fittingSize];
    return content;
}

//
// Shows label/value rows (see JLComponentInfoRows in component_info.h) in a
// popover under the "?" button; a second click closes it.
//
static inline void JLShowComponentInfo(NSButton *sender, NSArray<NSArray<NSString *> *> *rows) {
    static char popoverKey;
    NSPopover *previous = objc_getAssociatedObject(sender, &popoverKey);
    if (previous.shown) {
        [previous performClose:nil];
        return;
    }

    NSViewController *controller = [[NSViewController alloc] init];
    controller.view = JLCreateComponentInfoView(rows);
    NSPopover *popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentViewController = controller;
    objc_setAssociatedObject(sender, &popoverKey, popover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [popover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
}
