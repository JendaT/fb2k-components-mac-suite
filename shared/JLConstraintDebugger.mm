//
//  JLConstraintDebugger.mm
//  Constraint debugging helper for foobar2000 components
//

#import "JLConstraintDebugger.h"
#import <objc/runtime.h>

// foobar2000 SDK console logging
#ifdef FB2K_COMPONENT
#include <SDK/foobar2000.h>
#define FB2K_LOG(fmt, ...) FB2K_console_formatter() << "[JLConstraint] " << [NSString stringWithFormat:fmt, ##__VA_ARGS__].UTF8String
#else
#define FB2K_LOG(fmt, ...) NSLog(@"[JLConstraint] " fmt, ##__VA_ARGS__)
#endif

static BOOL g_enabled = NO;
static BOOL g_verbose = NO;
static NSMutableSet<NSString *> *g_loggedClasses = nil;

// Original method implementations
static NSSize (*original_intrinsicContentSize)(id, SEL) = NULL;

#pragma mark - Swizzled Methods

static NSSize swizzled_intrinsicContentSize(id self, SEL _cmd) {
    NSSize size = original_intrinsicContentSize(self, _cmd);

    if (g_verbose) {
        NSString *className = NSStringFromClass([self class]);

        // Only log each class once per session to reduce noise
        if (![g_loggedClasses containsObject:className]) {
            [g_loggedClasses addObject:className];

            BOOL isNoIntrinsic = (size.width == NSViewNoIntrinsicMetric &&
                                  size.height == NSViewNoIntrinsicMetric);

            if (!isNoIntrinsic) {
                NSLog(@"[JLConstraint] %@ intrinsicContentSize: %.0f x %.0f %@",
                      className, size.width, size.height,
                      isNoIntrinsic ? @"(NoIntrinsic)" : @"<-- RETURNS SIZE");
            }
        }
    }

    return size;
}

#pragma mark - JLConstraintDebugger Implementation

@implementation JLConstraintDebugger

+ (void)initialize {
    if (self == [JLConstraintDebugger class]) {
        g_loggedClasses = [NSMutableSet new];
    }
}

+ (void)enable {
    if (g_enabled) return;
    g_enabled = YES;

    // Swizzle intrinsicContentSize on NSView
    Method method = class_getInstanceMethod([NSView class], @selector(intrinsicContentSize));
    if (method) {
        original_intrinsicContentSize = (NSSize (*)(id, SEL))method_getImplementation(method);
        method_setImplementation(method, (IMP)swizzled_intrinsicContentSize);
    }

    // Listen for constraint conflicts
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleConstraintNotification:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:nil];

    NSLog(@"[JLConstraint] Debugger ENABLED - Use Console.app to view logs");
    NSLog(@"[JLConstraint] Call [JLConstraintDebugger setVerboseLogging:YES] to log intrinsicContentSize calls");
}

