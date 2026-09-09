//
//  ArtworkSaveController.mm
//  foo_jl_album_art_mac
//
//  Handles saving artwork to album folder
//

#import "ArtworkSaveController.h"
#import "ArtworkEmbedController.h"
#import "RemoteArtworkTypes.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kDefaultSaveOptionsKey = @"ArtworkDefaultSaveOptions";
static NSString *const kShowConfirmationKey = @"ArtworkShowSaveConfirmation";
static const CGFloat kJPEGSaveQuality = 0.9;

@interface ArtworkSaveController ()
@property (nonatomic, strong, readwrite) ArtworkResult *artworkResult;
@property (nonatomic, strong, readwrite) NSImage *image;
@property (nonatomic, strong, readwrite) TrackMetadata *metadata;
@end

@implementation ArtworkSaveController

- (instancetype)initWithResult:(ArtworkResult *)result
                         image:(NSImage *)image
                      metadata:(TrackMetadata *)metadata {
    self = [super init];
    if (self) {
        _artworkResult = result;
        _image = image;
        _metadata = metadata;
    }
    return self;
}

#pragma mark - Target Path

- (NSURL *)targetFileURL {
    if (!self.metadata.folderURL) {
        return nil;
    }

    NSString *filename = RemoteArtworkTypeFilename(self.artworkResult.artworkType);
    NSString *extension = @"jpg";  // Always save as JPEG for compatibility

    return [self.metadata.folderURL URLByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.%@", filename, extension]];
}

#pragma mark - Pre-flight Checks

/// UI hint only - the answer can be stale by the time the write happens, so
/// the save paths attempt the write and act on its error instead.
- (BOOL)canSaveToFolder {
    NSURL *folderURL = self.metadata.folderURL;
    if (!folderURL) {
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm isWritableFileAtPath:folderURL.path];
}

- (BOOL)fileExistsAtTarget {
    NSURL *targetURL = self.targetFileURL;
    if (!targetURL) {
        return NO;
    }

    return [[NSFileManager defaultManager] fileExistsAtPath:targetURL.path];
}

#pragma mark - Save Operations

- (void)saveWithOptions:(ArtworkSaveOptions)options
           parentWindow:(nullable NSWindow *)window {

    // If "remember choice" is set and we have defaults, use them directly
    if (![ArtworkSaveController shouldShowConfirmation]) {
        ArtworkSaveOptions defaults = [ArtworkSaveController defaultSaveOptions];
        if (defaults != ArtworkSaveOptionNone) {
            [self saveDirectlyWithOptions:defaults];
            return;
        }
    }

    // Show confirmation dialog
    [self showConfirmationDialogWithOptions:options parentWindow:window];
}

- (void)showConfirmationDialogWithOptions:(ArtworkSaveOptions)options
                             parentWindow:(nullable NSWindow *)window {

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Save Artwork";

    NSString *typeName = RemoteArtworkTypeName(self.artworkResult.artworkType);
    NSString *filename = [self.targetFileURL lastPathComponent];

    if ([self fileExistsAtTarget]) {
        alert.informativeText = [NSString stringWithFormat:
            @"Save %@ artwork as \"%@\"?\n\nA file with this name already exists and will be replaced.",
            typeName, filename];
    } else {
        alert.informativeText = [NSString stringWithFormat:
            @"Save %@ artwork as \"%@\"?",
            typeName, filename];
    }

    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    // Add accessory view with checkboxes
    NSView *accessoryView = [self createAccessoryView];
    alert.accessoryView = accessoryView;

    if (window) {
        [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn) {
                ArtworkSaveOptions finalOptions = [self optionsFromAccessoryView:accessoryView];
                [self saveDirectlyWithOptions:finalOptions parentWindow:window];
            } else {
                if ([self.delegate respondsToSelector:@selector(saveControllerDidCancel:)]) {
                    [self.delegate saveControllerDidCancel:self];
                }
            }
        }];
    } else {
        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn) {
            ArtworkSaveOptions finalOptions = [self optionsFromAccessoryView:accessoryView];
            [self saveDirectlyWithOptions:finalOptions parentWindow:nil];
        } else {
            if ([self.delegate respondsToSelector:@selector(saveControllerDidCancel:)]) {
                [self.delegate saveControllerDidCancel:self];
            }
        }
    }
}

