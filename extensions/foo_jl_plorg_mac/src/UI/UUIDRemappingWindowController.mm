//
//  UUIDRemappingWindowController.mm
//  foo_plorg_mac
//
//  Network Volume UUID Remapping Tool
//

#import "UUIDRemappingWindowController.h"
#import "../Core/PlorgVolumeSyncLogic.h"
#import <objc/runtime.h>
#import <DiskArbitration/DiskArbitration.h>
#include <sys/mount.h>

#pragma mark - Constants

static const NSUInteger kMaxBackupDirectories = 5;
// mac-volume:// prefix comes from PlorgVolumeSyncLogic (PlorgMacVolumePrefix)

#pragma mark - VolumeUUIDEntry Implementation

@implementation VolumeUUIDEntry

- (instancetype)initWithUUID:(NSString *)uuid
                  entryCount:(NSUInteger)entryCount
                    isActive:(BOOL)isActive
                   mountPath:(NSString *)mountPath
       affectedPlaylistPaths:(NSSet<NSString *> *)paths
          perPlaylistCounts:(NSDictionary<NSString *, NSNumber *> *)perPlaylistCounts {
    self = [super init];
    if (self) {
        _uuid = [uuid copy];
        _entryCount = entryCount;
        _isActive = isActive;
        _mountPath = [mountPath copy];
        _affectedPlaylistPaths = [paths copy];
        _perPlaylistCounts = [perPlaylistCounts copy];
    }
    return self;
}

- (NSUInteger)entryCountForPlaylist:(NSString *)playlistPath {
    NSNumber *count = self.perPlaylistCounts[playlistPath];
    return count ? count.unsignedIntegerValue : 0;
}

- (NSString *)shortUUID {
    if (self.uuid.length >= 13) {
        return [self.uuid substringToIndex:13];
    }
    return self.uuid;
}

@end

#pragma mark - Private Interface

@interface UUIDRemappingWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate>

// UI Elements
@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *scanButton;
@property (nonatomic, strong) NSButton *applyButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSScrollView *scrollView;

// Scope selection
@property (nonatomic, strong) NSButton *singlePlaylistRadio;
@property (nonatomic, strong) NSButton *allPlaylistsRadio;
@property (nonatomic, strong) NSTextField *affectedPlaylistsLabel;

// Target UUID input
@property (nonatomic, strong) NSTextField *targetLabel;
@property (nonatomic, strong) NSTextField *targetUUIDField;
@property (nonatomic, strong) NSButton *browseButton;

// State
@property (nonatomic, copy) NSString *playlistsDir;
@property (nonatomic, copy, nullable) NSString *singlePlaylistPath;
@property (nonatomic, copy, nullable) NSString *singlePlaylistName;
@property (nonatomic, strong) NSMutableArray<VolumeUUIDEntry *> *allUUIDEntries;      // All entries from scan
@property (nonatomic, strong) NSMutableArray<VolumeUUIDEntry *> *displayedUUIDEntries; // Filtered for current scope
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedUUIDs;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *activeVolumeUUIDs;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *playlistFileUUIDToName;  // Maps file UUID to display name
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *uuidSamplePaths;  // Maps volume UUID to first validated sample path from scan
@property (nonatomic, assign) BOOL useSinglePlaylist;

// Scanning state
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, assign) BOOL shouldStop;
@property (nonatomic, assign) BOOL isApplying;
@property (nonatomic, assign) BOOL didNotifyDelegate;
@property (nonatomic, assign) NSInteger scannedCount;
@property (nonatomic, assign) NSInteger totalCount;
@property (nonatomic, assign) NSInteger malformedCount;

@end

@implementation UUIDRemappingWindowController

#pragma mark - Initialization

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 700, 550)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = NSLocalizedString(@"Repair Volume UUIDs", @"Window title");
    window.minSize = NSMakeSize(600, 450);
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        window.delegate = self;
        _allUUIDEntries = [NSMutableArray array];
        _displayedUUIDEntries = [NSMutableArray array];
        _selectedUUIDs = [NSMutableSet set];
        _useSinglePlaylist = NO;
        [self setupUI];
    }
    return self;
}

#pragma mark - UI Setup

