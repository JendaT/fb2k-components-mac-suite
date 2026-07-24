//
//  ArtworkLightboxController.mm
//  foo_jl_album_art_mac
//
//  Modal preview controller for browsing and selecting remote artwork
//

#import "ArtworkLightboxController.h"
#import "../Core/RemoteArtworkTypes.h"

static const CGFloat kWindowWidth = 700.0;
static const CGFloat kWindowHeight = 600.0;
static const CGFloat kBottomBarHeight = 50.0;
static const CGFloat kTypeButtonHeight = 24.0;
static const CGFloat kNavButtonSize = 36.0;

@interface ArtworkLightboxController () <NSWindowDelegate>

// Window
@property (nonatomic, strong) NSWindow *lightboxWindow;
@property (nonatomic, weak) NSWindow *parentWindow;

// UI elements
@property (nonatomic, strong) NSStackView *typeFilterStack;
@property (nonatomic, strong) NSImageView *imageView;
@property (nonatomic, strong) NSProgressIndicator *loadingSpinner;
@property (nonatomic, strong) NSTextField *infoLabel;
@property (nonatomic, strong) NSTextField *errorLabel;
@property (nonatomic, strong) NSButton *retryButton;
@property (nonatomic, strong) NSButton *prevButton;
@property (nonatomic, strong) NSButton *nextButton;
@property (nonatomic, strong) NSButton *confirmButton;
@property (nonatomic, strong) NSButton *cancelButton;

// State
@property (nonatomic, strong, readwrite) TrackMetadata *metadata;
@property (nonatomic, copy, readwrite) NSArray<ArtworkResult *> *allResults;
@property (nonatomic, strong, readwrite, nullable) ArtworkResult *selectedResult;
@property (nonatomic, strong, readwrite, nullable) NSImage *selectedImage;
@property (nonatomic, copy) NSArray<ArtworkResult *> *filteredResults;
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, strong, nullable) NSNumber *currentTypeFilter;
// Bounded so browsing many large (multi-MB decoded) covers cannot grow without
// limit; NSCache also purges automatically under memory pressure.
@property (nonatomic, strong) NSCache<NSURL *, NSImage *> *imageCache;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentDownloadTask;

// Multi-select state: selected result and image per artwork type
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, ArtworkResult *> *selectedResultsByType;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSImage *> *selectedImagesByType;

// Selection checkbox
@property (nonatomic, strong) NSButton *selectCheckbox;

// Track which types have been auto-selected (so we don't override user changes)
@property (nonatomic, strong) NSMutableSet<NSNumber *> *autoSelectedTypes;

// Ensures the delegate hears about dismissal exactly once (closing the
// window via the close button also fires windowWillClose)
@property (nonatomic, assign) BOOL didNotifyDelegate;

@end

@implementation ArtworkLightboxController

- (instancetype)initWithResults:(NSArray<ArtworkResult *> *)results
                       metadata:(TrackMetadata *)metadata
                  initialIndex:(NSInteger)initialIndex {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _allResults = [results copy];
        _metadata = metadata;
        _filteredResults = results;
        _currentIndex = initialIndex;
        _currentTypeFilter = nil;
        _imageCache = [[NSCache alloc] init];
        _imageCache.countLimit = 10;
        _selectedResultsByType = [NSMutableDictionary dictionary];
        _selectedImagesByType = [NSMutableDictionary dictionary];
        _autoSelectedTypes = [NSMutableSet set];
    }
    return self;
}

- (void)dealloc {
    [self.currentDownloadTask cancel];
}

#pragma mark - View Lifecycle

- (void)loadView {
    // Create main container view
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kWindowWidth, kWindowHeight)];
    container.wantsLayer = YES;
    self.view = container;

    [self buildUI];
    [self autoSelectFirstOfEachType];
    [self updateTypeFilterButtons];
    [self updateDisplay];
}

