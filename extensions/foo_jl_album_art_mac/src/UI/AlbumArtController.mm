//
//  AlbumArtController.mm
//  foo_jl_album_art_mac
//
//  Main controller implementation
//

#import "AlbumArtController.h"
#import "../Core/AlbumArtFetcher.h"
#import "../Core/AlbumArtConfig.h"
#import "../Core/TrackMetadata.h"
#import "../Core/TrackMetadata+FB2K.h"
#import "../Core/ArtworkResult.h"
#import "../Core/ArtworkEmbedController.h"
#import "../Core/RemoteArtworkTypes.h"
#import "../../../../shared/NetworkReachability.h"

using namespace albumart_config;

static const NSTimeInterval kErrorAutoHideDelay = 3.0;

@interface AlbumArtController ()
@property (nonatomic, strong) AlbumArtView *artView;
@property (nonatomic, copy) NSString *instanceGUID;
@property (nonatomic, assign) ArtworkType currentType;
@property (nonatomic, assign) ArtworkType defaultType;  // From layout params
@property (nonatomic, assign) BOOL isSquare;
@property (nonatomic, assign) BOOL isZoomable;
@property (nonatomic, strong) NSArray<NSNumber*> *availableTypes;
@property (nonatomic, assign) metadb_handle_ptr currentTrack;

// Remote artwork search
@property (nonatomic, strong) RemoteArtworkSearchController *searchController;
@property (nonatomic, strong) NSArray<ArtworkResult *> *searchResults;
// Thumbnails keyed by thumbnail URL string: the results array is re-sorted
// as sources respond, so index-based keys would attach images to the wrong
// results
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *thumbnailCache;
// Results currently shown in the footer (subset of searchResults with
// loaded thumbnails, in display order) - used to resolve thumbnail clicks
@property (nonatomic, strong) NSArray<ArtworkResult *> *displayedResults;

// Lightbox
@property (nonatomic, strong) ArtworkLightboxController *lightboxController;

// Save
@property (nonatomic, strong) ArtworkSaveController *saveController;

// Footer state generation counter for race-safe auto-hide
@property (nonatomic, assign) NSUInteger footerStateGeneration;
@end

@implementation AlbumArtController

- (instancetype)init {
    return [self initWithParameters:nil];
}

- (instancetype)initWithParameters:(NSDictionary<NSString*, NSString*>*)params {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        // Parse layout parameters
        _defaultType = ArtworkType::Front;
        _isSquare = NO;
        _isZoomable = NO;

        if (params) {
            // Parse type parameter
            NSString *typeStr = params[@"type"];
            if (typeStr) {
                _defaultType = parseTypeFromString([typeStr UTF8String]);
            }

            // Parse square parameter
            if (params[@"square"]) {
                _isSquare = YES;
            }

            // Parse zoomable parameter
            if (params[@"zoomable"]) {
                _isZoomable = YES;
            }
        }

        // Generate or load instance GUID
        // For simplicity, we generate a new GUID each time
        // In a more sophisticated implementation, we'd store this in the layout
        pfc::string8 guid = generateInstanceGUID();
        _instanceGUID = [NSString stringWithUTF8String:guid.c_str()];

        // Check if there's a saved type for this instance
        if (hasInstanceType(guid.c_str())) {
            _currentType = getInstanceType(guid.c_str(), _defaultType);
        } else {
            _currentType = _defaultType;
        }

        _availableTypes = @[];

        // Initialize search controller
        _searchController = [[RemoteArtworkSearchController alloc] init];
        _searchController.delegate = self;
        _thumbnailCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    AlbumArtCallbackManager::instance().unregisterController(self);
}