- (void)setupUI {
    NSView *contentView = self.window.contentView;

    // Title label
    NSTextField *titleLabel = [NSTextField labelWithString:NSLocalizedString(@"Repair orphaned volume UUIDs in playlists", @"Title")];
    titleLabel.font = [NSFont boldSystemFontOfSize:13];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:titleLabel];

    // Progress bar
    self.progressBar = [[NSProgressIndicator alloc] init];
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0;
    self.progressBar.maxValue = 100;
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.progressBar];

    // Scan button
    self.scanButton = [NSButton buttonWithTitle:NSLocalizedString(@"Rescan", @"Scan button") target:self action:@selector(startScan:)];
    self.scanButton.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.scanButton];

    // Status label
    self.statusLabel = [NSTextField labelWithString:NSLocalizedString(@"Scanning...", @"Initial status")];
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.statusLabel];

    // === Scope Selection ===
    NSBox *scopeBox = [[NSBox alloc] init];
    scopeBox.title = NSLocalizedString(@"Scope", @"Scope box title");
    scopeBox.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:scopeBox];

    self.singlePlaylistRadio = [NSButton radioButtonWithTitle:NSLocalizedString(@"This playlist:", @"Single playlist radio")
                                                       target:self action:@selector(scopeChanged:)];
    self.singlePlaylistRadio.translatesAutoresizingMaskIntoConstraints = NO;
    self.singlePlaylistRadio.state = NSControlStateValueOff;
    [scopeBox.contentView addSubview:self.singlePlaylistRadio];

    self.allPlaylistsRadio = [NSButton radioButtonWithTitle:NSLocalizedString(@"All playlists", @"All playlists radio")
                                                     target:self action:@selector(scopeChanged:)];
    self.allPlaylistsRadio.translatesAutoresizingMaskIntoConstraints = NO;
    self.allPlaylistsRadio.state = NSControlStateValueOn;
    [scopeBox.contentView addSubview:self.allPlaylistsRadio];

    self.affectedPlaylistsLabel = [NSTextField labelWithString:@""];
    self.affectedPlaylistsLabel.font = [NSFont systemFontOfSize:10];
    self.affectedPlaylistsLabel.textColor = [NSColor secondaryLabelColor];
    self.affectedPlaylistsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.affectedPlaylistsLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.affectedPlaylistsLabel.maximumNumberOfLines = 0;  // No limit
    self.affectedPlaylistsLabel.preferredMaxLayoutWidth = 500;  // Allow wrapping
    [self.affectedPlaylistsLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [scopeBox.contentView addSubview:self.affectedPlaylistsLabel];

    // === Target UUID Input ===
    self.targetLabel = [NSTextField labelWithString:NSLocalizedString(@"Remap to UUID:", @"Target label")];
    self.targetLabel.font = [NSFont systemFontOfSize:12];
    self.targetLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.targetLabel];

    self.targetUUIDField = [[NSTextField alloc] init];
    self.targetUUIDField.placeholderString = NSLocalizedString(@"Enter UUID or browse to select volume...", @"UUID placeholder");
    self.targetUUIDField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.targetUUIDField.translatesAutoresizingMaskIntoConstraints = NO;
    self.targetUUIDField.delegate = self;
    [contentView addSubview:self.targetUUIDField];

    self.browseButton = [NSButton buttonWithTitle:NSLocalizedString(@"Browse...", @"Browse button") target:self action:@selector(browseForVolume:)];
    self.browseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.browseButton];

    // === Table view ===
    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    self.tableView = [[NSTableView alloc] init];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.allowsMultipleSelection = YES;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.rowHeight = 24;
    self.tableView.doubleAction = @selector(tableViewDoubleClicked:);
    self.tableView.target = self;

    // Columns
    NSTableColumn *selectColumn = [[NSTableColumn alloc] initWithIdentifier:@"SelectColumn"];
    selectColumn.title = @"";
    selectColumn.width = 30;
    selectColumn.minWidth = 30;
    selectColumn.maxWidth = 30;
    [self.tableView addTableColumn:selectColumn];

    NSTableColumn *uuidColumn = [[NSTableColumn alloc] initWithIdentifier:@"UUIDColumn"];
    uuidColumn.title = NSLocalizedString(@"Volume UUID", @"Column header");
    uuidColumn.width = 280;
    uuidColumn.minWidth = 150;
    [self.tableView addTableColumn:uuidColumn];

    NSTableColumn *countColumn = [[NSTableColumn alloc] initWithIdentifier:@"CountColumn"];
    countColumn.title = NSLocalizedString(@"Entries", @"Column header");
    countColumn.width = 70;
    countColumn.minWidth = 50;
    [self.tableView addTableColumn:countColumn];

    NSTableColumn *playlistsColumn = [[NSTableColumn alloc] initWithIdentifier:@"PlaylistsColumn"];
    playlistsColumn.title = NSLocalizedString(@"Playlists", @"Column header");
    playlistsColumn.width = 70;
    playlistsColumn.minWidth = 50;
    [self.tableView addTableColumn:playlistsColumn];

    NSTableColumn *statusColumn = [[NSTableColumn alloc] initWithIdentifier:@"StatusColumn"];
    statusColumn.title = NSLocalizedString(@"Status", @"Column header");
    statusColumn.width = 150;
    statusColumn.minWidth = 80;
    [self.tableView addTableColumn:statusColumn];

    self.scrollView.documentView = self.tableView;
    [contentView addSubview:self.scrollView];

    // Bottom buttons
    self.cancelButton = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel", @"Cancel button") target:self action:@selector(cancel:)];
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.cancelButton];

    self.applyButton = [NSButton buttonWithTitle:NSLocalizedString(@"Apply", @"Apply button") target:self action:@selector(applyRemapping:)];
    self.applyButton.bezelStyle = NSBezelStyleRounded;
    self.applyButton.keyEquivalent = @"\r";
    self.applyButton.enabled = NO;
    self.applyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.applyButton];

    // Layout
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:16],
        [titleLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],

        [self.progressBar.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:12],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:self.scanButton.leadingAnchor constant:-12],

        [self.scanButton.centerYAnchor constraintEqualToAnchor:self.progressBar.centerYAnchor],
        [self.scanButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
        [self.scanButton.widthAnchor constraintEqualToConstant:80],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:4],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],

        // Scope box
        [scopeBox.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:12],
        [scopeBox.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [scopeBox.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
        [scopeBox.heightAnchor constraintGreaterThanOrEqualToConstant:90],

        [self.singlePlaylistRadio.topAnchor constraintEqualToAnchor:scopeBox.contentView.topAnchor constant:8],
        [self.singlePlaylistRadio.leadingAnchor constraintEqualToAnchor:scopeBox.contentView.leadingAnchor constant:8],
        [self.singlePlaylistRadio.trailingAnchor constraintEqualToAnchor:scopeBox.contentView.trailingAnchor constant:-8],

        [self.allPlaylistsRadio.topAnchor constraintEqualToAnchor:self.singlePlaylistRadio.bottomAnchor constant:4],
        [self.allPlaylistsRadio.leadingAnchor constraintEqualToAnchor:scopeBox.contentView.leadingAnchor constant:8],

        [self.affectedPlaylistsLabel.topAnchor constraintEqualToAnchor:self.allPlaylistsRadio.bottomAnchor constant:4],
        [self.affectedPlaylistsLabel.leadingAnchor constraintEqualToAnchor:scopeBox.contentView.leadingAnchor constant:24],
        [self.affectedPlaylistsLabel.trailingAnchor constraintEqualToAnchor:scopeBox.contentView.trailingAnchor constant:-8],
        [self.affectedPlaylistsLabel.bottomAnchor constraintLessThanOrEqualToAnchor:scopeBox.contentView.bottomAnchor constant:-8],

        // Target UUID row
        [self.targetLabel.topAnchor constraintEqualToAnchor:scopeBox.bottomAnchor constant:12],
        [self.targetLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],

        [self.targetUUIDField.centerYAnchor constraintEqualToAnchor:self.targetLabel.centerYAnchor],
        [self.targetUUIDField.leadingAnchor constraintEqualToAnchor:self.targetLabel.trailingAnchor constant:8],
        [self.targetUUIDField.trailingAnchor constraintEqualToAnchor:self.browseButton.leadingAnchor constant:-8],

        [self.browseButton.centerYAnchor constraintEqualToAnchor:self.targetLabel.centerYAnchor],
        [self.browseButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
        [self.browseButton.widthAnchor constraintEqualToConstant:80],

        // Table
        [self.scrollView.topAnchor constraintEqualToAnchor:self.targetLabel.bottomAnchor constant:12],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.cancelButton.topAnchor constant:-16],

        // Bottom buttons
        [self.cancelButton.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-16],
        [self.cancelButton.trailingAnchor constraintEqualToAnchor:self.applyButton.leadingAnchor constant:-12],

        [self.applyButton.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-16],
        [self.applyButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
    ]];
}