- (void)autoSelectFirstOfEachType {
    // Pre-select only the initially displayed result. Other types must be
    // viewed (or checked) explicitly - auto-selecting every type would let
    // "Save Selected" claim images whose data never loaded, silently saving
    // fewer images than the button promised.
    if (self.currentIndex < 0 || self.currentIndex >= (NSInteger)self.filteredResults.count) {
        return;
    }

    ArtworkResult *initial = self.filteredResults[self.currentIndex];
    NSNumber *typeKey = @(initial.artworkType);
    self.selectedResultsByType[typeKey] = initial;
    [self.autoSelectedTypes addObject:typeKey];
}

- (void)buildUI {
    NSView *container = self.view;

    // Type filter toolbar at top
    self.typeFilterStack = [[NSStackView alloc] init];
    self.typeFilterStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.typeFilterStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.typeFilterStack.spacing = 8;
    self.typeFilterStack.alignment = NSLayoutAttributeCenterY;
    self.typeFilterStack.distribution = NSStackViewDistributionFill;
    [container addSubview:self.typeFilterStack];

    // Image view (center area)
    self.imageView = [[NSImageView alloc] init];
    self.imageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.imageView.wantsLayer = YES;
    self.imageView.layer.backgroundColor = [[NSColor blackColor] colorWithAlphaComponent:0.05].CGColor;
    [container addSubview:self.imageView];

    // Loading spinner (overlay on image view)
    self.loadingSpinner = [[NSProgressIndicator alloc] init];
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingSpinner.style = NSProgressIndicatorStyleSpinning;
    self.loadingSpinner.controlSize = NSControlSizeLarge;
    self.loadingSpinner.hidden = YES;
    [container addSubview:self.loadingSpinner];

    // Navigation buttons (overlay on left/right)
    self.prevButton = [self createNavButtonWithSymbol:@"chevron.left" action:@selector(navigateToPrevious)];
    self.nextButton = [self createNavButtonWithSymbol:@"chevron.right" action:@selector(navigateToNext)];
    [container addSubview:self.prevButton];
    [container addSubview:self.nextButton];

    // Info label (below image)
    self.infoLabel = [NSTextField labelWithString:@""];
    self.infoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.infoLabel.alignment = NSTextAlignmentCenter;
    self.infoLabel.font = [NSFont systemFontOfSize:12.0];
    self.infoLabel.textColor = [NSColor secondaryLabelColor];
    [container addSubview:self.infoLabel];

    // Error label (centered on image, hidden by default)
    self.errorLabel = [NSTextField labelWithString:@""];
    self.errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorLabel.alignment = NSTextAlignmentCenter;
    self.errorLabel.font = [NSFont systemFontOfSize:13.0];
    self.errorLabel.textColor = [NSColor systemRedColor];
    self.errorLabel.hidden = YES;
    [container addSubview:self.errorLabel];

    // Retry button (centered below error label, hidden by default)
    self.retryButton = [NSButton buttonWithTitle:@"Retry" target:self action:@selector(retryLoadImage)];
    self.retryButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.retryButton.bezelStyle = NSBezelStyleRounded;
    self.retryButton.hidden = YES;
    [container addSubview:self.retryButton];

    // Selection checkbox (below info label, above bottom bar)
    self.selectCheckbox = [NSButton checkboxWithTitle:@"Include this image" target:self action:@selector(toggleSelection:)];
    self.selectCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectCheckbox.state = NSControlStateValueOff;
    [container addSubview:self.selectCheckbox];

    // Bottom button bar
    NSView *bottomBar = [[NSView alloc] init];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:bottomBar];

    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(dismiss)];
    self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton.keyEquivalent = @"\e"; // Escape
    [bottomBar addSubview:self.cancelButton];

    self.confirmButton = [NSButton buttonWithTitle:@"Save Selected" target:self action:@selector(confirmSelection)];
    self.confirmButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.confirmButton.bezelStyle = NSBezelStyleRounded;
    self.confirmButton.keyEquivalent = @"\r"; // Enter
    [self.confirmButton setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [bottomBar addSubview:self.confirmButton];

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        // Type filter stack
        [self.typeFilterStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:12],
        [self.typeFilterStack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [self.typeFilterStack.heightAnchor constraintEqualToConstant:kTypeButtonHeight],

        // Image view
        [self.imageView.topAnchor constraintEqualToAnchor:self.typeFilterStack.bottomAnchor constant:12],
        [self.imageView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:50],
        [self.imageView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-50],
        [self.imageView.bottomAnchor constraintEqualToAnchor:self.infoLabel.topAnchor constant:-8],

        // Loading spinner (centered in image view)
        [self.loadingSpinner.centerXAnchor constraintEqualToAnchor:self.imageView.centerXAnchor],
        [self.loadingSpinner.centerYAnchor constraintEqualToAnchor:self.imageView.centerYAnchor],

        // Error label (centered in image view)
        [self.errorLabel.centerXAnchor constraintEqualToAnchor:self.imageView.centerXAnchor],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:self.imageView.centerYAnchor constant:-12],
        [self.errorLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.imageView.widthAnchor constant:-40],

        // Retry button (below error label)
        [self.retryButton.centerXAnchor constraintEqualToAnchor:self.imageView.centerXAnchor],
        [self.retryButton.topAnchor constraintEqualToAnchor:self.errorLabel.bottomAnchor constant:8],

        // Nav buttons
        [self.prevButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.prevButton.centerYAnchor constraintEqualToAnchor:self.imageView.centerYAnchor],
        [self.prevButton.widthAnchor constraintEqualToConstant:kNavButtonSize],
        [self.prevButton.heightAnchor constraintEqualToConstant:kNavButtonSize],

        [self.nextButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.nextButton.centerYAnchor constraintEqualToAnchor:self.imageView.centerYAnchor],
        [self.nextButton.widthAnchor constraintEqualToConstant:kNavButtonSize],
        [self.nextButton.heightAnchor constraintEqualToConstant:kNavButtonSize],

        // Info label
        [self.infoLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
        [self.infoLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20],
        [self.infoLabel.bottomAnchor constraintEqualToAnchor:self.selectCheckbox.topAnchor constant:-4],
        [self.infoLabel.heightAnchor constraintEqualToConstant:18],

        // Selection checkbox
        [self.selectCheckbox.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [self.selectCheckbox.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:-8],

        // Bottom bar
        [bottomBar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [bottomBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [bottomBar.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [bottomBar.heightAnchor constraintEqualToConstant:kBottomBarHeight],

        // Buttons in bottom bar
        [self.cancelButton.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor constant:20],
        [self.cancelButton.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],

        [self.confirmButton.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor constant:-20],
        [self.confirmButton.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],
    ]];
}

- (NSButton *)createNavButtonWithSymbol:(NSString *)symbolName action:(SEL)action {
    NSButton *button = [[NSButton alloc] init];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.bezelStyle = NSBezelStyleCircular;
    button.bordered = YES;
    button.target = self;
    button.action = action;

    if (@available(macOS 11.0, *)) {
        NSImage *symbol = [NSImage imageWithSystemSymbolName:symbolName accessibilityDescription:nil];
        if (symbol) {
            button.image = symbol;
        }
    } else {
        // Fallback for older macOS
        button.title = [symbolName isEqualToString:@"chevron.left"] ? @"<" : @">";
    }

    return button;
}

#pragma mark - Type Filter

- (void)updateTypeFilterButtons {
    // Remove existing buttons
    for (NSView *view in [self.typeFilterStack.arrangedSubviews copy]) {
        [self.typeFilterStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    // Count results by type
    NSMutableDictionary<NSNumber *, NSNumber *> *typeCounts = [NSMutableDictionary dictionary];
    for (ArtworkResult *result in self.allResults) {
        NSNumber *typeKey = @(result.artworkType);
        typeCounts[typeKey] = @(typeCounts[typeKey].integerValue + 1);
    }

    // "All" button
    NSButton *allButton = [self createTypeFilterButton:@"All"
                                                 count:self.allResults.count
                                              selected:(self.currentTypeFilter == nil)
                                                   tag:-1];
    [self.typeFilterStack addArrangedSubview:allButton];

    // Type-specific buttons (only for types that have results)
    NSArray *typeOrder = @[@(RemoteArtworkTypeFront), @(RemoteArtworkTypeBack),
                           @(RemoteArtworkTypeDisc), @(RemoteArtworkTypeBooklet),
                           @(RemoteArtworkTypeArtist), @(RemoteArtworkTypeOther)];

    for (NSNumber *typeNum in typeOrder) {
        NSNumber *count = typeCounts[typeNum];
        if (count.integerValue > 0) {
            RemoteArtworkType type = (RemoteArtworkType)typeNum.integerValue;
            NSString *typeName = RemoteArtworkTypeName(type);
            BOOL selected = [self.currentTypeFilter isEqual:typeNum];

            NSButton *button = [self createTypeFilterButton:typeName
                                                      count:count.integerValue
                                                   selected:selected
                                                        tag:typeNum.integerValue];
            [self.typeFilterStack addArrangedSubview:button];
        }
    }
}

- (NSButton *)createTypeFilterButton:(NSString *)title count:(NSInteger)count selected:(BOOL)selected tag:(NSInteger)tag {
    NSString *label = [NSString stringWithFormat:@"%@ (%ld)", title, (long)count];
    NSButton *button = [NSButton buttonWithTitle:label target:self action:@selector(typeFilterButtonClicked:)];
    button.bezelStyle = NSBezelStyleRounded;
    button.tag = tag;

    if (selected) {
        button.state = NSControlStateValueOn;
        if (@available(macOS 10.14, *)) {
            button.contentTintColor = [NSColor controlAccentColor];
        }
    }

    return button;
}

- (void)typeFilterButtonClicked:(NSButton *)sender {
    if (sender.tag < 0) {
        [self filterByType:nil];
    } else {
        [self filterByType:@(sender.tag)];
    }
}

- (void)filterByType:(nullable NSNumber *)type {
    self.currentTypeFilter = type;

    if (type == nil) {
        self.filteredResults = self.allResults;
    } else {
        NSPredicate *pred = [NSPredicate predicateWithFormat:@"artworkType == %@", type];
        self.filteredResults = [self.allResults filteredArrayUsingPredicate:pred];
    }

    // Reset to first result in filtered set
    self.currentIndex = 0;

    [self updateTypeFilterButtons];
    [self updateDisplay];
}

#pragma mark - Selection

- (void)toggleSelection:(NSButton *)sender {
    if (!self.selectedResult || !self.selectedImage) {
        return;
    }

    NSNumber *typeKey = @(self.selectedResult.artworkType);

    if (sender.state == NSControlStateValueOn) {
        // Add to selection
        self.selectedResultsByType[typeKey] = self.selectedResult;
        self.selectedImagesByType[typeKey] = self.selectedImage;
    } else {
        // Remove from selection
        [self.selectedResultsByType removeObjectForKey:typeKey];
        [self.selectedImagesByType removeObjectForKey:typeKey];
    }

    [self updateConfirmButton];
}

- (void)updateConfirmButton {
    NSUInteger count = self.selectedResultsByType.count;
    if (count == 0) {
        self.confirmButton.title = @"Save Selected";
        self.confirmButton.enabled = NO;
    } else if (count == 1) {
        self.confirmButton.title = @"Save Selected (1)";
        self.confirmButton.enabled = YES;
    } else {
        self.confirmButton.title = [NSString stringWithFormat:@"Save Selected (%lu)", (unsigned long)count];
        self.confirmButton.enabled = YES;
    }
}

- (void)updateCheckboxState {
    if (!self.selectedResult) {
        self.selectCheckbox.enabled = NO;
        self.selectCheckbox.state = NSControlStateValueOff;
        return;
    }

    NSNumber *typeKey = @(self.selectedResult.artworkType);
    ArtworkResult *selectedForType = self.selectedResultsByType[typeKey];

    self.selectCheckbox.enabled = (self.selectedImage != nil);

    if (selectedForType && [selectedForType isEqual:self.selectedResult]) {
        self.selectCheckbox.state = NSControlStateValueOn;
    } else {
        self.selectCheckbox.state = NSControlStateValueOff;
    }
}

#pragma mark - Navigation

- (void)navigateToPrevious {
    if (self.filteredResults.count == 0) return;

    self.currentIndex--;
    if (self.currentIndex < 0) {
        self.currentIndex = self.filteredResults.count - 1;
    }

    [self updateDisplay];
}

- (void)navigateToNext {
    if (self.filteredResults.count == 0) return;

    self.currentIndex++;
    if (self.currentIndex >= (NSInteger)self.filteredResults.count) {
        self.currentIndex = 0;
    }

    [self updateDisplay];
}

#pragma mark - Display Update

- (void)updateDisplay {
    if (self.filteredResults.count == 0) {
        self.selectedResult = nil;
        self.selectedImage = nil;
        self.imageView.image = nil;
        self.infoLabel.stringValue = @"No images available";
        self.prevButton.enabled = NO;
        self.nextButton.enabled = NO;
        [self updateCheckboxState];
        [self updateConfirmButton];
        return;
    }

    // Clamp index
    if (self.currentIndex < 0) self.currentIndex = 0;
    if (self.currentIndex >= (NSInteger)self.filteredResults.count) {
        self.currentIndex = self.filteredResults.count - 1;
    }

    self.selectedResult = self.filteredResults[self.currentIndex];

    // Update navigation buttons
    BOOL canNavigate = self.filteredResults.count > 1;
    self.prevButton.enabled = canNavigate;
    self.nextButton.enabled = canNavigate;

    // Update info label
    [self updateInfoLabel];

    // Update checkbox state
    [self updateCheckboxState];

    // Load full-resolution image
    [self loadFullResolutionImage];
}

- (void)updateInfoLabel {
    if (!self.selectedResult) {
        self.infoLabel.stringValue = @"";
        return;
    }

    NSString *typeName = RemoteArtworkTypeName(self.selectedResult.artworkType);
    NSString *variants = @"";
    if (self.selectedResult.variants.count > 0) {
        variants = [NSString stringWithFormat:@" (%@)", [self.selectedResult.variants componentsJoinedByString:@", "]];
    }

    NSString *position = [NSString stringWithFormat:@"%ld of %ld",
                          (long)(self.currentIndex + 1),
                          (long)self.filteredResults.count];

    NSString *resolution = @"";
    if (self.selectedResult.resolution.width > 0) {
        resolution = [NSString stringWithFormat:@" - %.0fx%.0f",
                      self.selectedResult.resolution.width,
                      self.selectedResult.resolution.height];
    }

    NSString *source = [NSString stringWithFormat:@" from %@", self.selectedResult.sourceName];

    self.infoLabel.stringValue = [NSString stringWithFormat:@"%@ - %@%@%@%@",
                                  position, typeName, variants, resolution, source];
}

- (void)loadFullResolutionImage {
    [self loadFullResolutionImageWithFallback:NO];
}

- (void)loadFullResolutionImageWithFallback:(BOOL)useThumbnail {
    if (!self.selectedResult) return;

    NSURL *url = useThumbnail ? self.selectedResult.thumbnailURL : self.selectedResult.fullResolutionURL;
    if (!url) {
        url = self.selectedResult.thumbnailURL ?: self.selectedResult.fullResolutionURL;
    }
    if (!url) {
        // Nothing loadable for this result; dataTaskWithURL:nil would throw.
        [self showImageLoadError:@"No image URL available"];
        return;
    }

    // Check cache
    NSImage *cached = [self.imageCache objectForKey:url];
    if (cached) {
        [self handleLoadedImage:cached forURL:url];
        return;
    }

    // Cancel previous download
    [self.currentDownloadTask cancel];

    // Show loading state, hide error state
    self.imageView.image = nil;
    self.loadingSpinner.hidden = NO;
    [self.loadingSpinner startAnimation:nil];
    self.errorLabel.hidden = YES;
    self.retryButton.hidden = YES;
    self.confirmButton.enabled = NO;

    ArtworkResult *loadingResult = self.selectedResult;

    // Download
    NSURLSession *session = [NSURLSession sharedSession];
    self.currentDownloadTask = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loadingSpinner.hidden = YES;
            [self.loadingSpinner stopAnimation:nil];

            // Verify still on same result
            if (self.selectedResult != loadingResult) return;

            if (error || !data) {
                if (!useThumbnail && self.selectedResult.thumbnailURL) {
                    // Full-res failed - try thumbnail as fallback
                    [self loadFullResolutionImageWithFallback:YES];
                } else {
                    [self showImageLoadError:@"Failed to load image"];
                }
                return;
            }

            NSImage *image = [[NSImage alloc] initWithData:data];
            if (!image) {
                if (!useThumbnail && self.selectedResult.thumbnailURL) {
                    [self loadFullResolutionImageWithFallback:YES];
                } else {
                    [self showImageLoadError:@"Invalid image data"];
                }
                return;
            }

            // Cache it
            [self.imageCache setObject:image forKey:url];
            [self handleLoadedImage:image forURL:url];
        });
    }];

    [self.currentDownloadTask resume];
}

- (void)handleLoadedImage:(NSImage *)image forURL:(NSURL *)url {
    self.selectedImage = image;
    self.imageView.image = image;
    self.errorLabel.hidden = YES;
    self.retryButton.hidden = YES;

    // If this result was auto-selected, store its image now
    NSNumber *typeKey = @(self.selectedResult.artworkType);
    if ([self.autoSelectedTypes containsObject:typeKey] &&
        [self.selectedResultsByType[typeKey] isEqual:self.selectedResult]) {
        self.selectedImagesByType[typeKey] = image;
    }

    // Update checkbox and button state now that image is available
    [self updateCheckboxState];
    [self updateConfirmButton];

    // Update info label with actual resolution
    if (image.size.width > 0) {
        [self updateInfoLabel];
    }
}

- (void)showImageLoadError:(NSString *)message {
    self.errorLabel.stringValue = message;
    self.errorLabel.hidden = NO;
    self.retryButton.hidden = NO;
    self.selectedImage = nil;
    [self updateCheckboxState];
    [self updateConfirmButton];
}

- (void)retryLoadImage {
    [self loadFullResolutionImage];
}

#pragma mark - Presentation

- (NSWindow *)makeLightboxWindow {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kWindowWidth, kWindowHeight)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    // ARC owns the window through our strong property; the default
    // releasedWhenClosed=YES would over-release it on close
    window.releasedWhenClosed = NO;
    window.title = @"Select Artwork";
    window.contentViewController = self;
    window.delegate = self;
    return window;
}

