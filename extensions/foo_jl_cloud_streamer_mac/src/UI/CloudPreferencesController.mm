//
//  CloudPreferencesController.mm
//  foo_jl_cloud_streamer_mac
//
//  Preferences page implementation
//

#import "CloudPreferencesController.h"
#import "../Core/CloudConfig.h"
#import "../Core/StreamCache.h"
#import "../Core/MetadataCache.h"
#import "../Core/ThumbnailCache.h"
#import "../Services/YtDlpWrapper.h"
#import "../../../../shared/PreferencesCommon.h"

using namespace cloud_streamer;

@interface CloudPreferencesController ()
// yt-dlp configuration
@property (nonatomic, strong) NSTextField *ytdlpPathField;
@property (nonatomic, strong) NSButton *browseButton;
@property (nonatomic, strong) NSTextField *ytdlpStatusLabel;

// Format preferences
@property (nonatomic, strong) NSPopUpButton *mixcloudFormatPopup;
@property (nonatomic, strong) NSPopUpButton *soundcloudFormatPopup;

// Cache info
@property (nonatomic, strong) NSTextField *streamCacheLabel;
@property (nonatomic, strong) NSTextField *metadataCacheLabel;
@property (nonatomic, strong) NSTextField *thumbnailCacheLabel;
@property (nonatomic, strong) NSButton *clearCacheButton;

// Debug
@property (nonatomic, strong) NSButton *debugLoggingCheckbox;
@end