#pragma mark - Public API

- (void)beginScanningWithPlaylistsDir:(NSString *)playlistsDir {
    [self beginScanningWithPlaylistsDir:playlistsDir singlePlaylistPath:nil singlePlaylistName:nil];
}

- (void)beginScanningWithPlaylistsDir:(NSString *)playlistsDir
                   singlePlaylistPath:(NSString *)playlistPath
                   singlePlaylistName:(NSString *)playlistName {
    self.playlistsDir = playlistsDir;
    self.singlePlaylistPath = playlistPath;

    if (playlistPath && playlistName) {
        self.singlePlaylistName = playlistName;
        self.useSinglePlaylist = YES;
        self.singlePlaylistRadio.title = [NSString stringWithFormat:@"This playlist: %@", playlistName];
        self.singlePlaylistRadio.state = NSControlStateValueOn;
        self.allPlaylistsRadio.state = NSControlStateValueOff;
    } else {
        self.singlePlaylistName = nil;
        self.useSinglePlaylist = NO;
        self.singlePlaylistRadio.title = NSLocalizedString(@"This playlist: (none selected)", @"No playlist");
        self.singlePlaylistRadio.enabled = NO;
        self.allPlaylistsRadio.state = NSControlStateValueOn;
    }

    [self showWindow:nil];
    [self startScan:nil];
}

#pragma mark - Actions

- (void)scopeChanged:(id)sender {
    if (sender == self.singlePlaylistRadio) {
        self.useSinglePlaylist = YES;
        self.singlePlaylistRadio.state = NSControlStateValueOn;
        self.allPlaylistsRadio.state = NSControlStateValueOff;
    } else {
        self.useSinglePlaylist = NO;
        self.singlePlaylistRadio.state = NSControlStateValueOff;
        self.allPlaylistsRadio.state = NSControlStateValueOn;
    }
    [self filterEntriesForCurrentScope];
    [self.tableView reloadData];
    [self updateApplyButtonState];
}

- (void)filterEntriesForCurrentScope {
    [self.displayedUUIDEntries removeAllObjects];
    [self.selectedUUIDs removeAllObjects];

    if (self.useSinglePlaylist && self.singlePlaylistPath) {
        // Filter to only show UUIDs that appear in the single playlist
        for (VolumeUUIDEntry *entry in self.allUUIDEntries) {
            if ([entry.affectedPlaylistPaths containsObject:self.singlePlaylistPath]) {
                [self.displayedUUIDEntries addObject:entry];
                // Auto-select orphaned UUIDs
                if (!entry.isActive) {
                    [self.selectedUUIDs addObject:entry.uuid];
                }
            }
        }
    } else {
        // Show all UUIDs
        [self.displayedUUIDEntries addObjectsFromArray:self.allUUIDEntries];
        // Auto-select orphaned UUIDs
        for (VolumeUUIDEntry *entry in self.allUUIDEntries) {
            if (!entry.isActive) {
                [self.selectedUUIDs addObject:entry.uuid];
            }
        }
    }
}

- (void)tableViewDoubleClicked:(id)sender {
    NSInteger clickedRow = self.tableView.clickedRow;
    if (clickedRow < 0 || clickedRow >= (NSInteger)self.displayedUUIDEntries.count) {
        return;
    }

    VolumeUUIDEntry *entry = self.displayedUUIDEntries[clickedRow];

    // Only allow setting active UUIDs as target
    if (entry.isActive) {
        self.targetUUIDField.stringValue = entry.uuid;
        [self updateApplyButtonState];
    }
}

- (void)browseForVolume:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.message = NSLocalizedString(@"Select a mounted volume to get its UUID", @"Browse panel message");
    panel.prompt = NSLocalizedString(@"Select", @"Browse panel button");

    // Start at /Volumes
    panel.directoryURL = [NSURL fileURLWithPath:@"/Volumes"];

    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;

        NSURL *url = panel.URL;
        if (!url) return;

        // First get the volume URL for the selected path
        NSURL *volumeURL = nil;
        NSError *error = nil;
        [url getResourceValue:&volumeURL forKey:NSURLVolumeURLKey error:&error];

        if (!volumeURL) {
            volumeURL = url;  // Fallback to selected URL
        }

        NSString *uuid = nil;

        // Method 1: Try NSURL API
        [volumeURL getResourceValue:&uuid forKey:NSURLVolumeUUIDStringKey error:&error];

        // Method 2: Try DiskArbitration framework
        if (!uuid) {
            uuid = [weakSelf volumeUUIDForPath:volumeURL.path];
        }

        // Method 3: Look up in our cached mounted volumes by path
        if (!uuid) {
            NSString *volumePath = [[volumeURL.path stringByResolvingSymlinksInPath]
                                    stringByStandardizingPath];
            for (NSString *cachedUUID in weakSelf.activeVolumeUUIDs) {
                NSString *cachedPath = [[weakSelf.activeVolumeUUIDs[cachedUUID] stringByResolvingSymlinksInPath]
                                        stringByStandardizingPath];
                if ([cachedPath isEqualToString:volumePath]) {
                    uuid = cachedUUID;
                    break;
                }
            }
        }

        // Method 4: For network volumes, find UUID by scanning playlist files for paths matching this volume
        if (!uuid) {
            uuid = [weakSelf findUUIDForVolumePath:volumeURL.path];
        }

        if (uuid) {
            weakSelf.targetUUIDField.stringValue = [uuid uppercaseString];
            [weakSelf updateApplyButtonState];
        } else {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = NSLocalizedString(@"Could not get volume UUID", @"Error title");
            alert.informativeText = [NSString stringWithFormat:
                NSLocalizedString(@"No UUID found for this volume.\n\n"
                                  @"This can happen if no tracks from this volume have been added to playlists yet.\n\n"
                                  @"Alternative: Double-click an Active UUID in the table to use it as target.\n\n"
                                  @"Path: %@", @"Error message with hint"),
                volumeURL.path];
            alert.alertStyle = NSAlertStyleWarning;
            [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
            [alert runModal];
        }
    }];
}

