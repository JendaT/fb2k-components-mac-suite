//
// JLDependencyGate.mm
//

#import "JLDependencyGate.h"

#include <foobar2000/SDK/foobar2000.h>

#include <spawn.h>
#include <unistd.h>

#include <algorithm>
#include <cmath>
#include <ctime>

using namespace jl_dep;

NSNotificationName const JLDependencyStateDidChange = @"JLDependencyStateDidChange";

namespace {

const char *const kResumeKey = "jl.dependency.resume";

const CGFloat kGateHeight = 62;     // the info line (two lines of 11 pt) and a row of buttons
const CGFloat kNotePadX = 8;
const CGFloat kNotePadY = 5;

std::string utf8(NSString *s) {
    return s ? std::string(s.UTF8String ?: "") : std::string();
}

NSString *megabytes(uint64_t bytes) {
    return [NSString stringWithFormat:@"%.1f MB", static_cast<double>(bytes) / (1024.0 * 1024.0)];
}

NSString *userComponentsFolder() {
    pfc::string8 native;
    try {
        native = filesystem::g_get_native_path(core_api::pathInProfile("user-components"));
    } catch (...) {
        return nil;
    }
    return native.length() ? [NSString stringWithUTF8String:native.c_str()] : nil;
}

} // namespace

// ---------------------------------------------------------------------------

@implementation JLDependencyManager {
    JLComponentInstaller *_installer;
    BOOL _working;
    NSString *_failedMessage;
    NSString *_message;
    double _progress;
    GateState _state;
}

+ (instancetype)managerForDescriptor:(JLDependencyDescriptor *)descriptor {
    static NSMutableDictionary<NSString *, JLDependencyManager *> *managers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ managers = [NSMutableDictionary dictionary]; });
    @synchronized(managers) {
        JLDependencyManager *m = managers[descriptor.component];
        if (!m) {
            m = [[JLDependencyManager alloc] initWithDescriptor:descriptor];
            managers[descriptor.component] = m;
        }
        return m;
    }
}

- (instancetype)initWithDescriptor:(JLDependencyDescriptor *)descriptor {
    if ((self = [super init])) {
        _descriptor = descriptor;
        _message = @"";
        _progress = -1;
        _state = GateState::Missing;
    }
    return self;
}

- (JLComponentInstaller *)installer {
    if (!_installer) {
        NSString *folder = userComponentsFolder();
        if (folder) _installer = [[JLComponentInstaller alloc] initWithDescriptor:_descriptor userComponents:folder];
    }
    return _installer;
}

- (GateState)state { return _state; }
- (NSString *)message { return _message; }
- (double)progress { return _progress; }

- (BOOL)needsGate {
    [self refresh];
    return _state != GateState::Available || _installedNote != nil;
}

- (void)post {
    [[NSNotificationCenter defaultCenter] postNotificationName:JLDependencyStateDidChange object:self];
}

- (void)refresh {
    JLDependencyDescriptor *d = _descriptor;
    const BOOL available = _serviceAvailable ? _serviceAvailable() : NO;
    NSString *onDisk = [[self installer] installedVersion];
    NSString *holder = _working ? nil : [[self installer] lockHolder];
    _state = gateState(available, parseVersion(utf8(onDisk)), parseVersion(utf8(d.minVersion)), _working,
                       _failedMessage != nil, holder != nil);
    NSString *feature = d.featureName.lowercaseString;
    switch (_state) {
        case GateState::Available:
            _message = _installedNote ?: @"";
            break;
        case GateState::Missing:
            _message = [NSString stringWithFormat:@"%@ need %@, a free component from the same suite.", d.featureName, d.displayName];
            break;
        case GateState::TooOld:
            _message = [NSString stringWithFormat:@"%@ %@ is installed; %@ need %@ or later.", d.displayName, onDisk, feature, d.minVersion];
            break;
        case GateState::RestartPending:
            _message = [NSString stringWithFormat:@"%@ %@ is installed. Restart foobar2000 to load it.", d.displayName, onDisk];
            break;
        case GateState::Working:
            break;   // the step, set as it goes
        case GateState::Failed:
            _message = _failedMessage;
            break;
        case GateState::BusyElsewhere:
            _message = [NSString stringWithFormat:@"%@ is being installed from %@...", d.displayName, holder];
            break;
    }
    [self post];
}

