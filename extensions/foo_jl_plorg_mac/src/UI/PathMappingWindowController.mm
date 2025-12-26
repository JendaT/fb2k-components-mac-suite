//
//  PathMappingWindowController.mm
//  foo_plorg_mac
//

#import "PathMappingWindowController.h"
#import <objc/runtime.h>

@interface PathMappingWindowController ()

@property (nonatomic, strong) NSProgressIndicator *progressBar;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSButton *importButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSStackView *mappingsStackView;
@property (nonatomic, strong) NSTextField *defaultMappingField;
@property (nonatomic, strong) NSScrollView *scrollView;

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *discoveredDrives;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTextField *> *mappingFields;
@property (nonatomic, strong) NSMutableArray<NSString *> *fpliteFiles;

@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, assign) BOOL shouldStop;
@property (nonatomic, assign) NSInteger scannedCount;
@property (nonatomic, assign) NSInteger totalCount;

@end

@implementation PathMappingWindowController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 400)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Import Path Mapping";
    [window center];

    self = [super initWithWindow:window];
    if (self) {
        _discoveredDrives = [NSMutableDictionary dictionary];
        _mappingFields = [NSMutableDictionary dictionary];
        _fpliteFiles = [NSMutableArray array];
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    NSView *contentView = self.window.contentView;
    contentView.wantsLayer = YES;

    // Title label
    NSTextField *titleLabel = [NSTextField labelWithString:@"Scanning playlists for path mappings..."];
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

    // Status label
    self.statusLabel = [NSTextField labelWithString:@"Preparing..."];
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.statusLabel];

    // Stop button
    self.stopButton = [NSButton buttonWithTitle:@"Stop Scan" target:self action:@selector(stopScan:)];
    self.stopButton.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.stopButton];

    // Mappings section label
    NSTextField *mappingsLabel = [NSTextField labelWithString:@"Drive Mappings:"];
    mappingsLabel.font = [NSFont boldSystemFontOfSize:12];
    mappingsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:mappingsLabel];

    // Scroll view for mappings
    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;

    // Stack view for mapping rows
    self.mappingsStackView = [[NSStackView alloc] init];
    self.mappingsStackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.mappingsStackView.alignment = NSLayoutAttributeLeading;
    self.mappingsStackView.spacing = 8;
    self.mappingsStackView.translatesAutoresizingMaskIntoConstraints = NO;

    // Wrap in a container for scroll view
    NSView *containerView = [[NSView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    [containerView addSubview:self.mappingsStackView];

    self.scrollView.documentView = containerView;
    [contentView addSubview:self.scrollView];

    // Default mapping section
    NSTextField *defaultLabel = [NSTextField labelWithString:@"Default base path (for unmatched drives):"];
    defaultLabel.font = [NSFont systemFontOfSize:11];
    defaultLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:defaultLabel];

    self.defaultMappingField = [[NSTextField alloc] init];
    self.defaultMappingField.placeholderString = @"/Volumes/music";
    self.defaultMappingField.stringValue = @"/Volumes/music";
    self.defaultMappingField.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.defaultMappingField];

    // Buttons
    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.cancelButton];

    self.importButton = [NSButton buttonWithTitle:@"Import" target:self action:@selector(doImport:)];
    self.importButton.bezelStyle = NSBezelStyleRounded;
    self.importButton.keyEquivalent = @"\r";
    self.importButton.enabled = NO;
    self.importButton.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:self.importButton];

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:contentView.topAnchor constant:16],
        [titleLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],

        [self.progressBar.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
        [self.progressBar.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [self.progressBar.trailingAnchor constraintEqualToAnchor:self.stopButton.leadingAnchor constant:-8],

        [self.stopButton.centerYAnchor constraintEqualToAnchor:self.progressBar.centerYAnchor],
        [self.stopButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
        [self.stopButton.widthAnchor constraintEqualToConstant:80],

        [self.statusLabel.topAnchor constraintEqualToAnchor:self.progressBar.bottomAnchor constant:4],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],

        [mappingsLabel.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:16],
        [mappingsLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],

        [self.scrollView.topAnchor constraintEqualToAnchor:mappingsLabel.bottomAnchor constant:8],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
        [self.scrollView.heightAnchor constraintGreaterThanOrEqualToConstant:120],

        [self.mappingsStackView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:8],
        [self.mappingsStackView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:8],
        [self.mappingsStackView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-8],
        [self.mappingsStackView.bottomAnchor constraintEqualToAnchor:containerView.bottomAnchor constant:-8],
        [containerView.widthAnchor constraintEqualToAnchor:self.scrollView.widthAnchor constant:-20],

        [defaultLabel.topAnchor constraintEqualToAnchor:self.scrollView.bottomAnchor constant:16],
        [defaultLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],

        [self.defaultMappingField.topAnchor constraintEqualToAnchor:defaultLabel.bottomAnchor constant:4],
        [self.defaultMappingField.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:16],
        [self.defaultMappingField.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],

        [self.cancelButton.topAnchor constraintEqualToAnchor:self.defaultMappingField.bottomAnchor constant:20],
        [self.cancelButton.trailingAnchor constraintEqualToAnchor:self.importButton.leadingAnchor constant:-8],
        [self.cancelButton.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor constant:-16],

        [self.importButton.centerYAnchor constraintEqualToAnchor:self.cancelButton.centerYAnchor],
        [self.importButton.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-16],
        [self.importButton.widthAnchor constraintEqualToConstant:80],
    ]];
}