- (void)startScan:(id)sender {
    if (self.isScanning) {
        self.shouldStop = YES;
        return;
    }

    self.isScanning = YES;
    self.shouldStop = NO;
    self.totalCount = 0;
    self.scannedCount = 0;
    self.malformedCount = 0;
    self.applyButton.enabled = NO;
    self.scanButton.title = NSLocalizedString(@"Stop", @"Stop button");

    [self.allUUIDEntries removeAllObjects];
    [self.displayedUUIDEntries removeAllObjects];
    [self.selectedUUIDs removeAllObjects];
    self.uuidSamplePaths = @{};

    // Get active volume UUIDs
    self.activeVolumeUUIDs = [self discoverMountedVolumeUUIDs];

    // Load playlist name mapping from index.txt
    self.playlistFileUUIDToName = [self loadPlaylistNameMapping];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self performScan];
    });
}

- (void)cancel:(id)sender {
    self.shouldStop = YES;
    BOOL shouldNotify = !self.didNotifyDelegate;
    self.didNotifyDelegate = YES;
    [self.window close];
    if (shouldNotify) {
        [self.delegate uuidRemappingDidCancel:self];
    }
}

- (void)applyRemapping:(id)sender {
    NSString *targetUUID = [self.targetUUIDField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (self.selectedUUIDs.count == 0) {
        return;
    }

    if (![PlorgVolumeSyncLogic isValidVolumeUUID:targetUUID]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = NSLocalizedString(@"Invalid target UUID", @"Error title");
        alert.informativeText = NSLocalizedString(@"The target UUID must have the form XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX.", @"Error message");
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
        [alert runModal];
        return;
    }

    [self performRemappingWithTargetUUID:[targetUUID uppercaseString]];
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.targetUUIDField) {
        [self updateApplyButtonState];
    }
}

#pragma mark - Volume Discovery

/// Get volume UUID using DiskArbitration framework (works for more volume types)
- (NSString *)volumeUUIDForPath:(NSString *)path {
    struct statfs stfs;
    if (statfs(path.fileSystemRepresentation, &stfs) != 0) {
        return nil;
    }

    DASessionRef session = DASessionCreate(NULL);
    if (!session) {
        return nil;
    }

    NSString *uuid = nil;
    DADiskRef disk = DADiskCreateFromBSDName(NULL, session, stfs.f_mntfromname);
    if (disk) {
        NSDictionary *diskInfo = CFBridgingRelease(DADiskCopyDescription(disk));
        id uuidValue = diskInfo[(__bridge NSString *)kDADiskDescriptionVolumeUUIDKey];
        if (uuidValue && CFGetTypeID((__bridge CFTypeRef)uuidValue) == CFUUIDGetTypeID()) {
            CFUUIDRef cfuuid = (__bridge CFUUIDRef)uuidValue;
            CFStringRef cfUuidString = CFUUIDCreateString(NULL, cfuuid);
            if (cfUuidString) {
                uuid = [(__bridge_transfer NSString *)cfUuidString uppercaseString];
            }
        }
        CFRelease(disk);
    }
    CFRelease(session);

    return uuid;
}

