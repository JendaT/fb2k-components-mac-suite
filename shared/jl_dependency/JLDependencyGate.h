//
// JLDependencyGate.h - a settings section that needs another suite
// component, and installing that component from right there.
//
// JLDependencyManager keeps one dependency's install flow (look up the
// release, confirm with real numbers, download, verify, install, restart)
// and outlives preferences pages, which rebuild their views. JLDependencyGate
// is the view a page puts under the section: what is missing or happening,
// and the button for the next step. Install only on an explicit click.
//
// Across the restart a resume note in the configuration (jl.dependency.resume)
// lets the dependent switch the feature on, reopen its preferences page and
// say the install worked, or that foobar2000 did not load the component.
//
// Objective-C++, AppKit and the foobar2000 SDK. A component compiles it
// through a one-line .mm of its own that includes JLDependencyGate.mm and
// JLComponentInstaller.mm.
//

#pragma once

#import <Cocoa/Cocoa.h>

#import "JLComponentInstaller.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const JLDependencyStateDidChange;   // object: the manager; main thread

@interface JLDependencyManager : NSObject

// The one manager for the descriptor's component
+ (instancetype)managerForDescriptor:(JLDependencyDescriptor *)descriptor;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) JLDependencyDescriptor *descriptor;
// Whether the component's service resolves (it is loaded and new enough)
@property (nonatomic, copy, nullable) BOOL (^serviceAvailable)(void);
// After the install and restart: the page to reopen, "{...}" or bare
@property (nonatomic, copy, nullable) NSString *preferencesPageGUID;
// After the install and restart, once the service resolves: switch the
// feature on (the dependent's own setting)
@property (nonatomic, copy, nullable) void (^enableFeature)(void);

@property (nonatomic, readonly) jl_dep::GateState state;
@property (nonatomic, readonly, copy) NSString *message;              // the gate's info line
@property (nonatomic, readonly) double progress;                       // 0..1; negative when unknown
@property (nonatomic, readonly, copy, nullable) NSString *installedNote;   // "BPM Analyzer 0.1.0 installed." after the restart

// Whether the page should show a gate at all: anything but available, or
// the note after an install
- (BOOL)needsGate;
// Recomputes the state from disk, the lock and the service
- (void)refresh;

- (void)startInstallFromWindow:(nullable NSWindow *)window;
- (void)cancel;
- (void)restartFoobar;
- (void)openReleasesPage;

// At launch (the dependent's initquit::on_init): removes bundles an update
// set aside, and acts on a fresh resume note for this component
- (void)resumeAfterLaunch;

@end

// The gate under a settings section; size it with preferredHeight
@interface JLDependencyGate : NSView
- (instancetype)initWithFrame:(NSRect)frame manager:(JLDependencyManager *)manager;
+ (CGFloat)preferredHeight;
@end

NS_ASSUME_NONNULL_END