- (void)loadView {
    self.artView = [[AlbumArtView alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
    self.artView.delegate = self;
    self.artView.isSquare = self.isSquare;
    self.artView.isZoomable = self.isZoomable;
    self.artView.artworkTypeName = [NSString stringWithUTF8String:artworkTypeName(self.currentType)];
    self.view = self.artView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Register for playback callbacks
    AlbumArtCallbackManager::instance().registerController(self);

    // Check if there's a currently playing track
    metadb_handle_ptr currentTrack = AlbumArtCallbackManager::instance().getCurrentTrack();
    if (currentTrack.is_valid()) {
        [self handleNewTrack:currentTrack];
    }
}

#pragma mark - Playback Callbacks

- (void)handleNewTrack:(metadb_handle_ptr)track {
    BOOL isTrackChange = !self.currentTrack.is_valid() || self.currentTrack != track;
    self.currentTrack = track;

    // A stale search or its results belong to the previous track
    if (isTrackChange) {
        [self clearSearchState];
    }

    // Fetch available types on background thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray<NSNumber*>* available = [AlbumArtFetcher availableTypesForTrack:track];

        // Fetch artwork for current type
        NSImage* image = [AlbumArtFetcher fetchArtworkForTrack:track type:self.currentType];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.availableTypes = available;
            [self updateNavigationArrows];
            self.artView.image = image;
            self.artView.artworkTypeName = [NSString stringWithUTF8String:artworkTypeName(self.currentType)];
        });
    });
}

- (void)handlePlaybackStop {
    self.currentTrack.release();
    [self clearSearchState];
    self.availableTypes = @[];
    self.artView.image = nil;
    self.artView.canNavigatePrevious = NO;
    self.artView.canNavigateNext = NO;
    [self.artView refreshDisplay];
}

#pragma mark - Navigation

// Index of self.currentType within availableTypes, or -1 if not present.
- (NSInteger)indexOfCurrentType {
    for (NSUInteger i = 0; i < self.availableTypes.count; i++) {
        if (self.availableTypes[i].integerValue == static_cast<NSInteger>(self.currentType)) {
            return (NSInteger)i;
        }
    }
    return -1;
}

- (void)updateNavigationArrows {
    // Navigation wraps around, so with 2+ available types both directions are
    // always possible; with 0 or 1, neither is.
    BOOL canNavigate = self.availableTypes.count > 1;
    self.artView.canNavigatePrevious = canNavigate;
    self.artView.canNavigateNext = canNavigate;
}

- (void)navigateToPreviousType {
    if (self.availableTypes.count == 0) return;

    NSInteger currentIndex = [self indexOfCurrentType];

    // Move to previous (wrap around)
    NSInteger newIndex;
    if (currentIndex <= 0) {
        newIndex = self.availableTypes.count - 1;
    } else {
        newIndex = currentIndex - 1;
    }

    ArtworkType newType = static_cast<ArtworkType>(self.availableTypes[newIndex].integerValue);
    [self changeToType:newType];
}

- (void)navigateToNextType {
    if (self.availableTypes.count == 0) return;

    NSInteger currentIndex = [self indexOfCurrentType];

    // Move to next (wrap around)
    NSInteger newIndex;
    if (currentIndex < 0 || currentIndex >= (NSInteger)self.availableTypes.count - 1) {
        newIndex = 0;
    } else {
        newIndex = currentIndex + 1;
    }

    ArtworkType newType = static_cast<ArtworkType>(self.availableTypes[newIndex].integerValue);
    [self changeToType:newType];
}

- (void)changeToType:(ArtworkType)type {
    self.currentType = type;

    // Save to config
    setInstanceType([self.instanceGUID UTF8String], type);

    // Update UI
    self.artView.artworkTypeName = [NSString stringWithUTF8String:artworkTypeName(type)];
    [self updateNavigationArrows];

    // Fetch new artwork
    [self refreshArtwork];
}

- (void)refreshArtwork {
    if (!self.currentTrack.is_valid()) {
        self.artView.image = nil;
        return;
    }

    metadb_handle_ptr track = self.currentTrack;
    ArtworkType type = self.currentType;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSImage* image = [AlbumArtFetcher fetchArtworkForTrack:track type:type];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.artView.image = image;
        });
    });
}

#pragma mark - AlbumArtViewDelegate