- (NSView *)createAccessoryView {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 70)];

    // Save to folder checkbox (default on)
    NSButton *folderCheck = [NSButton checkboxWithTitle:@"Save to album folder"
                                                 target:nil
                                                 action:nil];
    folderCheck.frame = NSMakeRect(0, 45, 280, 20);
    folderCheck.state = NSControlStateValueOn;
    folderCheck.tag = 1;
    [view addSubview:folderCheck];

    // Embed in file checkbox
    BOOL canEmbed = [ArtworkEmbedController canEmbedArtworkForTrack:self.metadata];
    NSString *embedTitle = @"Embed in audio file";
    if (!canEmbed) {
        embedTitle = [ArtworkEmbedController formatSupportsEmbedding:self.metadata]
            ? @"Embed in audio file (file not writable)"
            : @"Embed in audio file (format not supported)";
    }
    NSButton *embedCheck = [NSButton checkboxWithTitle:embedTitle
                                                target:nil
                                                action:nil];
    embedCheck.frame = NSMakeRect(0, 25, 280, 20);
    embedCheck.state = NSControlStateValueOff;
    embedCheck.enabled = canEmbed;
    embedCheck.tag = 2;
    [view addSubview:embedCheck];

    // Remember choice checkbox
    NSButton *rememberCheck = [NSButton checkboxWithTitle:@"Remember my choice"
                                                   target:nil
                                                   action:nil];
    rememberCheck.frame = NSMakeRect(0, 0, 280, 20);
    rememberCheck.state = NSControlStateValueOff;
    rememberCheck.tag = 3;
    [view addSubview:rememberCheck];

    return view;
}

- (ArtworkSaveOptions)optionsFromAccessoryView:(NSView *)view {
    ArtworkSaveOptions options = ArtworkSaveOptionNone;

    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:[NSButton class]]) {
            NSButton *button = (NSButton *)subview;
            if (button.state == NSControlStateValueOn) {
                switch (button.tag) {
                    case 1:
                        options |= ArtworkSaveOptionSaveToFolder;
                        break;
                    case 2:
                        options |= ArtworkSaveOptionEmbedInFile;
                        break;
                    case 3:
                        options |= ArtworkSaveOptionRememberChoice;
                        break;
                }
            }
        }
    }

    return options;
}

- (void)saveDirectlyWithOptions:(ArtworkSaveOptions)options {
    [self saveDirectlyWithOptions:options parentWindow:nil];
}

- (void)saveDirectlyWithOptions:(ArtworkSaveOptions)options parentWindow:(nullable NSWindow *)window {
    // Handle "remember choice"
    if (options & ArtworkSaveOptionRememberChoice) {
        [ArtworkSaveController setDefaultSaveOptions:options & ~ArtworkSaveOptionRememberChoice];
    }

    // Check if we have anything to do
    if (!(options & (ArtworkSaveOptionSaveToFolder | ArtworkSaveOptionEmbedInFile))) {
        [self reportResult:ArtworkSaveResultCancelled message:@"No save option selected"];
        return;
    }

    BOOL folderSaveOK = YES;  // Assume success unless save-to-folder fails

    // Save to folder
    if (options & ArtworkSaveOptionSaveToFolder) {
        // No writability pre-check: it can go stale between check and write,
        // and a failed write already lands in the save-panel fallback below
        folderSaveOK = [self saveImageToFolder];

        if (!folderSaveOK) {
            // Direct save failed or not writable - use save panel
            NSLog(@"[AlbumArt] Direct save not possible, using save panel");
            [self saveImageWithPanelOnWindow:window embedAfter:(options & ArtworkSaveOptionEmbedInFile) != 0];
            return;
        }
    }

    // Embed in file
    if (options & ArtworkSaveOptionEmbedInFile) {
        [self performEmbed];
        return;
    }

    [self reportResult:ArtworkSaveResultSuccess message:nil];
}

- (void)performEmbed {
    NSError *embedError = nil;
    ArtworkEmbedResult embedResult = [ArtworkEmbedController embedImage:self.image
                                                            artworkType:self.artworkResult.artworkType
                                                               metadata:self.metadata
                                                                  error:&embedError];

    switch (embedResult) {
        case ArtworkEmbedResultSuccess:
            [self reportResult:ArtworkSaveResultSuccess message:nil];
            return;

        case ArtworkEmbedResultFormatNotSupported:
            [self reportResult:ArtworkSaveResultEmbedNotSupported
                       message:embedError.localizedDescription ?: @"Format does not support embedded artwork"];
            return;

        case ArtworkEmbedResultFileNotWritable:
            [self reportResult:ArtworkSaveResultFolderNotWritable
                       message:embedError.localizedDescription ?: @"File is not writable"];
            return;

        case ArtworkEmbedResultEncodeFailed:
        case ArtworkEmbedResultSDKError:
            [self reportResult:ArtworkSaveResultWriteFailed
                       message:embedError.localizedDescription ?: @"Failed to embed artwork"];
            return;
    }
}