/// Find the UUID for a volume by checking if files from the playlists exist on it.
/// This works for network volumes where standard APIs don't return a UUID.
/// When multiple UUIDs match, returns the one with FEWEST entries (most likely to be current).
- (NSString *)findUUIDForVolumePath:(NSString *)volumePath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<VolumeUUIDEntry *> *matchingEntries = [NSMutableArray array];

    // For each UUID we found in playlists, check if its files exist on this volume
    for (VolumeUUIDEntry *entry in self.allUUIDEntries) {
        // Get a sample path from one of the playlists for this UUID
        NSString *samplePath = [self getSamplePathForUUID:entry.uuid];
        if (!samplePath) continue;

        // Construct full path: volumePath + samplePath
        NSString *fullPath = [volumePath stringByAppendingPathComponent:samplePath];

        // Check if this file exists
        if ([fm fileExistsAtPath:fullPath]) {
            [matchingEntries addObject:entry];
        }
    }

    if (matchingEntries.count == 0) {
        return nil;
    }

    // If multiple UUIDs match, return the one with FEWEST entries
    // (most recently added UUID will have fewer entries)
    [matchingEntries sortUsingComparator:^NSComparisonResult(VolumeUUIDEntry *a, VolumeUUIDEntry *b) {
        if (a.entryCount < b.entryCount) return NSOrderedAscending;
        if (a.entryCount > b.entryCount) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    return matchingEntries.firstObject.uuid;
}

/// Get a sample file path (relative to volume root) for a given UUID from playlists
- (NSString *)getSamplePathForUUID:(NSString *)uuid {
    return self.uuidSamplePaths[uuid];
}

- (NSDictionary<NSString *, NSString *> *)discoverMountedVolumeUUIDs {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    NSArray *keys = @[NSURLVolumeUUIDStringKey, NSURLVolumeNameKey];
    NSArray<NSURL *> *volumes = [[NSFileManager defaultManager]
        mountedVolumeURLsIncludingResourceValuesForKeys:keys
        options:NSVolumeEnumerationSkipHiddenVolumes];

    for (NSURL *volumeURL in volumes) {
        NSDictionary *values = [volumeURL resourceValuesForKeys:keys error:nil];
        NSString *uuid = values[NSURLVolumeUUIDStringKey];

        // Try DiskArbitration if NSURL didn't return a UUID
        if (!uuid) {
            uuid = [self volumeUUIDForPath:volumeURL.path];
        }

        if (uuid) {
            result[[uuid uppercaseString]] = volumeURL.path;
        }
    }

    return result;
}

- (NSDictionary<NSString *, NSString *> *)loadPlaylistNameMapping {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    // index.txt format: UUID:PlaylistName (one per line)
    NSString *indexPath = [self.playlistsDir stringByAppendingPathComponent:@"index.txt"];
    NSString *content = [NSString stringWithContentsOfFile:indexPath encoding:NSUTF8StringEncoding error:nil];
    if (!content) {
        return result;
    }

    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        NSRange colonRange = [line rangeOfString:@":"];
        if (colonRange.location != NSNotFound && colonRange.location > 0) {
            NSString *fileUUID = [line substringToIndex:colonRange.location];
            NSString *name = [line substringFromIndex:colonRange.location + 1];
            if ([PlorgVolumeSyncLogic isValidVolumeUUID:fileUUID] && name.length > 0) {
                result[[fileUUID uppercaseString]] = name;
            }
        }
    }

    return result;
}

- (NSString *)playlistNameFromPath:(NSString *)path {
    // Extract file UUID from path like "playlist-{UUID}.fplite"
    NSString *filename = [[path lastPathComponent] stringByDeletingPathExtension];
    if ([filename hasPrefix:@"playlist-"]) {
        NSString *fileUUID = [[filename substringFromIndex:9] uppercaseString];
        NSString *name = self.playlistFileUUIDToName[fileUUID];
        if (name) {
            return name;
        }
    }
    // Fallback: use filename without extension
    return filename;
}

#pragma mark - Scanning