+ (void)disable {
    if (!g_enabled) return;
    g_enabled = NO;

    // Restore original implementation
    if (original_intrinsicContentSize) {
        Method method = class_getInstanceMethod([NSView class], @selector(intrinsicContentSize));
        if (method) {
            method_setImplementation(method, (IMP)original_intrinsicContentSize);
        }
        original_intrinsicContentSize = NULL;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    NSLog(@"[JLConstraint] Debugger DISABLED");
}

+ (BOOL)isEnabled {
    return g_enabled;
}

+ (void)setVerboseLogging:(BOOL)verbose {
    g_verbose = verbose;
    [g_loggedClasses removeAllObjects];
    NSLog(@"[JLConstraint] Verbose logging: %@", verbose ? @"ON" : @"OFF");
}

+ (void)handleConstraintNotification:(NSNotification *)notification {
    // This is a placeholder - actual constraint conflicts are logged by AppKit
    // to the system console. We can add custom logic here if needed.
}

#pragma mark - View Hierarchy Dumping

+ (void)dumpViewHierarchy:(NSView *)rootView {
    NSLog(@"[JLConstraint] === View Hierarchy Dump ===");
    [self dumpView:rootView indent:0];
    NSLog(@"[JLConstraint] === End Dump ===");
}

+ (void)dumpView:(NSView *)view indent:(int)indent {
    NSString *indentStr = [@"" stringByPaddingToLength:indent * 2 withString:@" " startingAtIndex:0];

    NSSize intrinsic = view.intrinsicContentSize;
    CGFloat huggingH = [view contentHuggingPriorityForOrientation:NSLayoutConstraintOrientationHorizontal];
    CGFloat huggingV = [view contentHuggingPriorityForOrientation:NSLayoutConstraintOrientationVertical];
    CGFloat compressionH = [view contentCompressionResistancePriorityForOrientation:NSLayoutConstraintOrientationHorizontal];
    CGFloat compressionV = [view contentCompressionResistancePriorityForOrientation:NSLayoutConstraintOrientationVertical];

    NSString *issues = @"";

    // Check for potential issues
    if (intrinsic.width != NSViewNoIntrinsicMetric || intrinsic.height != NSViewNoIntrinsicMetric) {
        issues = [issues stringByAppendingString:@" [INTRINSIC]"];
    }
    if (huggingH >= 750 || huggingV >= 750) {
        issues = [issues stringByAppendingString:@" [HIGH-HUG]"];
    }
    if (compressionH >= 750 || compressionV >= 750) {
        issues = [issues stringByAppendingString:@" [HIGH-COMP]"];
    }

    NSLog(@"[JLConstraint] %@%@ frame:%.0fx%.0f intrinsic:%.0fx%.0f hug:%.0f/%.0f comp:%.0f/%.0f%@",
          indentStr,
          NSStringFromClass([view class]),
          view.frame.size.width, view.frame.size.height,
          intrinsic.width, intrinsic.height,
          huggingH, huggingV,
          compressionH, compressionV,
          issues);

    for (NSView *subview in view.subviews) {
        [self dumpView:subview indent:indent + 1];
    }
}

+ (void)dumpAllWindows {
    NSLog(@"[JLConstraint] === All Windows Dump ===");
    for (NSWindow *window in [NSApp windows]) {
        NSLog(@"[JLConstraint] Window: %@ (%.0fx%.0f)",
              window.title.length > 0 ? window.title : @"<untitled>",
              window.frame.size.width, window.frame.size.height);
        if (window.contentView) {
            [self dumpView:window.contentView indent:1];
        }
    }
    NSLog(@"[JLConstraint] === End Dump ===");
}

#pragma mark - Suspect View Detection

+ (NSArray<NSView *> *)findSuspectViews:(NSView *)rootView {
    NSMutableArray<NSView *> *suspects = [NSMutableArray array];
    [self collectSuspectViews:rootView into:suspects];
    return suspects;
}

+ (void)collectSuspectViews:(NSView *)view into:(NSMutableArray<NSView *> *)suspects {
    NSSize intrinsic = view.intrinsicContentSize;
    CGFloat huggingH = [view contentHuggingPriorityForOrientation:NSLayoutConstraintOrientationHorizontal];
    CGFloat huggingV = [view contentHuggingPriorityForOrientation:NSLayoutConstraintOrientationVertical];
    CGFloat compressionH = [view contentCompressionResistancePriorityForOrientation:NSLayoutConstraintOrientationHorizontal];
    CGFloat compressionV = [view contentCompressionResistancePriorityForOrientation:NSLayoutConstraintOrientationVertical];

    BOOL isSuspect = NO;

    // Check for non-NoIntrinsicMetric (only flag if also has high priority)
    if ((intrinsic.width != NSViewNoIntrinsicMetric && compressionH >= 500) ||
        (intrinsic.height != NSViewNoIntrinsicMetric && compressionV >= 500)) {
        isSuspect = YES;
    }

    // Check for high compression resistance (the main cause of "snap back")
    if (compressionH >= 750 || compressionV >= 750) {
        isSuspect = YES;
    }

    if (isSuspect) {
        [suspects addObject:view];
    }

    for (NSView *subview in view.subviews) {
        [self collectSuspectViews:subview into:suspects];
    }
}

+ (void)logSizingInfo:(NSView *)view {
    NSSize intrinsic = view.intrinsicContentSize;
    CGFloat huggingH = [view contentHuggingPriorityForOrientation:NSLayoutConstraintOrientationHorizontal];
    CGFloat huggingV = [view contentHuggingPriorityForOrientation:NSLayoutConstraintOrientationVertical];
    CGFloat compressionH = [view contentCompressionResistancePriorityForOrientation:NSLayoutConstraintOrientationHorizontal];
    CGFloat compressionV = [view contentCompressionResistancePriorityForOrientation:NSLayoutConstraintOrientationVertical];

    NSLog(@"[JLConstraint] === %@ ===", NSStringFromClass([view class]));
    NSLog(@"[JLConstraint]   Frame: %.0f x %.0f at (%.0f, %.0f)",
          view.frame.size.width, view.frame.size.height,
          view.frame.origin.x, view.frame.origin.y);
    NSLog(@"[JLConstraint]   Intrinsic: %.0f x %.0f %@",
          intrinsic.width, intrinsic.height,
          (intrinsic.width == NSViewNoIntrinsicMetric && intrinsic.height == NSViewNoIntrinsicMetric)
            ? @"(NoIntrinsic - GOOD)" : @"<-- HAS INTRINSIC SIZE");
    NSLog(@"[JLConstraint]   Hugging: H=%.0f V=%.0f %@",
          huggingH, huggingV,
          (huggingH >= 750 || huggingV >= 750) ? @"<-- HIGH!" : @"");
    NSLog(@"[JLConstraint]   Compression: H=%.0f V=%.0f %@",
          compressionH, compressionV,
          (compressionH >= 750 || compressionV >= 750) ? @"<-- HIGH! (causes snap-back)" : @"");

    // Log constraints
    NSLog(@"[JLConstraint]   Constraints (%lu):", (unsigned long)view.constraints.count);
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeWidth ||
            constraint.firstAttribute == NSLayoutAttributeHeight) {
            NSLog(@"[JLConstraint]     %@ priority=%.0f",
                  constraint, constraint.priority);
        }
    }
}

