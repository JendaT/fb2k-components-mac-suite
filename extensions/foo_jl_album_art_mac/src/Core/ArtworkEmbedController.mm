//
//  ArtworkEmbedController.mm
//  foo_jl_album_art_mac
//
//  Embeds artwork into audio file tags using the foobar2000 SDK
//

#import "ArtworkEmbedController.h"
#import "AlbumArtConfig.h"
#import "RemoteArtworkTypes.h"

#include <foobar2000/SDK/album_art.h>
#include <foobar2000/SDK/album_art_helpers.h>

static const CGFloat kEmbedJPEGQuality = 0.92;

/// Convert RemoteArtworkType to local SDK type for save operations
static inline albumart_config::ArtworkType RemoteToLocalArtworkType(RemoteArtworkType remote) {
    switch (remote) {
        case RemoteArtworkTypeFront:   return albumart_config::ArtworkType::Front;
        case RemoteArtworkTypeBack:    return albumart_config::ArtworkType::Back;
        case RemoteArtworkTypeDisc:    return albumart_config::ArtworkType::Disc;
        case RemoteArtworkTypeIcon:    return albumart_config::ArtworkType::Icon;
        case RemoteArtworkTypeArtist:  return albumart_config::ArtworkType::Artist;
        case RemoteArtworkTypeBooklet: return albumart_config::ArtworkType::Front;  // Fallback
        case RemoteArtworkTypeOther:   return albumart_config::ArtworkType::Front;  // Fallback
    }
}

@implementation ArtworkEmbedController

+ (BOOL)formatSupportsEmbedding:(TrackMetadata *)metadata {
    if (!metadata.fileURL) return NO;

    // Check file extension - some formats don't support embedded art
    NSString *extension = [metadata.fileURL.pathExtension lowercaseString];

    // Formats that do NOT support embedded artwork
    static NSSet<NSString *> *unsupportedFormats = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsupportedFormats = [NSSet setWithArray:@[@"wav", @"aiff", @"aif", @"pcm", @"raw"]];
    });

    return ![unsupportedFormats containsObject:extension];
}

/// UI hint only - the writability half can go stale before the write, so
/// -embedImage: does not gate on it and reports the SDK's own I/O error.
+ (BOOL)canEmbedArtworkForTrack:(TrackMetadata *)metadata {
    if (![self formatSupportsEmbedding:metadata]) {
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    return [fm isWritableFileAtPath:metadata.fileURL.path];
}

+ (ArtworkEmbedResult)embedImage:(NSImage *)image
                     artworkType:(RemoteArtworkType)artworkType
                        metadata:(TrackMetadata *)metadata
                           error:(NSError * _Nullable *)error {

    if (!metadata.fileURL) {
        if (error) {
            *error = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                         code:ArtworkFetchErrorEmbedFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"No file URL available"}];
        }
        return ArtworkEmbedResultFileNotWritable;
    }

    // Only the format is checked up front; an unwritable file surfaces as
    // exception_io below, which maps to ArtworkEmbedResultFileNotWritable
    if (![self formatSupportsEmbedding:metadata]) {
        NSString *ext = [metadata.fileURL.pathExtension uppercaseString];
        if (error) {
            *error = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                         code:ArtworkFetchErrorEmbedFailed
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"%@ files do not support embedded artwork", ext]}];
        }
        return ArtworkEmbedResultFormatNotSupported;
    }

    // Convert image to JPEG data
    NSData *jpegData = [self jpegDataFromImage:image quality:kEmbedJPEGQuality];
    if (!jpegData) {
        if (error) {
            *error = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                         code:ArtworkFetchErrorEmbedFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to encode image as JPEG"}];
        }
        return ArtworkEmbedResultEncodeFailed;
    }

    // Convert RemoteArtworkType to SDK GUID
    albumart_config::ArtworkType localType = RemoteToLocalArtworkType(artworkType);
    GUID artGUID = albumart_config::artworkTypeToGUID(localType);

    // Use SDK to embed artwork
    const char *filePath = [metadata.fileURL.path UTF8String];

    try {
        // Create album art data from JPEG bytes
        album_art_data_ptr artData = album_art_data_impl::g_create(jpegData.bytes, jpegData.length);

        // Open album art editor for the file
        abort_callback_dummy abort;
        auto editor = album_art_editor::g_open(nullptr, filePath, abort);

        // Set the artwork
        editor->set(artGUID, artData, abort);

        // Commit changes
        editor->commit(abort);

        NSLog(@"[AlbumArt] Embedded %@ artwork in %@",
              RemoteArtworkTypeDisplayName(artworkType),
              metadata.fileURL.lastPathComponent);

        return ArtworkEmbedResultSuccess;

    } catch (const exception_album_art_not_found &) {
        // Editor doesn't support this art type
        if (error) {
            *error = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                         code:ArtworkFetchErrorEmbedFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"File format does not support this artwork type"}];
        }
        return ArtworkEmbedResultFormatNotSupported;

    } catch (const exception_io &e) {
        if (error) {
            // e.what() may contain non-UTF-8 filesystem bytes; stringWithUTF8String:
            // returns nil for those, which would crash the dictionary literal.
            NSString *msg = [NSString stringWithUTF8String:e.what()] ?: @"I/O error";
            *error = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                         code:ArtworkFetchErrorEmbedFailed
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return ArtworkEmbedResultFileNotWritable;

    } catch (const std::exception &e) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:e.what()] ?: @"Unknown error";
            *error = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                         code:ArtworkFetchErrorEmbedFailed
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return ArtworkEmbedResultSDKError;

    } catch (...) {
        if (error) {
            *error = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                         code:ArtworkFetchErrorEmbedFailed
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unknown error during embedding"}];
        }
        return ArtworkEmbedResultSDKError;
    }
}

#pragma mark - Image Conversion

+ (NSData *)jpegDataFromImage:(NSImage *)image quality:(CGFloat)quality {
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

    NSDictionary *props = @{NSImageCompressionFactor: @(quality)};
    return [rep representationUsingType:NSBitmapImageFileTypeJPEG properties:props];
}

@end