- (void)performScan {
    __weak typeof(self) weakSelf = self;

    // Find .fplite files - always scan all to show affected playlists
    NSMutableArray *files = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
        enumeratorAtPath:self.playlistsDir];

    NSString *file;
    while ((file = [enumerator nextObject])) {
        if ([file.pathExtension.lowercaseString isEqualToString:@"fplite"]) {
            [files addObject:[self.playlistsDir stringByAppendingPathComponent:file]];
        }
    }

    NSArray<NSString *> *fpliteFiles = files;
    self.totalCount = fpliteFiles.count;

    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.statusLabel.stringValue = [NSString stringWithFormat:
            NSLocalizedString(@"Scanning %ld playlist files...", @"Status"),
            (long)weakSelf.totalCount];
    });

    // Dictionary: UUID -> {count, playlists}
    NSMutableDictionary<NSString *, NSMutableDictionary *> *uuidData = [NSMutableDictionary dictionary];

    // Also track playlist names for display
    NSMutableDictionary<NSString *, NSString *> *playlistPathToName = [NSMutableDictionary dictionary];

    for (NSString *fplitePath in fpliteFiles) {
        if (self.shouldStop) break;

        @autoreleasepool {
            // Get playlist display name from index.txt mapping
            playlistPathToName[fplitePath] = [self playlistNameFromPath:fplitePath];

            [self scanFpliteFile:fplitePath intoData:uuidData];
            self.scannedCount++;

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;

                CGFloat progress = strongSelf.totalCount > 0 ?
                    (CGFloat)strongSelf.scannedCount / strongSelf.totalCount * 100 : 0;
                strongSelf.progressBar.doubleValue = progress;
            });
        }
    }

    // Capture the first validated sample path per UUID for later lookups
    NSMutableDictionary<NSString *, NSString *> *samplePaths = [NSMutableDictionary dictionary];
    for (NSString *uuid in uuidData) {
        NSString *samplePath = uuidData[uuid][@"samplePath"];
        if (samplePath) {
            samplePaths[uuid] = samplePath;
        }
    }

    // Build VolumeUUIDEntry objects
    NSMutableArray<VolumeUUIDEntry *> *entries = [NSMutableArray array];

    // Get list of mounted volumes for file-existence check fallback
    NSArray<NSURL *> *mountedVolumes = [[NSFileManager defaultManager]
        mountedVolumeURLsIncludingResourceValuesForKeys:nil
        options:NSVolumeEnumerationSkipHiddenVolumes];

    // First pass: collect all UUIDs and which volumes they match via file-existence
    NSMutableDictionary<NSString *, NSMutableArray *> *volumeToUUIDs = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *uuidToVolume = [NSMutableDictionary dictionary];

    for (NSString *uuid in uuidData) {
        // Check if this UUID is already known via standard APIs
        NSString *mountPath = self.activeVolumeUUIDs[uuid];
        if (mountPath) {
            uuidToVolume[uuid] = mountPath;
            continue;
        }

        // Try file-existence check
        NSString *samplePath = uuidData[uuid][@"samplePath"];
        if (!samplePath) continue;

        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSURL *volumeURL in mountedVolumes) {
            NSString *fullPath = [volumeURL.path stringByAppendingPathComponent:samplePath];
            if ([fm fileExistsAtPath:fullPath]) {
                NSString *volPath = volumeURL.path;
                uuidToVolume[uuid] = volPath;
                if (!volumeToUUIDs[volPath]) {
                    volumeToUUIDs[volPath] = [NSMutableArray array];
                }
                [volumeToUUIDs[volPath] addObject:uuid];
                break;
            }
        }
    }

    // For volumes with multiple matching UUIDs, only the one with fewest entries is "active"
    // (the one with fewest entries is most likely the current UUID)
    NSMutableSet<NSString *> *activeUUIDs = [NSMutableSet set];

    // UUIDs found via standard APIs are always active
    for (NSString *uuid in self.activeVolumeUUIDs) {
        [activeUUIDs addObject:uuid];
    }

    // For each volume with multiple matching UUIDs, pick the one with fewest entries
    for (NSString *volPath in volumeToUUIDs) {
        NSArray *uuids = volumeToUUIDs[volPath];
        if (uuids.count == 0) continue;

        // Sort by entry count ascending
        NSArray *sorted = [uuids sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSUInteger countA = [uuidData[a][@"count"] unsignedIntegerValue];
            NSUInteger countB = [uuidData[b][@"count"] unsignedIntegerValue];
            if (countA < countB) return NSOrderedAscending;
            if (countA > countB) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        // Only the one with fewest entries is active
        [activeUUIDs addObject:sorted.firstObject];
    }

    // Second pass: create entries
    for (NSString *uuid in uuidData) {
        NSDictionary *data = uuidData[uuid];
        NSUInteger count = [data[@"count"] unsignedIntegerValue];
        NSSet *playlists = data[@"playlists"];
        NSDictionary *perPlaylistCounts = data[@"perPlaylist"];

        BOOL isActive = [activeUUIDs containsObject:uuid];
        NSString *mountPath = isActive ? uuidToVolume[uuid] : nil;

        VolumeUUIDEntry *entry = [[VolumeUUIDEntry alloc] initWithUUID:uuid
                                                           entryCount:count
                                                             isActive:isActive
                                                            mountPath:mountPath
                                                affectedPlaylistPaths:playlists
                                                   perPlaylistCounts:perPlaylistCounts];
        [entries addObject:entry];
    }

    // Sort: active first, then orphaned by count descending
    [entries sortUsingComparator:^NSComparisonResult(VolumeUUIDEntry *a, VolumeUUIDEntry *b) {
        if (a.isActive && !b.isActive) return NSOrderedAscending;
        if (!a.isActive && b.isActive) return NSOrderedDescending;
        if (a.entryCount > b.entryCount) return NSOrderedAscending;
        if (a.entryCount < b.entryCount) return NSOrderedDescending;
        return [a.uuid compare:b.uuid];
    }];

    // Count orphaned and collect affected playlist names
    NSUInteger orphanedCount = 0;
    NSUInteger orphanedEntries = 0;
    NSMutableSet<NSString *> *affectedPlaylistPaths = [NSMutableSet set];

    for (VolumeUUIDEntry *entry in entries) {
        if (!entry.isActive) {
            orphanedCount++;
            orphanedEntries += entry.entryCount;
            [affectedPlaylistPaths unionSet:entry.affectedPlaylistPaths];
        }
    }

    // Build affected playlists display string
    NSMutableArray<NSString *> *affectedNames = [NSMutableArray array];
    for (NSString *path in affectedPlaylistPaths) {
        NSString *name = playlistPathToName[path];
        if (name) {
            [affectedNames addObject:name];
        }
    }
    [affectedNames sortUsingSelector:@selector(caseInsensitiveCompare:)];

    // Build display string with ALL playlist names (no truncation)
    NSString *affectedPlaylistsStr;
    if (affectedNames.count == 0) {
        affectedPlaylistsStr = NSLocalizedString(@"(no playlists with orphaned UUIDs)", @"No affected playlists");
    } else {
        affectedPlaylistsStr = [affectedNames componentsJoinedByString:@", "];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        strongSelf.isScanning = NO;
        strongSelf.scanButton.title = NSLocalizedString(@"Rescan", @"Rescan button");

        // Store all entries and filter for current scope
        strongSelf.uuidSamplePaths = samplePaths;
        [strongSelf.allUUIDEntries setArray:entries];
        [strongSelf filterEntriesForCurrentScope];
        [strongSelf.tableView reloadData];

        // Update affected playlists label - show just the names
        strongSelf.affectedPlaylistsLabel.stringValue = [NSString stringWithFormat:@"(%@)", affectedPlaylistsStr];

        strongSelf.progressBar.doubleValue = 100;

        NSString *status;
        if (orphanedCount > 0) {
            status = [NSString stringWithFormat:
                NSLocalizedString(@"Found %ld UUIDs (%ld orphaned with %ld entries)", @"Status with orphaned"),
                (long)entries.count, (long)orphanedCount, (long)orphanedEntries];
        } else {
            status = [NSString stringWithFormat:
                NSLocalizedString(@"Found %ld UUIDs, none orphaned", @"Status no orphaned"),
                (long)entries.count];
        }
        strongSelf.statusLabel.stringValue = status;

        [strongSelf updateApplyButtonState];
    });
}

- (void)scanFpliteFile:(NSString *)path intoData:(NSMutableDictionary *)uuidData {
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!content) return;

    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *line in lines) {
        NSString *uuid = nil;
        NSString *samplePath = nil;
        FpliteLineResult parsed = [PlorgVolumeSyncLogic parseFpliteLine:line uuid:&uuid samplePath:&samplePath];
        if (parsed == FpliteLineNotVolume) continue;
        if (parsed == FpliteLineMalformed) {
            self.malformedCount++;
            continue;
        }

        if (!uuidData[uuid]) {
            uuidData[uuid] = [@{
                @"count": @1,
                @"samplePath": samplePath,
                @"playlists": [NSMutableSet setWithObject:path],
                @"perPlaylist": [NSMutableDictionary dictionaryWithObject:@1 forKey:path]
            } mutableCopy];
        } else {
            NSMutableDictionary *existing = uuidData[uuid];
            existing[@"count"] = @([existing[@"count"] unsignedIntegerValue] + 1);
            [existing[@"playlists"] addObject:path];

            // Track per-playlist count
            NSMutableDictionary *perPlaylist = existing[@"perPlaylist"];
            NSNumber *currentCount = perPlaylist[path];
            perPlaylist[path] = @(currentCount ? currentCount.unsignedIntegerValue + 1 : 1);
        }
    }
}