- (void)presentAsSheetOnWindow:(NSWindow *)parentWindow {
    self.parentWindow = parentWindow;
    self.lightboxWindow = [self makeLightboxWindow];

    NSWindow *sheetWindow = self.lightboxWindow;
    [parentWindow beginSheet:sheetWindow completionHandler:^(NSModalResponse returnCode) {
        // endSheet: only detaches the sheet; without an explicit orderOut
        // AppKit keeps the window (and this controller) alive forever
        [sheetWindow orderOut:nil];
    }];
}

- (void)presentAsModalWindow {
    self.lightboxWindow = [self makeLightboxWindow];

    // Center on screen
    [self.lightboxWindow center];

    [self.lightboxWindow makeKeyAndOrderFront:nil];
    [NSApp runModalForWindow:self.lightboxWindow];
}

- (void)dismiss {
    [self.currentDownloadTask cancel];

    BOOL shouldNotify = !self.didNotifyDelegate;
    self.didNotifyDelegate = YES;

    if (self.parentWindow && self.lightboxWindow) {
        [self.parentWindow endSheet:self.lightboxWindow];
    } else if (self.lightboxWindow) {
        [NSApp stopModal];
        [self.lightboxWindow close];
    }

    if (shouldNotify && [self.delegate respondsToSelector:@selector(lightboxDidCancel:)]) {
        [self.delegate lightboxDidCancel:self];
    }

    self.lightboxWindow = nil;
}

