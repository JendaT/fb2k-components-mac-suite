#pragma once

//
// Shared preferences UI utilities for all foobar2000 macOS components
// Provides consistent styling matching foobar2000's built-in preferences pages
//

#import <Cocoa/Cocoa.h>

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
// Standard preferences title (matches foobar2000 built-in style - non-bold)
//
static inline NSTextField *JLCreatePreferencesTitle(NSString *title) {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
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