#pragma mark - Apply Button State

- (void)updateApplyButtonState {
    NSString *targetUUID = [self.targetUUIDField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL hasTarget = [PlorgVolumeSyncLogic isValidVolumeUUID:targetUUID];
    BOOL hasSelection = self.selectedUUIDs.count > 0;

    // Don't allow remapping to a UUID that's also selected for remapping
    BOOL targetSelected = [self.selectedUUIDs containsObject:[targetUUID uppercaseString]];

    self.applyButton.enabled = hasTarget && hasSelection && !targetSelected;
}

#pragma mark - Remapping

- (void)performRemappingWithTargetUUID:(NSString *)targetUUID {
    self.isApplying = YES;
    self.applyButton.enabled = NO;
    self.scanButton.enabled = NO;
    self.tableView.enabled = NO;

    NSSet<NSString *> *selectedUUIDsSnapshot = [self.selectedUUIDs copy];
    NSArray<VolumeUUIDEntry *> *uuidEntriesSnapshot = [self.allUUIDEntries copy];
    BOOL useSinglePlaylist = self.useSinglePlaylist;
    NSString *singlePlaylistPath = [self.singlePlaylistPath copy];

    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Collect affected playlists based on scope
        NSMutableSet<NSString *> *playlistsToProcess = [NSMutableSet set];

        if (useSinglePlaylist && singlePlaylistPath) {
            // Single playlist mode - only process this one
            [playlistsToProcess addObject:singlePlaylistPath];
        } else {
            // All playlists mode - process all affected
            for (VolumeUUIDEntry *entry in uuidEntriesSnapshot) {
                if ([selectedUUIDsSnapshot containsObject:entry.uuid]) {
                    [playlistsToProcess unionSet:entry.affectedPlaylistPaths];
                }
            }
        }

        // Create backup
        NSError *backupError = nil;
        NSString *backupDir = [strongSelf createBackupForPlaylists:playlistsToProcess error:&backupError];
        if (!backupDir) {
            dispatch_async(dispatch_get_main_queue(), ^{
                strongSelf.isApplying = NO;
                strongSelf.scanButton.enabled = YES;
                strongSelf.tableView.enabled = YES;
                [strongSelf updateApplyButtonState];

                NSError *failError = backupError;
                if (!failError) {
                    failError = [NSError errorWithDomain:NSCocoaErrorDomain
                                                    code:NSFileWriteUnknownError
                                                userInfo:@{NSLocalizedDescriptionKey:
                                                    NSLocalizedString(@"Failed to create backup directory", @"Backup error")}];
                }

                if ([strongSelf.delegate respondsToSelector:@selector(uuidRemappingDidFail:error:)]) {
                    strongSelf.didNotifyDelegate = YES;
                    [strongSelf.window close];
                    [strongSelf.delegate uuidRemappingDidFail:strongSelf error:failError];
                } else {
                    NSAlert *alert = [[NSAlert alloc] init];
                    alert.messageText = NSLocalizedString(@"UUID Remapping Failed", @"Alert title");
                    alert.informativeText = failError.localizedDescription;
                    alert.alertStyle = NSAlertStyleCritical;
                    [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                    [alert runModal];

                    BOOL shouldNotify = !strongSelf.didNotifyDelegate;
                    strongSelf.didNotifyDelegate = YES;
                    [strongSelf.window close];
                    if (shouldNotify) {
                        [strongSelf.delegate uuidRemappingDidCancel:strongSelf];
                    }
                }
            });
            return;
        }

        // Perform remapping
        NSMutableArray<NSString *> *changedFiles = [NSMutableArray array];
        NSMutableArray<NSError *> *errors = [NSMutableArray array];

        for (NSString *playlistPath in playlistsToProcess) {
            NSError *error = nil;
            BOOL changed = [strongSelf remapUUIDsInPlaylist:playlistPath
                                                fromUUIDs:selectedUUIDsSnapshot
                                               targetUUID:targetUUID
                                                    error:&error];

            if (error) {
                [errors addObject:error];
            } else if (changed) {
                [changedFiles addObject:playlistPath];
            }
        }

        // Prune old backups
        [strongSelf pruneOldBackups];

        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.isApplying = NO;
            strongSelf.scanButton.enabled = YES;
            strongSelf.tableView.enabled = YES;
            strongSelf.didNotifyDelegate = YES;
            [strongSelf.delegate uuidRemappingDidComplete:strongSelf
                                             changedFiles:changedFiles
                                                   errors:errors];

            // Show info modal about restart requirement
            if (changedFiles.count > 0) {
                NSAlert *alert = [[NSAlert alloc] init];
                alert.alertStyle = NSAlertStyleInformational;

                if (changedFiles.count == 1) {
                    NSString *playlistName = [[changedFiles.firstObject lastPathComponent] stringByDeletingPathExtension];
                    alert.messageText = NSLocalizedString(@"Restart Required", @"Alert title");
                    alert.informativeText = [NSString stringWithFormat:
                        NSLocalizedString(@"UUID remapping on \"%@\" is complete.\n\nRestart foobar2000 for changes to take effect.",
                            @"Alert message for single playlist"),
                        playlistName];
                } else {
                    alert.messageText = NSLocalizedString(@"Restart Required", @"Alert title");
                    alert.informativeText = [NSString stringWithFormat:
                        NSLocalizedString(@"UUID remapping on %lu playlists is complete.\n\nRestart foobar2000 for changes to take effect.",
                            @"Alert message for multiple playlists"),
                        (unsigned long)changedFiles.count];
                }

                [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
                [alert beginSheetModalForWindow:strongSelf.window completionHandler:^(NSModalResponse returnCode) {
                    [strongSelf.window close];
                }];
            } else {
                [strongSelf.window close];
            }
        });
    });
}