- (void)confirmSelection {
    // Only types whose image data actually loaded can be saved; prune any
    // selection whose download never finished
    for (NSNumber *typeKey in [self.selectedResultsByType.allKeys copy]) {
        if (!self.selectedImagesByType[typeKey]) {
            [self.selectedResultsByType removeObjectForKey:typeKey];
        }
    }

    if (self.selectedResultsByType.count == 0) {
        [self updateConfirmButton];
        return;
    }

    self.didNotifyDelegate = YES;
    [self.currentDownloadTask cancel];

    if (self.parentWindow && self.lightboxWindow) {
        [self.parentWindow endSheet:self.lightboxWindow];
    } else if (self.lightboxWindow) {
        [NSApp stopModal];
        [self.lightboxWindow close];
    }

    // Prefer multi-select delegate if available
    if ([self.delegate respondsToSelector:@selector(lightbox:didSelectResults:withImages:)]) {
        [self.delegate lightbox:self
              didSelectResults:[self.selectedResultsByType copy]
                    withImages:[self.selectedImagesByType copy]];
    } else if (self.selectedResultsByType.count == 1 &&
               [self.delegate respondsToSelector:@selector(lightbox:didSelectResult:withImage:)]) {
        // Fallback to single-select delegate
        NSNumber *typeKey = self.selectedResultsByType.allKeys.firstObject;
        [self.delegate lightbox:self
              didSelectResult:self.selectedResultsByType[typeKey]
                    withImage:self.selectedImagesByType[typeKey]];
    }

    self.lightboxWindow = nil;
}