- (void)setStep:(NSString *)step progress:(double)progress {
    _message = step;
    _progress = progress;
    [self post];
}

#pragma mark - Install

- (void)startInstallFromWindow:(NSWindow *)window {
    if (_working) return;
    JLComponentInstaller *installer = [self installer];
    if (!installer) {
        _failedMessage = @"foobar2000's component folder could not be found.";
        [self refresh];
        return;
    }
    _failedMessage = nil;
    _installedNote = nil;
    _working = YES;
    [self refresh];
    [self setStep:@"Looking up the latest release..." progress:-1];
    __weak JLDependencyManager *weakSelf = self;
    [installer lookUp:^(JLReleaseInfo *release, NSString *error) {
        JLDependencyManager *me = weakSelf;
        if (!me) return;
        me->_working = NO;
        if (!release && !error) {   // cancelled
            [me refresh];
            return;
        }
        if (!release) {
            me->_failedMessage = error ?: @"The release could not be looked up.";
            [me refresh];
            return;
        }
        [me refresh];
        [me confirm:release window:window then:^{ [me install:release window:window]; }];
    }];
}

// The confirmation, with the real numbers
- (void)confirm:(JLReleaseInfo *)release window:(NSWindow *)window then:(void (^)(void))proceed {
    JLDependencyDescriptor *d = _descriptor;
    const BOOL update = [[self installer] installedVersion] != nil;
    NSString *folder = [[[self installer].installedBundlePath stringByDeletingLastPathComponent] stringByAbbreviatingWithTildeInPath];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = update ? [NSString stringWithFormat:@"Update %@ to %@?", d.displayName, release.version]
                               : [NSString stringWithFormat:@"Install %@ %@?", d.displayName, release.version];
    alert.informativeText = [NSString stringWithFormat:
        @"Downloads %@ (%@) from the GitHub release %@ of %@, checks it against the release's SHA-256 checksum "
        @"and installs it to %@.\n\nfoobar2000 then needs a restart to load it.",
        d.assetName, megabytes(release.packageSize), release.tag, d.repository, folder];
    [alert addButtonWithTitle:update ? @"Update" : @"Install"];
    [alert addButtonWithTitle:@"Cancel"];
    void (^answer)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) proceed();
    };
    // The lookup took a while: the page's window may have closed since
    NSWindow *host = window.isVisible ? window : NSApp.keyWindow;
    if (host) [alert beginSheetModalForWindow:host completionHandler:answer];
    else answer([alert runModal]);
}

- (void)install:(JLReleaseInfo *)release window:(NSWindow *)window {
    _working = YES;
    [self refresh];
    [self setStep:@"Starting..." progress:-1];
    __weak JLDependencyManager *weakSelf = self;
    [[self installer] install:release
        progress:^(NSString *step, double fraction) { [weakSelf setStep:step progress:fraction]; }
        done:^(NSString *error, BOOL cancelled) {
            JLDependencyManager *me = weakSelf;
            if (!me) return;
            me->_working = NO;
            if (cancelled) {
                [me refresh];
                return;
            }
            if (error) {
                me->_failedMessage = error;
                [me refresh];
                return;
            }
            [me writeResumeNote:release.version];
            [me refresh];
            [me askRestart:release.version window:window];
        }];
}

- (void)askRestart:(NSString *)version window:(NSWindow *)window {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"%@ %@ is installed.", _descriptor.displayName, version];
    alert.informativeText = @"Restart foobar2000 now to load it?";
    [alert addButtonWithTitle:@"Restart Now"];
    [alert addButtonWithTitle:@"Later"];
    __weak JLDependencyManager *weakSelf = self;
    void (^answer)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) [weakSelf restartFoobar];
    };
    // The page that asked may be gone; any key window will do
    NSWindow *host = window.isVisible ? window : NSApp.keyWindow;
    if (host) [alert beginSheetModalForWindow:host completionHandler:answer];
    else answer([alert runModal]);
}

- (void)cancel {
    [[self installer] cancel];
}