- (void)albumArtViewRequestsContextMenu:(AlbumArtView*)view atPoint:(NSPoint)point {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Album Art"];
    // Respect explicit enabled flags (e.g. "Fetch Missing..." when offline)
    menu.autoenablesItems = NO;

    // Add artwork type items
    for (int i = 0; i < static_cast<int>(ArtworkType::Count); i++) {
        ArtworkType type = static_cast<ArtworkType>(i);
        const char* name = artworkTypeName(type);

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithUTF8String:name]
                                                      action:@selector(menuSelectType:)
                                               keyEquivalent:@""];
        item.target = self;
        item.tag = i;

        // Add checkmark for current type
        if (type == self.currentType) {
            item.state = NSControlStateValueOn;
        }

        [menu addItem:item];
    }

    // Add separator
    [menu addItem:[NSMenuItem separatorItem]];

    // Add "Fetch Missing..." menu item
    NSMenuItem *fetchItem = [[NSMenuItem alloc] initWithTitle:@"Fetch Missing..."
                                                       action:@selector(menuFetchMissing:)
                                                keyEquivalent:@""];
    fetchItem.target = self;

    // Disable if offline or no track
    BOOL canFetch = self.currentTrack.is_valid() &&
                    [[JLNetworkReachability sharedInstance] isReachable];
    fetchItem.enabled = canFetch;

    if (![[JLNetworkReachability sharedInstance] isReachable]) {
        fetchItem.title = @"Fetch Missing... (Offline)";
    }

    [menu addItem:fetchItem];

    // Reset remembered save options (only shown once a choice was remembered)
    if (![ArtworkSaveController shouldShowConfirmation]) {
        NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:@"Reset Artwork Save Options"
                                                           action:@selector(menuResetSaveOptions:)
                                                    keyEquivalent:@""];
        resetItem.target = self;
        [menu addItem:resetItem];
    }

    // Add separator and refresh
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh"
                                                         action:@selector(menuRefresh:)
                                                  keyEquivalent:@""];
    refreshItem.target = self;
    [menu addItem:refreshItem];

    // Show menu
    [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
}

- (void)albumArtViewNavigatePrevious:(AlbumArtView*)view {
    [self navigateToPreviousType];
}

- (void)albumArtViewNavigateNext:(AlbumArtView*)view {
    [self navigateToNextType];
}

- (void)albumArtViewDidRequestCancelSearch:(AlbumArtView*)view {
    [self cancelSearch];
}

#pragma mark - Menu Actions

- (void)menuSelectType:(NSMenuItem*)sender {
    ArtworkType type = static_cast<ArtworkType>(sender.tag);
    [self changeToType:type];
}

- (void)menuRefresh:(NSMenuItem*)sender {
    // Re-fetch available types and current artwork
    if (self.currentTrack.is_valid()) {
        [self handleNewTrack:self.currentTrack];
    }
}

- (void)menuFetchMissing:(NSMenuItem*)sender {
    [self fetchMissingArtwork];
}

- (void)menuResetSaveOptions:(NSMenuItem*)sender {
    [ArtworkSaveController resetToShowConfirmation];
}

#pragma mark - Remote Artwork Search

- (void)fetchMissingArtwork {
    if (!self.currentTrack.is_valid()) {
        return;
    }

    // Create metadata from current track
    TrackMetadata *metadata = [TrackMetadata metadataFromTrack:self.currentTrack];
    if (!metadata || !metadata.isSearchable) {
        [self.artView showError:@"Insufficient metadata for search"];
        return;
    }

    // Clear previous results
    self.searchResults = nil;
    self.displayedResults = nil;
    [self.thumbnailCache removeAllObjects];

    // Start search
    [self.searchController searchForArtworkWithMetadata:metadata];
}

- (void)cancelSearch {
    [self.searchController cancel];
    [self.artView hideFooter];
}

- (void)clearSearchState {
    [self.searchController cancel];
    self.searchResults = nil;
    self.displayedResults = nil;
    [self.thumbnailCache removeAllObjects];
    [self.artView hideFooter];
}

#pragma mark - RemoteArtworkSearchDelegate

- (void)searchDidStart {
    self.footerStateGeneration++;  // Invalidate any pending auto-hide
    [self.artView showSearchProgress:@"Starting search..."];
}

- (void)searchDidUpdateProgress:(NSString *)message {
    [self.artView showSearchProgress:message];
}

- (void)searchDidFindResults:(NSArray<ArtworkResult *> *)results {
    self.searchResults = results;

    // Download thumbnails asynchronously
    [self downloadThumbnailsForResults:results];
}

- (void)searchDidFailWithError:(NSError *)error {
    NSString *message = error.localizedDescription ?: @"Search failed";
    [self.artView showError:message];
    [self scheduleErrorAutoHide];
}

- (void)searchDidComplete {
    // Search complete - thumbnails may still be loading
    if (self.searchResults.count == 0) {
        [self.artView showError:@"No artwork found"];
        [self scheduleErrorAutoHide];
    }
}