#pragma mark - Keyboard Handling

- (void)keyDown:(NSEvent *)event {
    NSString *chars = [event charactersIgnoringModifiers];
    if (chars.length == 0) {
        [super keyDown:event];
        return;
    }

    unichar key = [chars characterAtIndex:0];

    switch (key) {
        case NSLeftArrowFunctionKey:
            [self navigateToPrevious];
            break;
        case NSRightArrowFunctionKey:
            [self navigateToNext];
            break;
        case ' ':
            // Space: toggle "Include this image" checkbox
            if (self.selectCheckbox.isEnabled) {
                self.selectCheckbox.state = (self.selectCheckbox.state == NSControlStateValueOn)
                    ? NSControlStateValueOff : NSControlStateValueOn;
                [self toggleSelection:self.selectCheckbox];
            }
            break;
        default:
            // 1-9: jump to type filter button by index
            if (key >= '1' && key <= '9') {
                NSUInteger buttonIndex = key - '1';  // 0-based
                NSArray<NSView *> *buttons = self.typeFilterStack.arrangedSubviews;
                if (buttonIndex < buttons.count) {
                    NSButton *button = (NSButton *)buttons[buttonIndex];
                    if ([button isKindOfClass:[NSButton class]]) {
                        [self typeFilterButtonClicked:button];
                    }
                }
            } else {
                [super keyDown:event];
            }
            break;
    }
}

#pragma mark - NSWindowDelegate

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.lightboxWindow && !self.didNotifyDelegate) {
        self.didNotifyDelegate = YES;
        if ([self.delegate respondsToSelector:@selector(lightboxDidCancel:)]) {
            [self.delegate lightboxDidCancel:self];
        }
    }
}

@end