- (void)saveImageWithPanelOnWindow:(nullable NSWindow *)window embedAfter:(BOOL)embedAfter {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Save Artwork";
    panel.nameFieldStringValue = [self.targetFileURL lastPathComponent] ?: @"cover.jpg";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"jpg"]];

    // Start in album folder if available
    if (self.metadata.folderURL) {
        panel.directoryURL = self.metadata.folderURL;
    }

    void (^completionHandler)(NSModalResponse) = ^(NSModalResponse response) {
        if (response == NSModalResponseOK && panel.URL) {
            BOOL success = [self saveImageToURL:panel.URL];
            if (success) {
                if (embedAfter) {
                    [self performEmbed];
                } else {
                    [self reportResult:ArtworkSaveResultSuccess message:nil];
                }
            } else {
                [self reportResult:ArtworkSaveResultWriteFailed
                           message:@"Failed to write image file"];
            }
        } else {
            [self reportResult:ArtworkSaveResultCancelled message:nil];
        }
    };

    if (window) {
        [panel beginSheetModalForWindow:window completionHandler:completionHandler];
    } else {
        NSModalResponse response = [panel runModal];
        completionHandler(response);
    }
}

- (BOOL)saveImageToFolder {
    NSURL *targetURL = self.targetFileURL;
    if (!targetURL) {
        return NO;
    }

    return [self saveImageToURL:targetURL];
}

- (BOOL)saveImageToURL:(NSURL *)targetURL {
    // Convert NSImage to JPEG data
    NSData *imageData = [self jpegDataFromImage:self.image quality:kJPEGSaveQuality];
    if (!imageData) {
        NSLog(@"[AlbumArt] Failed to convert image to JPEG");
        return NO;
    }

    // Write to file
    NSError *error = nil;
    BOOL success = [imageData writeToURL:targetURL
                                 options:NSDataWritingAtomic
                                   error:&error];

    // Filenames only: full paths end up in the unified system log
    if (!success) {
        NSLog(@"[AlbumArt] Failed to save artwork to %@: %@",
              targetURL.lastPathComponent, error.localizedDescription);
    } else {
        NSLog(@"[AlbumArt] Saved artwork to %@", targetURL.lastPathComponent);
    }

    return success;
}

- (NSData *)jpegDataFromImage:(NSImage *)image quality:(CGFloat)quality {
    NSBitmapImageRep *rep = nil;

    // Try to get existing bitmap rep
    for (NSImageRep *imageRep in image.representations) {
        if ([imageRep isKindOfClass:[NSBitmapImageRep class]]) {
            rep = (NSBitmapImageRep *)imageRep;
            break;
        }
    }

    // Create bitmap rep if needed
    if (!rep) {
        NSSize size = image.size;
        if (size.width <= 0 || size.height <= 0) return nil;

        rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                      pixelsWide:(NSInteger)size.width
                                                      pixelsHigh:(NSInteger)size.height
                                                   bitsPerSample:8
                                                 samplesPerPixel:4
                                                        hasAlpha:YES
                                                        isPlanar:NO
                                                  colorSpaceName:NSCalibratedRGBColorSpace
                                                     bytesPerRow:0
                                                    bitsPerPixel:0];

        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext setCurrentContext:context];
        [image drawInRect:NSMakeRect(0, 0, size.width, size.height)
                 fromRect:NSZeroRect
                operation:NSCompositingOperationCopy
                 fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];
    }

    // Convert to JPEG
    NSDictionary *props = @{NSImageCompressionFactor: @(quality)};
    return [rep representationUsingType:NSBitmapImageFileTypeJPEG properties:props];
}

- (void)reportResult:(ArtworkSaveResult)result message:(nullable NSString *)message {
    if ([self.delegate respondsToSelector:@selector(saveController:didCompleteWithResult:message:)]) {
        [self.delegate saveController:self didCompleteWithResult:result message:message];
    }
}

#pragma mark - Preferences

+ (ArtworkSaveOptions)defaultSaveOptions {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return (ArtworkSaveOptions)[defaults integerForKey:kDefaultSaveOptionsKey];
}

+ (void)setDefaultSaveOptions:(ArtworkSaveOptions)options {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:options forKey:kDefaultSaveOptionsKey];
    [defaults setBool:NO forKey:kShowConfirmationKey];  // Don't show dialog
}

+ (BOOL)shouldShowConfirmation {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Default to YES if not set
    if (![defaults objectForKey:kShowConfirmationKey]) {
        return YES;
    }

    return [defaults boolForKey:kShowConfirmationKey];
}

+ (void)resetToShowConfirmation {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:kShowConfirmationKey];
    [defaults removeObjectForKey:kDefaultSaveOptionsKey];
}

@end