static const NSUInteger kMaxThumbnails = 10;
static const NSTimeInterval kThumbnailTimeout = 15.0;

#pragma mark - Thumbnail Loading

+ (NSURLSession *)thumbnailSession {
    static NSURLSession *session = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kThumbnailTimeout;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

- (nullable NSString *)thumbnailKeyForResult:(ArtworkResult *)result {
    NSString *key = result.thumbnailURL.absoluteString;
    return key.length > 0 ? key : result.fullResolutionURL.absoluteString;
}

- (void)downloadThumbnailsForResults:(NSArray<ArtworkResult *> *)results {
    NSUInteger count = MIN(results.count, kMaxThumbnails);
    if (count == 0) return;

    for (NSUInteger i = 0; i < count; i++) {
        ArtworkResult *result = results[i];
        NSString *key = [self thumbnailKeyForResult:result];
        if (!key || self.thumbnailCache[key]) {
            continue;  // No URL, already loaded, or download in flight completed
        }

        // thumbnailURL can be nil when the provider's URL parse failed while
        // fullResolutionURL survived; dataTaskWithURL:nil would throw.
        NSURL *thumbURL = result.thumbnailURL ?: result.fullResolutionURL;
        if (!thumbURL) {
            continue;
        }

        NSURLSessionDataTask *task = [[AlbumArtController thumbnailSession]
            dataTaskWithURL:thumbURL
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

            dispatch_async(dispatch_get_main_queue(), ^{
                // Ignore downloads that finished after the search state changed
                if (![self.searchResults containsObject:result]) return;

                NSImage *image = nil;
                if (data && !error) {
                    image = [[NSImage alloc] initWithData:data];
                }

                if (!image) {
                    // Create placeholder for failed downloads
                    image = [self placeholderThumbnailImage];
                }

                self.thumbnailCache[key] = image;
                [self updateThumbnailDisplay];
            });
        }];
        [task resume];
    }

    [self updateThumbnailDisplay];
}

- (void)updateThumbnailDisplay {
    // Show whichever of the current results already have thumbnails,
    // preserving the sorted order of searchResults
    NSMutableArray<NSImage *> *thumbnails = [NSMutableArray array];
    NSMutableArray<ArtworkResult *> *displayResults = [NSMutableArray array];

    NSUInteger count = MIN(self.searchResults.count, kMaxThumbnails);
    for (NSUInteger i = 0; i < count; i++) {
        ArtworkResult *result = self.searchResults[i];
        NSString *key = [self thumbnailKeyForResult:result];
        NSImage *thumb = key ? self.thumbnailCache[key] : nil;
        if (thumb) {
            [thumbnails addObject:thumb];
            [displayResults addObject:result];
        }
    }

    if (thumbnails.count > 0) {
        self.displayedResults = displayResults;
        [self.artView showThumbnails:thumbnails results:displayResults];
    }
}

- (NSImage *)placeholderThumbnailImage {
    NSImage *placeholder = nil;

    if (@available(macOS 11.0, *)) {
        placeholder = [NSImage imageWithSystemSymbolName:@"photo.fill" accessibilityDescription:@"Failed to load"];
        if (placeholder) return placeholder;
    }

    // Fallback: draw a simple placeholder
    NSSize size = NSMakeSize(48, 48);
    placeholder = [[NSImage alloc] initWithSize:size];
    [placeholder lockFocus];
    [[NSColor tertiaryLabelColor] setFill];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));
    // Draw an X
    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = 1.5;
    [path moveToPoint:NSMakePoint(16, 16)];
    [path lineToPoint:NSMakePoint(32, 32)];
    [path moveToPoint:NSMakePoint(32, 16)];
    [path lineToPoint:NSMakePoint(16, 32)];
    [[NSColor secondaryLabelColor] setStroke];
    [path stroke];
    [placeholder unlockFocus];

    return placeholder;
}

#pragma mark - Thumbnail Selection