- (void)beginScanningWithPlaylistsDir:(NSString *)playlistsDir themeFilePath:(NSString *)themeFilePath {
    self.playlistsDir = playlistsDir;
    self.themeFilePath = themeFilePath;

    [self.window makeKeyAndOrderFront:nil];
    [self startScanning];
}

- (void)startScanning {
    self.isScanning = YES;
    self.shouldStop = NO;
    self.scannedCount = 0;
    self.importButton.enabled = NO;
    self.stopButton.title = @"Stop Scan";

    // Find all .fplite files
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *contents = [fm contentsOfDirectoryAtPath:strongSelf.playlistsDir error:nil];

        [strongSelf.fpliteFiles removeAllObjects];
        for (NSString *file in contents) {
            if ([file hasSuffix:@".fplite"]) {
                [strongSelf.fpliteFiles addObject:[strongSelf.playlistsDir stringByAppendingPathComponent:file]];
            }
        }

        strongSelf.totalCount = strongSelf.fpliteFiles.count;

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) mainSelf = weakSelf;
            if (!mainSelf) return;
            mainSelf.progressBar.maxValue = mainSelf.totalCount;
            mainSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Found %ld playlist files", (long)mainSelf.totalCount];
        });

        // Scan each file for unique paths
        for (NSString *fplitePath in strongSelf.fpliteFiles) {
            if (strongSelf.shouldStop) break;

            [strongSelf scanFpliteFile:fplitePath];
            strongSelf.scannedCount++;

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) mainSelf = weakSelf;
                if (!mainSelf) return;
                mainSelf.progressBar.doubleValue = mainSelf.scannedCount;
                mainSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Scanned %ld / %ld files, found %ld drives",
                    (long)mainSelf.scannedCount, (long)mainSelf.totalCount, (long)mainSelf.discoveredDrives.count];
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) mainSelf = weakSelf;
            if (!mainSelf) return;
            mainSelf.isScanning = NO;
            mainSelf.importButton.enabled = YES;
            mainSelf.stopButton.title = @"Rescan";

            if (mainSelf.shouldStop) {
                mainSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Scan stopped. Scanned %ld / %ld files, found %ld drives",
                    (long)mainSelf.scannedCount, (long)mainSelf.totalCount, (long)mainSelf.discoveredDrives.count];
            } else {
                mainSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Scan complete. Found %ld drives in %ld playlists",
                    (long)mainSelf.discoveredDrives.count, (long)mainSelf.totalCount];
            }
        });
    });
}

