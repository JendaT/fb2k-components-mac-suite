//
//  ScrobbleStatusController.mm
//  foo_scrobble_mac
//
//  UI Element showing scrobble status in toolbar
//

#import "ScrobbleStatusController.h"
#import "../Core/ScrobbleNotifications.h"
#import "../LastFm/LastFmAuth.h"
#import "../Services/ScrobbleService.h"
#import "../Services/ScrobbleCache.h"

@interface ScrobbleStatusController ()
@property (nonatomic, strong) NSTextField *userLabel;
@property (nonatomic, strong) NSTextField *statsLabel;
@property (nonatomic, strong) NSImageView *statusIcon;
@end

@implementation ScrobbleStatusController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(stateChanged:)
                                                     name:LastFmAuthStateDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(stateChanged:)
                                                     name:ScrobbleCacheDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(stateChanged:)
                                                     name:ScrobbleServiceStateDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(stateChanged:)
                                                     name:ScrobbleServiceDidScrobbleNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView {
    // Create compact horizontal container
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 180, 40)];

    // Status icon (Last.fm logo or indicator)
    self.statusIcon = [[NSImageView alloc] init];
    self.statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    // Use system symbol for music.note as placeholder
    if (@available(macOS 11.0, *)) {
        self.statusIcon.image = [NSImage imageWithSystemSymbolName:@"music.note"
                                          accessibilityDescription:@"Last.fm Scrobbler"];
    }
    self.statusIcon.contentTintColor = [NSColor secondaryLabelColor];
    [container addSubview:self.statusIcon];

    // User label (username or status)
    self.userLabel = [NSTextField labelWithString:@"Last.fm"];
    self.userLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.userLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.userLabel.textColor = [NSColor labelColor];
    self.userLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [container addSubview:self.userLabel];

    // Stats label (queue + session stats)
    self.statsLabel = [NSTextField labelWithString:@""];
    self.statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statsLabel.font = [NSFont systemFontOfSize:10];
    self.statsLabel.textColor = [NSColor secondaryLabelColor];
    self.statsLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [container addSubview:self.statsLabel];

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        // Icon on the left
        [self.statusIcon.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.statusIcon.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [self.statusIcon.widthAnchor constraintEqualToConstant:16],
        [self.statusIcon.heightAnchor constraintEqualToConstant:16],

        // User label top right of icon
        [self.userLabel.leadingAnchor constraintEqualToAnchor:self.statusIcon.trailingAnchor constant:6],
        [self.userLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [self.userLabel.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-8],

        // Stats label below user label
        [self.statsLabel.leadingAnchor constraintEqualToAnchor:self.userLabel.leadingAnchor],
        [self.statsLabel.topAnchor constraintEqualToAnchor:self.userLabel.bottomAnchor constant:2],
        [self.statsLabel.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-8],
    ]];

    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self updateUI];
}

- (void)updateUI {
    LastFmAuth *auth = [LastFmAuth shared];

    // Update user label
    if (auth.isAuthenticated) {
        self.userLabel.stringValue = auth.username ?: @"Last.fm";
        self.userLabel.textColor = [NSColor labelColor];
        if (@available(macOS 11.0, *)) {
            self.statusIcon.contentTintColor = [NSColor systemGreenColor];
        }
    } else {
        self.userLabel.stringValue = @"Not signed in";
        self.userLabel.textColor = [NSColor secondaryLabelColor];
        if (@available(macOS 11.0, *)) {
            self.statusIcon.contentTintColor = [NSColor secondaryLabelColor];
        }
    }

    // Update stats label
    NSUInteger pending = [[ScrobbleCache shared] pendingCount];
    NSUInteger sessionCount = [[ScrobbleService shared] sessionScrobbleCount];

    NSMutableArray *parts = [NSMutableArray array];
    if (pending > 0) {
        [parts addObject:[NSString stringWithFormat:@"%lu queued", (unsigned long)pending]];
    }
    if (sessionCount > 0) {
        [parts addObject:[NSString stringWithFormat:@"%lu scrobbled", (unsigned long)sessionCount]];
    }

    if (parts.count > 0) {
        self.statsLabel.stringValue = [parts componentsJoinedByString:@" | "];
    } else {
        self.statsLabel.stringValue = @"Ready";
    }
}

- (void)stateChanged:(NSNotification *)notification {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf updateUI];
    });
}

@end