- (void)albumArtView:(AlbumArtView*)view didSelectThumbnailAtIndex:(NSInteger)index {
    // The footer shows displayedResults (loaded thumbnails only), so the
    // clicked index must be resolved against that array, not searchResults
    if (index < 0 || index >= (NSInteger)self.displayedResults.count) {
        return;
    }

    ArtworkResult *clicked = self.displayedResults[index];
    NSUInteger resultIndex = [self.searchResults indexOfObject:clicked];
    if (resultIndex == NSNotFound) {
        return;
    }

    [self openLightboxAtIndex:(NSInteger)resultIndex];
}

- (void)openLightboxAtIndex:(NSInteger)index {
    if (self.searchResults.count == 0) {
        return;
    }

    // Create metadata snapshot
    TrackMetadata *metadata = nil;
    if (self.currentTrack.is_valid()) {
        metadata = [TrackMetadata metadataFromTrack:self.currentTrack];
    }

    // Create lightbox controller
    self.lightboxController = [[ArtworkLightboxController alloc] initWithResults:self.searchResults
                                                                         metadata:metadata
                                                                    initialIndex:index];
    self.lightboxController.delegate = self;

    // Present as sheet
    NSWindow *parentWindow = self.view.window;
    if (parentWindow) {
        [self.lightboxController presentAsSheetOnWindow:parentWindow];
    } else {
        [self.lightboxController presentAsModalWindow];
    }
}

#pragma mark - ArtworkLightboxDelegate

- (void)lightbox:(ArtworkLightboxController *)controller
    didSelectResult:(ArtworkResult *)result
          withImage:(NSImage *)image {

    // Clear lightbox reference
    self.lightboxController = nil;

    // Create metadata for save
    TrackMetadata *metadata = nil;
    if (self.currentTrack.is_valid()) {
        metadata = [TrackMetadata metadataFromTrack:self.currentTrack];
    }

    if (!metadata) {
        [self.artView showError:@"Cannot save: no track metadata"];
        return;
    }

    // Create save controller
    self.saveController = [[ArtworkSaveController alloc] initWithResult:result
                                                                  image:image
                                                               metadata:metadata];
    self.saveController.delegate = self;

    // Show save dialog
    [self.saveController saveWithOptions:ArtworkSaveOptionSaveToFolder
                            parentWindow:self.view.window];
}

- (void)lightbox:(ArtworkLightboxController *)controller
    didSelectResults:(NSDictionary<NSNumber *, ArtworkResult *> *)resultsByType
          withImages:(NSDictionary<NSNumber *, NSImage *> *)imagesByType {

    // Clear lightbox reference
    self.lightboxController = nil;

    // Create metadata for save
    TrackMetadata *metadata = nil;
    if (self.currentTrack.is_valid()) {
        metadata = [TrackMetadata metadataFromTrack:self.currentTrack];
    }

    if (!metadata) {
        [self.artView showError:@"Cannot save: no track metadata"];
        return;
    }

    // If only one image, use single-image flow
    if (resultsByType.count == 1) {
        NSNumber *typeKey = resultsByType.allKeys.firstObject;
        ArtworkResult *result = resultsByType[typeKey];
        NSImage *image = imagesByType[typeKey];

        self.saveController = [[ArtworkSaveController alloc] initWithResult:result
                                                                      image:image
                                                                   metadata:metadata];
        self.saveController.delegate = self;
        [self.saveController saveWithOptions:ArtworkSaveOptionSaveToFolder
                                parentWindow:self.view.window];
        return;
    }

    // Multiple images - save each one
    [self saveMultipleResults:resultsByType images:imagesByType metadata:metadata];
}