- (void)scanFpliteFile:(NSString *)path {
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!content) return;

    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *line in lines) {
        if (line.length == 0) continue;

        NSString *filePath = line;

        // Handle file:// URLs
        if ([filePath hasPrefix:@"file://"]) {
            filePath = [filePath substringFromIndex:7];
            filePath = [filePath stringByRemovingPercentEncoding];
        }

        // Extract drive letter or network path
        NSString *driveKey = nil;

        if (filePath.length > 2 && [filePath characterAtIndex:1] == ':') {
            // Windows drive letter (e.g., "A:\")
            driveKey = [[filePath substringToIndex:2] uppercaseString];
        } else if ([filePath hasPrefix:@"\\\\"]) {
            // UNC network path (e.g., "\\server\share")
            NSRange secondSlash = [filePath rangeOfString:@"\\" options:0 range:NSMakeRange(2, filePath.length - 2)];
            if (secondSlash.location != NSNotFound) {
                NSRange thirdSlash = [filePath rangeOfString:@"\\" options:0 range:NSMakeRange(secondSlash.location + 1, filePath.length - secondSlash.location - 1)];
                if (thirdSlash.location != NSNotFound) {
                    driveKey = [filePath substringToIndex:thirdSlash.location];
                } else {
                    driveKey = filePath;
                }
            }
        } else if ([filePath hasPrefix:@"//"]) {
            // Unix-style network path
            NSArray *components = [filePath pathComponents];
            if (components.count >= 3) {
                driveKey = [NSString stringWithFormat:@"//%@/%@", components[1], components[2]];
            }
        }

        if (driveKey && !self.discoveredDrives[driveKey]) {
            // Suggest a default mapping
            NSString *suggestion = @"";
            if (driveKey.length == 2 && [driveKey characterAtIndex:1] == ':') {
                // Drive letter - suggest /Volumes/drivename or common mapping
                NSString *letter = [[driveKey substringToIndex:1] lowercaseString];
                if ([letter isEqualToString:@"a"]) {
                    suggestion = @"/Volumes/music";
                } else if ([letter isEqualToString:@"c"]) {
                    suggestion = @"";  // Usually not needed
                } else {
                    suggestion = [NSString stringWithFormat:@"/Volumes/%@", letter];
                }
            }

            self.discoveredDrives[driveKey] = suggestion;

            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf addMappingRowForDrive:driveKey suggestion:suggestion];
            });
        }
    }
}

- (void)addMappingRowForDrive:(NSString *)drive suggestion:(NSString *)suggestion {
    if (self.mappingFields[drive]) return;  // Already added

    NSStackView *row = [[NSStackView alloc] init];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 8;
    row.alignment = NSLayoutAttributeCenterY;

    NSTextField *driveLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ ->", drive]];
    driveLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    [driveLabel setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSTextField *pathField = [[NSTextField alloc] init];
    pathField.stringValue = suggestion;
    pathField.placeholderString = @"/Volumes/...";
    [pathField setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *browseButton = [NSButton buttonWithTitle:@"..." target:self action:@selector(browseForPath:)];
    browseButton.tag = self.mappingFields.count;
    objc_setAssociatedObject(browseButton, "driveKey", drive, OBJC_ASSOCIATION_RETAIN);

    [row addArrangedSubview:driveLabel];
    [row addArrangedSubview:pathField];
    [row addArrangedSubview:browseButton];

    [NSLayoutConstraint activateConstraints:@[
        [driveLabel.widthAnchor constraintEqualToConstant:60],
        [pathField.widthAnchor constraintGreaterThanOrEqualToConstant:250],
        [browseButton.widthAnchor constraintEqualToConstant:30],
    ]];

    self.mappingFields[drive] = pathField;
    [self.mappingsStackView addArrangedSubview:row];
}

- (void)browseForPath:(NSButton *)sender {
    NSString *driveKey = objc_getAssociatedObject(sender, "driveKey");
    NSTextField *field = self.mappingFields[driveKey];

    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.message = [NSString stringWithFormat:@"Select folder to map %@ to:", driveKey];

    if ([panel runModal] == NSModalResponseOK) {
        field.stringValue = panel.URL.path;
    }
}

- (void)stopScan:(id)sender {
    if (self.isScanning) {
        self.shouldStop = YES;
        self.stopButton.enabled = NO;
    } else {
        // Rescan
        [self startScanning];
    }
}

- (void)cancel:(id)sender {
    self.shouldStop = YES;
    [self.window close];
    [self.delegate pathMappingDidCancel:self];
}

- (void)doImport:(id)sender {
    // Collect all mappings
    NSMutableDictionary<NSString *, NSString *> *mappings = [NSMutableDictionary dictionary];
    for (NSString *drive in self.mappingFields) {
        NSTextField *field = self.mappingFields[drive];
        if (field.stringValue.length > 0) {
            mappings[drive] = field.stringValue;
        }
    }

    NSString *defaultMapping = self.defaultMappingField.stringValue;

    [self.window close];
    [self.delegate pathMappingDidComplete:self mappings:mappings defaultMapping:defaultMapping];
}

@end