@implementation CloudPreferencesController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    return self;
}

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 400)];

    CGFloat leftMargin = JLPrefsLeftMargin;
    __block CGFloat currentY = 20;
    CGFloat rowHeight = JLPrefsRowHeight;
    CGFloat sectionGap = JLPrefsSectionGap;

    // Helper to add a view with Auto Layout
    void (^addRow)(NSView *, CGFloat) = ^(NSView *view, CGFloat height) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:container.topAnchor constant:currentY],
            [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:leftMargin],
            [view.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-leftMargin],
        ]];
        currentY += height;
    };

    void (^addIndentedRow)(NSView *, CGFloat) = ^(NSView *view, CGFloat height) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [view.topAnchor constraintEqualToAnchor:container.topAnchor constant:currentY],
            [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:leftMargin + JLPrefsIndent],
            [view.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-leftMargin],
        ]];
        currentY += height;
    };

    // ===== Title =====
    NSTextField *title = JLCreatePreferencesTitle(@"Cloud Streamer");
    addRow(title, 30);

    // ===== yt-dlp Section =====
    NSTextField *ytdlpSectionLabel = JLCreateSectionHeader(@"yt-dlp Configuration");
    addRow(ytdlpSectionLabel, rowHeight);

    // Path field row
    NSStackView *pathRow = [[NSStackView alloc] init];
    pathRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pathRow.spacing = 8;
    pathRow.alignment = NSLayoutAttributeCenterY;

    NSTextField *pathLabel = JLCreateLabel(@"Path:");
    pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [pathLabel.widthAnchor constraintEqualToConstant:40]
    ]];
    [pathRow addArrangedSubview:pathLabel];

    self.ytdlpPathField = [[NSTextField alloc] init];
    self.ytdlpPathField.translatesAutoresizingMaskIntoConstraints = NO;
    self.ytdlpPathField.font = [NSFont systemFontOfSize:11];
    self.ytdlpPathField.placeholderString = @"/opt/homebrew/bin/yt-dlp";
    [NSLayoutConstraint activateConstraints:@[
        [self.ytdlpPathField.widthAnchor constraintEqualToConstant:250]
    ]];
    [self.ytdlpPathField setTarget:self];
    [self.ytdlpPathField setAction:@selector(ytdlpPathChanged:)];
    [pathRow addArrangedSubview:self.ytdlpPathField];

    self.browseButton = [NSButton buttonWithTitle:@"Browse..."
                                           target:self
                                           action:@selector(browseForYtdlp:)];
    [pathRow addArrangedSubview:self.browseButton];

    addIndentedRow(pathRow, 28);

    // Status label
    self.ytdlpStatusLabel = JLCreateHelperText(@"Checking...");
    addIndentedRow(self.ytdlpStatusLabel, rowHeight + sectionGap);

    // ===== Format Preferences Section =====
    NSTextField *formatSectionLabel = JLCreateSectionHeader(@"Audio Format Preferences");
    addRow(formatSectionLabel, rowHeight);

    // Mixcloud format
    NSStackView *mixcloudRow = [[NSStackView alloc] init];
    mixcloudRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    mixcloudRow.spacing = 8;
    mixcloudRow.alignment = NSLayoutAttributeCenterY;

    NSTextField *mixcloudLabel = JLCreateLabel(@"Mixcloud:");
    mixcloudLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [mixcloudLabel.widthAnchor constraintEqualToConstant:80]
    ]];
    [mixcloudRow addArrangedSubview:mixcloudLabel];

    self.mixcloudFormatPopup = [[NSPopUpButton alloc] init];
    [self.mixcloudFormatPopup addItemsWithTitles:@[@"Best Quality", @"128 kbps AAC", @"64 kbps AAC"]];
    [self.mixcloudFormatPopup setTarget:self];
    [self.mixcloudFormatPopup setAction:@selector(formatChanged:)];
    [mixcloudRow addArrangedSubview:self.mixcloudFormatPopup];

    addIndentedRow(mixcloudRow, rowHeight + 4);

    // SoundCloud format
    NSStackView *soundcloudRow = [[NSStackView alloc] init];
    soundcloudRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    soundcloudRow.spacing = 8;
    soundcloudRow.alignment = NSLayoutAttributeCenterY;

    NSTextField *soundcloudLabel = JLCreateLabel(@"SoundCloud:");
    soundcloudLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [soundcloudLabel.widthAnchor constraintEqualToConstant:80]
    ]];
    [soundcloudRow addArrangedSubview:soundcloudLabel];

    self.soundcloudFormatPopup = [[NSPopUpButton alloc] init];
    [self.soundcloudFormatPopup addItemsWithTitles:@[@"Best Quality", @"256 kbps MP3", @"128 kbps MP3"]];
    [self.soundcloudFormatPopup setTarget:self];
    [self.soundcloudFormatPopup setAction:@selector(formatChanged:)];
    [soundcloudRow addArrangedSubview:self.soundcloudFormatPopup];

    addIndentedRow(soundcloudRow, rowHeight + 4 + sectionGap);

    // ===== Cache Section =====
    NSTextField *cacheSectionLabel = JLCreateSectionHeader(@"Cache");
    addRow(cacheSectionLabel, rowHeight);

    self.streamCacheLabel = JLCreateLabel(@"Stream URLs: 0 entries");
    addIndentedRow(self.streamCacheLabel, rowHeight);

    self.metadataCacheLabel = JLCreateLabel(@"Metadata: 0 entries");
    addIndentedRow(self.metadataCacheLabel, rowHeight);

    self.thumbnailCacheLabel = JLCreateLabel(@"Thumbnails: 0 entries, 0 MB");
    addIndentedRow(self.thumbnailCacheLabel, rowHeight + 8);

    self.clearCacheButton = [NSButton buttonWithTitle:@"Clear All Caches"
                                               target:self
                                               action:@selector(clearCaches:)];
    addIndentedRow(self.clearCacheButton, 32 + sectionGap);

    // ===== Debug Section =====
    NSTextField *debugSectionLabel = JLCreateSectionHeader(@"Troubleshooting");
    addRow(debugSectionLabel, rowHeight);

    self.debugLoggingCheckbox = [NSButton checkboxWithTitle:@"Enable debug logging"
                                                     target:self
                                                     action:@selector(debugLoggingChanged:)];
    addIndentedRow(self.debugLoggingCheckbox, rowHeight);

    NSTextField *debugHelperText = JLCreateHelperText(@"Debug messages appear in View > Console");
    addIndentedRow(debugHelperText, rowHeight);

    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadSettings];
    [self updateCacheStats];
    [self validateYtdlp];
}

#pragma mark - Settings

