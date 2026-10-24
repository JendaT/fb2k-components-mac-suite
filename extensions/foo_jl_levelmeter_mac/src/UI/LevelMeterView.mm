//
//  LevelMeterView.mm
//  foo_jl_levelmeter_mac
//

#import "LevelMeterView.h"
#import "MeterRenderer.h"
#include "../Core/LevelMeterConfig.h"
#include "../../../../shared/UIStyles.h"

@implementation LevelMeterView {
    meter::MeterRenderer _renderer;
    meter::DisplaySettings _settings;
    meter::Snapshot _snapshot;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        [self reloadSettings];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }   // the renderer works top-down
- (BOOL)isOpaque { return NO; }

- (void)reloadSettings {
    _settings = levelmeter_config::loadDisplaySettings(fb2k_ui::isDarkMode());
    [self setNeedsDisplay:YES];
}

- (void)showSnapshot:(const meter::Snapshot &)snapshot {
    _snapshot = snapshot;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    _renderer.draw(ctx, self.bounds, _settings, _snapshot);
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self reloadSettings];
}

#pragma mark - Mouse

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)mouseDown:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagControl) {
        [self rightMouseDown:event];  // ctrl-click opens the context menu
        return;
    }
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    switch (_renderer.hitTest(p)) {
        case meter::HitArea::Peaks:
            [self.delegate levelMeterViewResetPeaks:self];
            break;
        case meter::HitArea::Loudness:
            [self.delegate levelMeterViewResetLoudness:self];
            break;
        default:
            [super mouseDown:event];
            break;
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    if ([self.delegate respondsToSelector:@selector(levelMeterViewRequestsContextMenu:atPoint:)]) {
        [self.delegate levelMeterViewRequestsContextMenu:self atPoint:pt];
    } else {
        [super rightMouseDown:event];
    }
}

@end
