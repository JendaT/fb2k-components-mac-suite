//
//  JLConstraintDebugger.h
//  Constraint debugging helper for foobar2000 components
//
//  Usage:
//    1. Import this header in your component's Main.mm
//    2. Call [JLConstraintDebugger enable] in your component's initialization
//    3. Use foobar2000 console commands to control:
//       - jl_debug_constraints on/off    - Enable/disable logging
//       - jl_debug_dump <viewname>       - Dump view hierarchy
//       - jl_debug_highlight on/off      - Highlight views with issues
//
//  All output goes to Console.app (filter by "JLConstraint") and fb2k console
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface JLConstraintDebugger : NSObject

/// Enable the constraint debugger (call once at startup)
+ (void)enable;

/// Disable the constraint debugger
+ (void)disable;

/// Check if debugger is currently enabled
+ (BOOL)isEnabled;

/// Toggle verbose logging of intrinsicContentSize calls
+ (void)setVerboseLogging:(BOOL)verbose;

/// Dump the view hierarchy starting from a window or view
+ (void)dumpViewHierarchy:(NSView *)rootView;

/// Dump all windows' view hierarchies
+ (void)dumpAllWindows;

/// Find views with potential sizing issues
+ (NSArray<NSView *> *)findSuspectViews:(NSView *)rootView;

/// Log sizing info for a specific view
+ (void)logSizingInfo:(NSView *)view;

/// Highlight views that may cause container limiting (adds colored borders)
+ (void)highlightSuspectViews:(NSView *)rootView;

/// Remove highlight borders
+ (void)removeHighlights:(NSView *)rootView;

@end

NS_ASSUME_NONNULL_END