- (void)saveMultipleResults:(NSDictionary<NSNumber *, ArtworkResult *> *)resultsByType
                     images:(NSDictionary<NSNumber *, NSImage *> *)imagesByType
                   metadata:(TrackMetadata *)metadata {

    // Honor a remembered choice (folder and/or embed); otherwise confirm and
    // save to folder
    ArtworkSaveOptions options = ArtworkSaveOptionSaveToFolder;

    // 4B: Show confirmation dialog (unless "Remember my choice" was set)
    if ([ArtworkSaveController shouldShowConfirmation]) {
        NSMutableArray<NSString *> *fileNames = [NSMutableArray array];
        for (NSNumber *typeKey in resultsByType) {
            ArtworkResult *result = resultsByType[typeKey];
            NSString *filename = [NSString stringWithFormat:@"%@.jpg",
                                  RemoteArtworkTypeFilename(result.artworkType)];
            [fileNames addObject:filename];
        }

        NSAlert *confirm = [[NSAlert alloc] init];
        confirm.messageText = [NSString stringWithFormat:@"Save %lu images?",
                               (unsigned long)resultsByType.count];
        confirm.informativeText = [fileNames componentsJoinedByString:@", "];
        [confirm addButtonWithTitle:@"Save"];
        [confirm addButtonWithTitle:@"Cancel"];

        NSModalResponse response = [confirm runModal];
        if (response != NSAlertFirstButtonReturn) {
            return;
        }
    } else {
        ArtworkSaveOptions remembered = [ArtworkSaveController defaultSaveOptions];
        if (remembered & (ArtworkSaveOptionSaveToFolder | ArtworkSaveOptionEmbedInFile)) {
            options = remembered;
        }
    }

    NSMutableArray<NSString *> *savedFiles = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, ArtworkResult *> *failedResults = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSImage *> *failedImages = [NSMutableDictionary dictionary];
    NSUInteger embeddedCount = 0;
    NSUInteger embedFailedCount = 0;

    for (NSNumber *typeKey in resultsByType) {
        ArtworkResult *result = resultsByType[typeKey];
        NSImage *image = imagesByType[typeKey];

        if (!image) continue;

        if (options & ArtworkSaveOptionEmbedInFile) {
            NSError *embedError = nil;
            if ([ArtworkEmbedController embedImage:image
                                       artworkType:result.artworkType
                                          metadata:metadata
                                             error:&embedError] == ArtworkEmbedResultSuccess) {
                embeddedCount++;
            } else {
                embedFailedCount++;
                NSLog(@"[AlbumArt] Embed failed for %@: %@",
                      RemoteArtworkTypeName(result.artworkType),
                      embedError.localizedDescription);
            }
        }

        if (!(options & ArtworkSaveOptionSaveToFolder)) {
            continue;
        }

        ArtworkSaveController *saver = [[ArtworkSaveController alloc] initWithResult:result
                                                                               image:image
                                                                            metadata:metadata];

        NSURL *targetURL = [saver targetFileURL];
        if (!targetURL) {
            failedResults[typeKey] = result;
            failedImages[typeKey] = image;
            continue;
        }

        if ([saver canSaveToFolder] && [saver saveImageToFolder]) {
            [savedFiles addObject:[targetURL lastPathComponent]];
        } else {
            failedResults[typeKey] = result;
            failedImages[typeKey] = image;
        }
    }

    // Embed-only flow: report and finish without the folder-save fallbacks
    if (!(options & ArtworkSaveOptionSaveToFolder)) {
        if (embedFailedCount == 0 && embeddedCount > 0) {
            [self showSuccessAlert:[NSString stringWithFormat:@"Embedded %lu images in the current track.",
                                    (unsigned long)embeddedCount]];
        } else if (embeddedCount > 0) {
            [self showPartialSuccessAlert:[NSString stringWithFormat:@"Embedded %lu images, %lu failed.",
                                           (unsigned long)embeddedCount, (unsigned long)embedFailedCount]];
        } else {
            [self.artView showError:@"Failed to embed images"];
        }

        if (embeddedCount > 0 && self.currentTrack.is_valid()) {
            [self handleNewTrack:self.currentTrack];
        }
        [self.artView hideFooter];
        return;
    }

    // 4A: NSSavePanel fallback for failed saves
    if (failedResults.count > 0) {
        [self saveFailedResults:failedResults images:failedImages savedFiles:savedFiles];
    } else {
        [self showMultiSaveResult:savedFiles failedCount:0];
    }

    // 4C: Post-save artwork refresh
    if (savedFiles.count > 0 && self.currentTrack.is_valid()) {
        [self handleNewTrack:self.currentTrack];
    }

    [self.artView hideFooter];
}