- (NSString *)createBackupForPlaylists:(NSSet<NSString *> *)playlists error:(NSError **)error {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd_HHmmss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];

    NSString *backupDir = [self.playlistsDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"backup_uuid_remap_%@", timestamp]];

    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }

    for (NSString *playlistPath in playlists) {
        NSString *filename = [playlistPath lastPathComponent];
        NSString *backupPath = [backupDir stringByAppendingPathComponent:filename];

        NSError *copyError = nil;
        if (![fm copyItemAtPath:playlistPath toPath:backupPath error:&copyError]) {
            NSLog(@"Failed to backup %@: %@", filename, copyError);
        }
    }

    return backupDir;
}

- (BOOL)remapUUIDsInPlaylist:(NSString *)path fromUUIDs:(NSSet<NSString *> *)fromUUIDs targetUUID:(NSString *)targetUUID error:(NSError **)error {
    NSData *rawData = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!rawData) return NO;

    // Shared BOM-preserving remap (PlorgVolumeSyncLogic); nil means nothing changed
    NSData *newData = [PlorgVolumeSyncLogic remappedFpliteData:rawData
                                                fromUUIDs:fromUUIDs
                                                   toUUID:targetUUID];
    if (!newData) return NO;

    if (![newData writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }

    return YES;
}

- (void)pruneOldBackups {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:self.playlistsDir error:nil];

    NSMutableArray<NSString *> *backupDirs = [NSMutableArray array];
    for (NSString *item in contents) {
        if ([item hasPrefix:@"backup_uuid_remap_"]) {
            [backupDirs addObject:[self.playlistsDir stringByAppendingPathComponent:item]];
        }
    }

    if (backupDirs.count <= kMaxBackupDirectories) return;

    // Directory names embed a zero-padded timestamp (backup_uuid_remap_yyyy-MM-dd_HHmmss),
    // so lexicographic order is chronological order
    [backupDirs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent compare:b.lastPathComponent];
    }];

    NSUInteger toRemove = backupDirs.count - kMaxBackupDirectories;
    for (NSUInteger i = 0; i < toRemove; i++) {
        [fm removeItemAtPath:backupDirs[i] error:nil];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.displayedUUIDEntries.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    VolumeUUIDEntry *entry = self.displayedUUIDEntries[row];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:@"SelectColumn"]) {
        NSButton *checkbox = [tableView makeViewWithIdentifier:@"CheckCell" owner:self];
        if (!checkbox) {
            checkbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(checkboxClicked:)];
            checkbox.identifier = @"CheckCell";
        }

        checkbox.state = [self.selectedUUIDs containsObject:entry.uuid] ? NSControlStateValueOn : NSControlStateValueOff;
        checkbox.enabled = !entry.isActive;
        checkbox.tag = row;

        return checkbox;
    }

    if ([identifier isEqualToString:@"UUIDColumn"]) {
        NSTextField *cell = [tableView makeViewWithIdentifier:@"TextCell" owner:self];
        if (!cell) {
            cell = [NSTextField labelWithString:@""];
            cell.identifier = @"TextCell";
        }
        cell.stringValue = entry.uuid;
        cell.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        return cell;
    }

    if ([identifier isEqualToString:@"CountColumn"]) {
        NSTextField *cell = [tableView makeViewWithIdentifier:@"CountCell" owner:self];
        if (!cell) {
            cell = [NSTextField labelWithString:@""];
            cell.identifier = @"CountCell";
            cell.alignment = NSTextAlignmentRight;
        }
        // Show per-playlist count in single playlist mode, total otherwise
        NSUInteger displayCount;
        if (self.useSinglePlaylist && self.singlePlaylistPath) {
            displayCount = [entry entryCountForPlaylist:self.singlePlaylistPath];
        } else {
            displayCount = entry.entryCount;
        }
        cell.stringValue = [NSString stringWithFormat:@"%ld", (long)displayCount];
        return cell;
    }

    if ([identifier isEqualToString:@"PlaylistsColumn"]) {
        NSTextField *cell = [tableView makeViewWithIdentifier:@"PlaylistsCell" owner:self];
        if (!cell) {
            cell = [NSTextField labelWithString:@""];
            cell.identifier = @"PlaylistsCell";
            cell.alignment = NSTextAlignmentRight;
        }
        // Show "1" in single playlist mode, total otherwise
        NSUInteger displayCount;
        if (self.useSinglePlaylist && self.singlePlaylistPath) {
            displayCount = 1;
        } else {
            displayCount = entry.affectedPlaylistPaths.count;
        }
        cell.stringValue = [NSString stringWithFormat:@"%ld", (long)displayCount];
        return cell;
    }

    if ([identifier isEqualToString:@"StatusColumn"]) {
        NSTextField *cell = [tableView makeViewWithIdentifier:@"StatusCell" owner:self];
        if (!cell) {
            cell = [NSTextField labelWithString:@""];
            cell.identifier = @"StatusCell";
        }

        if (entry.isActive) {
            cell.stringValue = [NSString stringWithFormat:@"Active (%@)", entry.mountPath.lastPathComponent];
            cell.textColor = [NSColor systemGreenColor];
        } else {
            cell.stringValue = @"Orphaned";
            cell.textColor = [NSColor systemOrangeColor];
        }

        return cell;
    }

    return nil;
}

- (void)checkboxClicked:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.displayedUUIDEntries.count) return;

    VolumeUUIDEntry *entry = self.displayedUUIDEntries[row];

    if (self.isApplying) {
        sender.state = [self.selectedUUIDs containsObject:entry.uuid] ? NSControlStateValueOn : NSControlStateValueOff;
        return;
    }

    if (sender.state == NSControlStateValueOn) {
        [self.selectedUUIDs addObject:entry.uuid];
    } else {
        [self.selectedUUIDs removeObject:entry.uuid];
    }

    [self updateApplyButtonState];
}

#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification {
    if (self.didNotifyDelegate) return;
    self.didNotifyDelegate = YES;
    self.shouldStop = YES;
    [self.delegate uuidRemappingDidCancel:self];
}

@end