- (void)openReleasesPage {
    NSURL *url = [NSURL URLWithString:_descriptor.releasesPageURL];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark - Restart and resume

// foobar2000's own restart command where the host has one; else a detached
// shell that waits (two minutes at most) for this process to end and opens
// the app again. The app's path is the shell's $0, never part of the script.
- (void)restartFoobar {
    if (standard_commands::main_restart()) return;
    NSString *app = [NSBundle mainBundle].bundlePath;
    const std::string script = "i=0; while /bin/kill -0 " + std::to_string(getpid()) +
                               " 2>/dev/null; do i=$((i+1)); [ $i -gt 600 ] && exit 0; /bin/sleep 0.2; done; "
                               "/usr/bin/open \"$0\"";
    const std::string appPath = utf8(app);
    char *argv[] = { const_cast<char *>("/bin/sh"), const_cast<char *>("-c"), const_cast<char *>(script.c_str()),
                     const_cast<char *>(appPath.c_str()), nullptr };
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // Its own session, and none of this process's open files
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t child = 0;
    const int spawned = posix_spawn(&child, "/bin/sh", nullptr, &attr, argv, nullptr);
    posix_spawnattr_destroy(&attr);
    if (spawned != 0) {
        _failedMessage = @"foobar2000 could not restart itself; quit and open it again.";
        [self refresh];
        return;
    }
    if (!standard_commands::main_exit()) [NSApp terminate:nil];
}

- (void)writeResumeNote:(NSString *)version {
    ResumeNote note;
    note.component = utf8(_descriptor.component);
    note.pageGuid = utf8(_preferencesPageGUID);
    note.dependent = utf8(_descriptor.dependentName);
    note.version = utf8(version);
    note.timestamp = static_cast<int64_t>(std::time(nullptr));
    fb2k::configStore::get()->setConfigString(kResumeKey, encodeResume(note).c_str());
}

- (void)resumeAfterLaunch {
    [[self installer] cleanUpAtLaunch];
    auto store = fb2k::configStore::get();
    const std::string text = store->getConfigString(kResumeKey)->c_str();
    ResumeNote note;
    // Only the dependent that installed it resumes: its page, its feature
    if (text.empty() || !decodeResume(text, note) || note.component != utf8(_descriptor.component) ||
        note.dependent != utf8(_descriptor.dependentName)) {
        return;
    }
    store->deleteConfigString(kResumeKey);
    if (!resumeIsFresh(note, static_cast<int64_t>(std::time(nullptr)))) return;
    NSString *version = [NSString stringWithUTF8String:note.version.c_str()] ?: @"";
    const GUID page = pfc::GUID_from_text(note.pageGuid.c_str());
    // Once the main window is up
    __weak JLDependencyManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        JLDependencyManager *me = weakSelf;
        if (!me) return;
        if (me.serviceAvailable && me.serviceAvailable()) {
            if (me.enableFeature) me.enableFeature();
            me->_installedNote = [NSString stringWithFormat:@"%@ %@ installed.", me.descriptor.displayName, version];
        } else {
            me->_failedMessage = @"Installed, but foobar2000 did not load it.";
        }
        [me refresh];
        ui_control::ptr ui;
        if (page != pfc::guid_null && fb2k::std_api_try_get(ui)) ui->show_preferences(page);
    });
}

@end

// ---------------------------------------------------------------------------

@implementation JLDependencyGate {
    JLDependencyManager *_manager;
    NSTextField *_label;
    NSButton *_primary;
    NSButton *_secondary;
    NSProgressIndicator *_bar;
    NSTimer *_poll;
}

- (BOOL)showsNote {
    return _manager.state == GateState::Available && _manager.installedNote;
}

- (CGFloat)noteTextHeight {
    const NSRect bounds = NSMakeRect(0, 0, std::max<CGFloat>(1, self.bounds.size.width - 2 * kNotePadX), CGFLOAT_MAX);
    return std::ceil([_label.cell cellSizeForBounds:bounds].height);
}

- (CGFloat)preferredHeight {
    return [self showsNote] ? [self noteTextHeight] + 2 * kNotePadY : kGateHeight;
}

- (BOOL)isFlipped {
    return YES;
}

