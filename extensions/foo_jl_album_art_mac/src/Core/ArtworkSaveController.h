//
//  ArtworkSaveController.h
//  foo_jl_album_art_mac
//
//  Handles saving artwork to album folder
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "ArtworkResult.h"
#import "TrackMetadata.h"

NS_ASSUME_NONNULL_BEGIN

/// Save options for artwork
typedef NS_OPTIONS(NSUInteger, ArtworkSaveOptions) {
    ArtworkSaveOptionNone           = 0,
    ArtworkSaveOptionSaveToFolder   = 1 << 0,   // Save as front.jpg, back.jpg, etc.
    ArtworkSaveOptionEmbedInFile    = 1 << 1,   // Embed in audio file (Phase 3)
    ArtworkSaveOptionRememberChoice = 1 << 2,   // Don't ask again
};

/// Result of save operation
typedef NS_ENUM(NSInteger, ArtworkSaveResult) {
    ArtworkSaveResultSuccess = 0,
    ArtworkSaveResultCancelled,
    ArtworkSaveResultFolderNotWritable,
    ArtworkSaveResultFileExists,
    ArtworkSaveResultWriteFailed,
    ArtworkSaveResultEmbedNotSupported,  // Phase 3
};

@class ArtworkSaveController;

@protocol ArtworkSaveDelegate <NSObject>
@optional
/// Called when save completes
- (void)saveController:(ArtworkSaveController *)controller
      didCompleteWithResult:(ArtworkSaveResult)result
                    message:(nullable NSString *)message;

/// Called if user cancels
- (void)saveControllerDidCancel:(ArtworkSaveController *)controller;
@end

@interface ArtworkSaveController : NSObject

/// Delegate for save events
@property (nonatomic, weak, nullable) id<ArtworkSaveDelegate> delegate;

/// The artwork result being saved
@property (nonatomic, strong, readonly) ArtworkResult *artworkResult;

/// The image data to save
@property (nonatomic, strong, readonly) NSImage *image;

/// Track metadata (for folder location)
@property (nonatomic, strong, readonly) TrackMetadata *metadata;

/// Initialize with artwork to save
- (instancetype)initWithResult:(ArtworkResult *)result
                         image:(NSImage *)image
                      metadata:(TrackMetadata *)metadata;

/// Check if folder is writable
- (BOOL)canSaveToFolder;

/// Check if target file already exists
- (BOOL)fileExistsAtTarget;

/// Get the target file path
@property (nonatomic, readonly) NSURL *targetFileURL;

/// Save artwork with specified options
/// Shows confirmation dialog if needed
- (void)saveWithOptions:(ArtworkSaveOptions)options
           parentWindow:(nullable NSWindow *)window;

/// Save directly without dialog (for "remember choice")
- (void)saveDirectlyWithOptions:(ArtworkSaveOptions)options;

/// Save image directly to folder (returns success/failure)
- (BOOL)saveImageToFolder;

/// Save image to a specific URL (returns success/failure)
- (BOOL)saveImageToURL:(NSURL *)targetURL;

#pragma mark - Preferences

/// Get saved preference for default save option
+ (ArtworkSaveOptions)defaultSaveOptions;

/// Set default save options (for "remember choice")
+ (void)setDefaultSaveOptions:(ArtworkSaveOptions)options;

/// Whether to show confirmation dialog
+ (BOOL)shouldShowConfirmation;

/// Reset to always show confirmation
+ (void)resetToShowConfirmation;

@end

NS_ASSUME_NONNULL_END