- (void)saveFailedResults:(NSDictionary<NSNumber *, ArtworkResult *> *)failedResults
                   images:(NSDictionary<NSNumber *, NSImage *> *)failedImages
               savedFiles:(NSMutableArray<NSString *> *)savedFiles {

    // Use NSOpenPanel to let user pick a writable directory
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = [NSString stringWithFormat:@"Choose folder for %lu remaining images",
                   (unsigned long)failedResults.count];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;

    // Try to start in the album folder
    TrackMetadata *meta = nil;
    if (self.currentTrack.is_valid()) {
        meta = [TrackMetadata metadataFromTrack:self.currentTrack];
    }
    if (meta.folderURL) {
        panel.directoryURL = meta.folderURL;
    }

    NSModalResponse response = [panel runModal];
    if (response != NSModalResponseOK || !panel.URL) {
        [self showMultiSaveResult:savedFiles failedCount:failedResults.count];
        return;
    }

    NSURL *directory = panel.URL;
    NSUInteger additionalFailed = 0;

    for (NSNumber *typeKey in failedResults) {
        ArtworkResult *result = failedResults[typeKey];
        NSImage *image = failedImages[typeKey];

        if (!meta) continue;

        ArtworkSaveController *saver = [[ArtworkSaveController alloc] initWithResult:result
                                                                               image:image
                                                                            metadata:meta];

        NSString *filename = [NSString stringWithFormat:@"%@.jpg",
                              RemoteArtworkTypeFilename(result.artworkType)];
        NSURL *targetURL = [directory URLByAppendingPathComponent:filename];

        if ([saver saveImageToURL:targetURL]) {
            [savedFiles addObject:filename];
        } else {
            additionalFailed++;
        }
    }

    [self showMultiSaveResult:savedFiles failedCount:additionalFailed];
}

- (void)showMultiSaveResult:(NSArray<NSString *> *)savedFiles failedCount:(NSUInteger)failedCount {
    if (savedFiles.count > 0 && failedCount == 0) {
        NSString *message = [NSString stringWithFormat:@"Saved %lu images: %@",
                            (unsigned long)savedFiles.count,
                            [savedFiles componentsJoinedByString:@", "]];
        [self showSuccessAlert:message];
    } else if (savedFiles.count > 0 && failedCount > 0) {
        NSString *message = [NSString stringWithFormat:@"Saved %lu images, %lu failed.\nSaved: %@",
                            (unsigned long)savedFiles.count,
                            (unsigned long)failedCount,
                            [savedFiles componentsJoinedByString:@", "]];
        [self showPartialSuccessAlert:message];
    } else {
        [self.artView showError:@"Failed to save images"];
    }
}

- (void)showSuccessAlert:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Artwork Saved";
    alert.informativeText = message;
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)showPartialSuccessAlert:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Artwork Partially Saved";
    alert.informativeText = message;
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)lightboxDidCancel:(ArtworkLightboxController *)controller {
    // Lightbox dismissed without selection
    self.lightboxController = nil;
}

#pragma mark - ArtworkSaveDelegate

- (void)saveController:(ArtworkSaveController *)controller
      didCompleteWithResult:(ArtworkSaveResult)result
                    message:(nullable NSString *)message {

    // Hide footer
    [self.artView hideFooter];

    // Clear search state
    self.searchResults = nil;
    self.displayedResults = nil;
    [self.thumbnailCache removeAllObjects];

    switch (result) {
        case ArtworkSaveResultSuccess: {
            // Update display with saved artwork
            self.artView.image = controller.image;

            // Log success
            NSLog(@"[AlbumArt] Saved artwork to: %@", controller.targetFileURL.path);

            // Refresh to pick up the new artwork
            [self refreshArtwork];
            break;
        }

        case ArtworkSaveResultCancelled:
            // User cancelled, no action needed
            break;

        case ArtworkSaveResultFolderNotWritable:
        case ArtworkSaveResultFileExists:
        case ArtworkSaveResultWriteFailed:
        case ArtworkSaveResultEmbedNotSupported: {
            // Show error
            NSString *errorMsg = message ?: @"Failed to save artwork";
            [self.artView showError:errorMsg];
            [self scheduleErrorAutoHide];
            break;
        }
    }

    self.saveController = nil;
}

- (void)saveControllerDidCancel:(ArtworkSaveController *)controller {
    self.saveController = nil;
}

#pragma mark - Error Auto-Hide

- (void)scheduleErrorAutoHide {
    self.footerStateGeneration++;
    NSUInteger generation = self.footerStateGeneration;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kErrorAutoHideDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Only hide if no state change has occurred since we scheduled this
        if (self.footerStateGeneration == generation &&
            self.artView.footerState == AlbumArtFooterStateError) {
            [self.artView hideFooter];
        }
    });
}

@end