- (instancetype)initWithFrame:(NSRect)frame manager:(JLDependencyManager *)manager {
    if ((self = [super initWithFrame:frame])) {
        _manager = manager;
        _label = [NSTextField wrappingLabelWithString:@""];
        _label.font = [NSFont systemFontOfSize:11];
        _label.textColor = [NSColor secondaryLabelColor];
        _label.frame = NSMakeRect(0, 0, frame.size.width, 30);
        [self addSubview:_label];
        _primary = [NSButton buttonWithTitle:@"" target:self action:@selector(primaryClicked:)];
        _secondary = [NSButton buttonWithTitle:@"" target:self action:@selector(secondaryClicked:)];
        [self addSubview:_primary];
        [self addSubview:_secondary];
        _bar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
        _bar.style = NSProgressIndicatorStyleBar;
        _bar.controlSize = NSControlSizeSmall;
        _bar.minValue = 0;
        _bar.maxValue = 1;
        [self addSubview:_bar];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stateChanged:)
                                                     name:JLDependencyStateDidChange object:manager];
        [_manager refresh];
        [self update];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_poll invalidate];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        [_poll invalidate];
        _poll = nil;
        return;
    }
    // Just installed (or failed to load): bring the gate into view
    if (_manager.installedNote || _manager.state == GateState::Failed) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self scrollRectToVisible:self.bounds]; });
    }
}

- (void)stateChanged:(NSNotification *)note {
    [self update];
}

- (void)placeButton:(NSButton *)button title:(NSString *)title x:(CGFloat *)x {
    button.title = title;
    [button sizeToFit];
    button.frameOrigin = NSMakePoint(*x, 30);
    button.hidden = NO;
    *x += button.frame.size.width + 4;
}

- (void)update {
    const GateState state = _manager.state;
    const CGFloat width = self.bounds.size.width;
    _label.stringValue = _manager.message ?: @"";
    const BOOL note = [self showsNote];
    // The note sits inside its tint; the other states start at the left edge
    // like the hints above
    _label.frame = note ? NSMakeRect(kNotePadX, kNotePadY, width - 2 * kNotePadX, [self noteTextHeight])
                        : NSMakeRect(0, 0, width, 30);
    _label.textColor = note ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    self.wantsLayer = YES;
    self.layer.cornerRadius = 4;
    self.layer.backgroundColor = note ? [[NSColor controlAccentColor] colorWithAlphaComponent:0.12].CGColor : nil;

    _primary.hidden = YES;
    _secondary.hidden = YES;
    _bar.hidden = YES;
    CGFloat x = -6;   // push buttons' bezels sit inside their frames
    JLDependencyDescriptor *d = _manager.descriptor;
    switch (state) {
        case GateState::Missing:
            [self placeButton:_primary title:[NSString stringWithFormat:@"Install %@...", d.displayName] x:&x];
            break;
        case GateState::TooOld:
            [self placeButton:_primary title:[NSString stringWithFormat:@"Update %@...", d.displayName] x:&x];
            break;
        case GateState::RestartPending:
            [self placeButton:_primary title:@"Restart foobar2000" x:&x];
            break;
        case GateState::Failed:
            [self placeButton:_primary title:@"Try Again" x:&x];
            [self placeButton:_secondary title:@"Open Releases Page" x:&x];
            break;
        case GateState::Working: {
            _secondary.title = @"Cancel";
            [_secondary sizeToFit];
            const CGFloat cancelWidth = _secondary.frame.size.width;
            _secondary.frameOrigin = NSMakePoint(width - cancelWidth + 6, 30);
            _secondary.hidden = NO;
            _bar.frame = NSMakeRect(0, 37, std::max<CGFloat>(40, width - cancelWidth - 8), 12);
            _bar.hidden = NO;
            const double p = _manager.progress;
            _bar.indeterminate = p < 0;
            if (p < 0) [_bar startAnimation:nil];
            else {
                [_bar stopAnimation:nil];
                _bar.doubleValue = p;
            }
            break;
        }
        case GateState::BusyElsewhere:
        case GateState::Available:
            break;
    }
    // Another dependent's install ends without telling this one: look again
    if (state == GateState::BusyElsewhere && !_poll && self.window) {
        __weak JLDependencyManager *manager = _manager;
        _poll = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *) { [manager refresh]; }];
    } else if (state != GateState::BusyElsewhere) {
        [_poll invalidate];
        _poll = nil;
    }
}

- (void)primaryClicked:(id)sender {
    switch (_manager.state) {
        case GateState::RestartPending: [_manager restartFoobar]; break;
        default: [_manager startInstallFromWindow:self.window]; break;
    }
}

- (void)secondaryClicked:(id)sender {
    if (_manager.state == GateState::Working) [_manager cancel];
    else [_manager openReleasesPage];
}

@end
