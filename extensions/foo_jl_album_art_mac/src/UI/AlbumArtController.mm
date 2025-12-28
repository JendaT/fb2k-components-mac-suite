//
//  AlbumArtController.mm
//  foo_jl_album_art_mac
//
//  Main controller implementation
//

#import "AlbumArtController.h"
#import "../Core/AlbumArtFetcher.h"
#import "../Core/AlbumArtConfig.h"

using namespace albumart_config;

@interface AlbumArtController ()
@property (nonatomic, strong) AlbumArtView *artView;
@property (nonatomic, copy) NSString *instanceGUID;
@property (nonatomic, assign) ArtworkType currentType;
@property (nonatomic, assign) ArtworkType defaultType;  // From layout params
@property (nonatomic, assign) BOOL isSquare;
@property (nonatomic, assign) BOOL isZoomable;
@property (nonatomic, strong) NSArray<NSNumber*> *availableTypes;
@property (nonatomic, assign) metadb_handle_ptr currentTrack;
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
    self.currentTrack = track;

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
    self.availableTypes = @[];
    self.artView.image = nil;
    self.artView.canNavigatePrevious = NO;
    self.artView.canNavigateNext = NO;
    [self.artView refreshDisplay];
}

#pragma mark - Navigation

- (void)updateNavigationArrows {
    if (self.availableTypes.count <= 1) {
        self.artView.canNavigatePrevious = NO;
        self.artView.canNavigateNext = NO;
        return;
    }

    // Find current type in available types
    NSInteger currentIndex = -1;
    for (NSUInteger i = 0; i < self.availableTypes.count; i++) {
        if (self.availableTypes[i].integerValue == static_cast<NSInteger>(self.currentType)) {
            currentIndex = i;
            break;
        }
    }

    if (currentIndex < 0) {
        // Current type not available, can navigate to any
        self.artView.canNavigatePrevious = YES;
        self.artView.canNavigateNext = YES;
    } else {
        // Check if there are types before/after
        self.artView.canNavigatePrevious = currentIndex > 0 || self.availableTypes.count > 1;
        self.artView.canNavigateNext = currentIndex < (NSInteger)self.availableTypes.count - 1 || self.availableTypes.count > 1;
    }
}

- (void)navigateToPreviousType {
    if (self.availableTypes.count == 0) return;

    // Find current type index
    NSInteger currentIndex = -1;
    for (NSUInteger i = 0; i < self.availableTypes.count; i++) {
        if (self.availableTypes[i].integerValue == static_cast<NSInteger>(self.currentType)) {
            currentIndex = i;
            break;
        }
    }

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

    // Find current type index
    NSInteger currentIndex = -1;
    for (NSUInteger i = 0; i < self.availableTypes.count; i++) {
        if (self.availableTypes[i].integerValue == static_cast<NSInteger>(self.currentType)) {
            currentIndex = i;
            break;
        }
    }

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

@end