- (void)loadSettings {
    std::string ytdlpPath = CloudConfig::getYtDlpPath();
    if (!ytdlpPath.empty()) {
        self.ytdlpPathField.stringValue = [NSString stringWithUTF8String:ytdlpPath.c_str()];
    }

    [self.mixcloudFormatPopup selectItemAtIndex:(NSInteger)CloudConfig::getMixcloudFormat()];
    [self.soundcloudFormatPopup selectItemAtIndex:(NSInteger)CloudConfig::getSoundCloudFormat()];
    self.debugLoggingCheckbox.state = CloudConfig::isDebugLoggingEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)saveSettings {
    std::string path = std::string([self.ytdlpPathField.stringValue UTF8String]);
    CloudConfig::setYtDlpPath(path);
    CloudConfig::setMixcloudFormat((MixcloudFormat)self.mixcloudFormatPopup.indexOfSelectedItem);
    CloudConfig::setSoundCloudFormat((SoundCloudFormat)self.soundcloudFormatPopup.indexOfSelectedItem);
    CloudConfig::setDebugLoggingEnabled(self.debugLoggingCheckbox.state == NSControlStateValueOn);
}

#pragma mark - Actions

- (void)ytdlpPathChanged:(id)sender {
    [self saveSettings];
    [self validateYtdlp];
}

- (void)browseForYtdlp:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.directoryURL = [NSURL fileURLWithPath:@"/opt/homebrew/bin"];
    panel.message = @"Select yt-dlp executable";

    __weak typeof(self) weakSelf = self;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            weakSelf.ytdlpPathField.stringValue = panel.URL.path;
            [weakSelf saveSettings];
            [weakSelf validateYtdlp];
        }
    }];
}

- (void)formatChanged:(id)sender {
    [self saveSettings];
}

- (void)debugLoggingChanged:(id)sender {
    [self saveSettings];
}

- (void)clearCaches:(id)sender {
    StreamCache::shared().clear();
    MetadataCache::shared().clear();
    ThumbnailCache::shared().clear();

    [self updateCacheStats];

    // Show confirmation
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Caches Cleared";
    alert.informativeText = @"All cached stream URLs, metadata, and thumbnails have been removed.";
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

#pragma mark - Updates

- (void)validateYtdlp {
    NSString *path = self.ytdlpPathField.stringValue;
    if (path.length == 0) {
        self.ytdlpStatusLabel.stringValue = @"No path specified - auto-detection failed";
        self.ytdlpStatusLabel.textColor = [NSColor systemOrangeColor];
        return;
    }

    self.ytdlpStatusLabel.stringValue = @"Validating...";
    self.ytdlpStatusLabel.textColor = [NSColor secondaryLabelColor];

    std::string pathStr = std::string([path UTF8String]);
    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        bool valid = YtDlpWrapper::shared().validateBinary(pathStr);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (valid) {
                weakSelf.ytdlpStatusLabel.stringValue = @"Valid yt-dlp installation";
                weakSelf.ytdlpStatusLabel.textColor = [NSColor systemGreenColor];
            } else {
                weakSelf.ytdlpStatusLabel.stringValue = @"Invalid or not executable";
                weakSelf.ytdlpStatusLabel.textColor = [NSColor systemRedColor];
            }
        });
    });
}

- (void)updateCacheStats {
    size_t streamCount = StreamCache::shared().size();
    size_t metadataCount = MetadataCache::shared().size();
    size_t thumbnailCount = ThumbnailCache::shared().entryCount();
    uint64_t thumbnailBytes = ThumbnailCache::shared().diskUsage();

    self.streamCacheLabel.stringValue = [NSString stringWithFormat:@"Stream URLs: %zu entries", streamCount];
    self.metadataCacheLabel.stringValue = [NSString stringWithFormat:@"Metadata: %zu entries", metadataCount];
    self.thumbnailCacheLabel.stringValue = [NSString stringWithFormat:@"Thumbnails: %zu entries, %.1f MB",
                                            thumbnailCount, (double)thumbnailBytes / (1024.0 * 1024.0)];
}

@end