#pragma mark - Visual Highlighting

+ (void)highlightSuspectViews:(NSView *)rootView {
    NSArray<NSView *> *suspects = [self findSuspectViews:rootView];

    NSLog(@"[JLConstraint] Found %lu suspect views:", (unsigned long)suspects.count);

    for (NSView *view in suspects) {
        view.wantsLayer = YES;
        view.layer.borderWidth = 2.0;
        view.layer.borderColor = [NSColor redColor].CGColor;

        [self logSizingInfo:view];
    }
}

+ (void)removeHighlights:(NSView *)rootView {
    [self removeHighlightsRecursive:rootView];
}

+ (void)removeHighlightsRecursive:(NSView *)view {
    if (view.layer.borderWidth == 2.0 &&
        CGColorEqualToColor(view.layer.borderColor, [NSColor redColor].CGColor)) {
        view.layer.borderWidth = 0;
        view.layer.borderColor = NULL;
    }

    for (NSView *subview in view.subviews) {
        [self removeHighlightsRecursive:subview];
    }
}

@end

#pragma mark - Console Command Registration (optional)

// To use console commands, add this to your component's initquit:
//
// class mycomponent_initquit : public initquit {
// public:
//     void on_init() override {
//         [JLConstraintDebugger enable];
//     }
//     void on_quit() override {
//         [JLConstraintDebugger disable];
//     }
// };
// FB2K_SERVICE_FACTORY(mycomponent_initquit);
