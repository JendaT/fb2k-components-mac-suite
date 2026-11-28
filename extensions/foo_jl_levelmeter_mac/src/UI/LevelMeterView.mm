//
//  LevelMeterView.mm
//  foo_jl_levelmeter_mac
//

#import "LevelMeterView.h"
#import "MeterRenderer.h"
#include "../Core/LevelMeterConfig.h"
#include "../../../../shared/UIStyles.h"

// Transparent view over the meter for the parts that change every frame.
// The overlay view above it uses the same class.
@interface LevelMeterLiveView : NSView
@property (nonatomic, copy, nullable) void (^drawHandler)(void);
@end

@implementation LevelMeterLiveView
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }  // clicks go to the meter view
- (void)drawRect:(NSRect)dirtyRect {
    if (self.drawHandler) self.drawHandler();
}
@end

// The view draws the background, scales and names, which only change with
// the settings or the size; the live view above it draws the readings.
// Redrawing the scale text every frame cost more main-thread time than the
// readings themselves. The overlay view on top holds what the analog faces
// draw over their needles (pivot, glass, window shadow); it changes when the
// view does, not every frame.
@implementation LevelMeterView {
    meter::MeterRenderer _renderer;
    meter::DisplaySettings _settings;
    meter::Snapshot _snapshot;
    LevelMeterLiveView *_liveView;
    LevelMeterLiveView *_overlayView;
    bool _mono;   // last snapshot's source was mono (analog shows one face)
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;

        _liveView = [[LevelMeterLiveView alloc] initWithFrame:self.bounds];
        _liveView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _liveView.wantsLayer = YES;
        _liveView.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        __weak typeof(self) weakSelf = self;
        _liveView.drawHandler = ^{ [weakSelf drawPass:meter::Pass::Live]; };
        [self addSubview:_liveView];

        _overlayView = [[LevelMeterLiveView alloc] initWithFrame:self.bounds];
        _overlayView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _overlayView.wantsLayer = YES;
        _overlayView.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
        _overlayView.drawHandler = ^{ [weakSelf drawPass:meter::Pass::Overlay]; };
        [self addSubview:_overlayView];

        _mono = _snapshot.channels == 1;

        [self reloadSettings];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }   // the renderer works top-down
- (BOOL)isOpaque { return NO; }

- (void)reloadSettings {
    _settings = levelmeter_config::loadDisplaySettings(fb2k_ui::isDarkMode());
    [self setNeedsDisplay:YES];
    [_liveView setNeedsDisplay:YES];
    [_overlayView setNeedsDisplay:YES];
}

- (void)showSnapshot:(const meter::Snapshot &)snapshot {
    _snapshot = snapshot;
    // Mono and stereo sources lay the analog faces out differently, so the
    // still layers follow a change.
    const bool mono = snapshot.channels == 1;
    if (mono != _mono) {
        _mono = mono;
        [self setNeedsDisplay:YES];
        [_overlayView setNeedsDisplay:YES];
    }
    [_liveView setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self setNeedsDisplay:YES];
    [_liveView setNeedsDisplay:YES];
    [_overlayView setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [self drawPass:meter::Pass::Static];
}

- (void)drawPass:(meter::Pass)pass {
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    _renderer.draw(ctx, self.bounds, _settings, _snapshot, pass);
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
