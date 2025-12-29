//
//  UIStyles.h
//  Shared UI styles for foobar2000 macOS components
//
//  Common visual definitions to ensure consistent look across:
//  - foo_jl_simplaylist_mac
//  - foo_jl_queue_manager
//  - Other list-based UI components
//

#pragma once

#import <Cocoa/Cocoa.h>

namespace fb2k_ui {

// Layout constants
static const CGFloat kDefaultRowHeight = 22.0;
static const CGFloat kDefaultHeaderHeight = 22.0;
static const CGFloat kHeaderTextPadding = 6.0;
static const CGFloat kCellTextPadding = 4.0;
static const CGFloat kResizeHandleWidth = 6.0;

// Font sizes
static const CGFloat kHeaderFontSize = 11.0;
static const CGFloat kRowFontSize = 12.0;
static const CGFloat kStatusBarFontSize = 11.0;

// Color helpers - inline functions for Objective-C++ compatibility
inline NSColor* backgroundColor() {
    return [NSColor controlBackgroundColor];
}

inline NSColor* alternateRowColor() {
    return [[NSColor controlBackgroundColor] blendedColorWithFraction:0.03
                                                              ofColor:[NSColor labelColor]];
}

inline NSColor* headerBackgroundColor() {
    return [[NSColor controlBackgroundColor] blendedColorWithFraction:0.08
                                                              ofColor:[NSColor labelColor]];
}

inline NSColor* selectedBackgroundColor() {
    return [NSColor selectedContentBackgroundColor];
}

inline NSColor* textColor() {
    return [NSColor labelColor];
}

inline NSColor* selectedTextColor() {
    return [NSColor selectedMenuItemTextColor];
}

inline NSColor* secondaryTextColor() {
    return [NSColor secondaryLabelColor];
}

inline NSColor* separatorColor() {
    return [NSColor separatorColor];
}

inline NSColor* dropIndicatorColor() {
    return [NSColor systemBlueColor];
}

// Font helpers
inline NSFont* headerFont() {
    return [NSFont systemFontOfSize:kHeaderFontSize weight:NSFontWeightMedium];
}

inline NSFont* rowFont() {
    return [NSFont systemFontOfSize:kRowFontSize];
}

inline NSFont* monospacedDigitFont() {
    return [NSFont monospacedDigitSystemFontOfSize:kRowFontSize weight:NSFontWeightRegular];
}

inline NSFont* statusBarFont() {
    return [NSFont systemFontOfSize:kStatusBarFontSize];
}

} // namespace fb2k_ui
