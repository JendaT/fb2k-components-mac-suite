//
//  GalleryFetchState.h
//  foo_jl_biography_mac
//
//  Thread-safe accumulator for a multi-source gallery fetch.
//  Collects per-source results, deduplicates via ArtistGalleryDataBuilder,
//  guards against double-completion (timeout racing all-sources-done), and
//  decides whether the Last.fm fallback image should be appended.
//  Contains NO foobar2000 SDK dependency, NO AppKit, and NO dispatch calls -
//  callers own the threading policy. Extracted from ArtistGalleryCoordinator.
//

#pragma once

#import <Foundation/Foundation.h>
#import "BiographySource.h"

@class ArtistImage, ArtistGalleryData;

NS_ASSUME_NONNULL_BEGIN

@interface GalleryFetchState : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithArtistName:(NSString *)artistName
                              mbid:(nullable NSString *)mbid NS_DESIGNATED_INITIALIZER;

/// Record one source's result. Thread-safe. Ignored after completion.
- (void)recordImages:(nullable NSArray<ArtistImage *> *)images
               error:(nullable NSError *)error
          fromSource:(BiographySource)source;

/// Record that a source was skipped (e.g. Fanart.tv without an MBID).
/// A skipped source never counts as failed.
- (void)recordSkippedSource:(BiographySource)source;

/// Atomically transition to completed. Returns YES for exactly one caller;
/// the loser of the timeout-vs-group-notify race gets NO and must not finish.
- (BOOL)tryComplete;

@property (readonly) BOOL isCompleted;

/// YES when at least one source reported, every reporting source returned an
/// error, and no images were collected. Skipped sources don't count as failed.
@property (readonly) BOOL allSourcesFailed;

/// The first error recorded, if any.
@property (readonly, nullable) NSError *firstError;

/// Number of images collected so far (after dedup).
@property (readonly) NSUInteger imageCount;

/// Build the final gallery data: sorted by preference; when no API images
/// arrived, appends the fallback image unless it is the Last.fm default
/// placeholder (star icon) or nil.
- (ArtistGalleryData *)buildGalleryDataWithFallbackURL:(nullable NSURL *)fallbackURL;

@end

NS_ASSUME_NONNULL_END
