//
//  BiographyData.h
//  foo_jl_biography_mac
//
//  Immutable data models for artist biography information
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Enums

typedef NS_ENUM(NSInteger, BiographySource) {
    BiographySourceUnknown = 0,
    BiographySourceLastFm,
    BiographySourceWikipedia,
    BiographySourceAudioDb,
    BiographySourceFanartTv,
    BiographySourceCache
};

typedef NS_ENUM(NSInteger, BiographyImageType) {
    BiographyImageTypeThumb = 0,
    BiographyImageTypeBackground,
    BiographyImageTypeLogo,
    BiographyImageTypeBanner
};

#pragma mark - Forward declarations

@class BiographyDataBuilder;

#pragma mark - SimilarArtistRef

/// Lightweight reference for similar artists - avoids recursive BiographyData
@interface SimilarArtistRef : NSObject

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSURL *thumbnailURL;
@property (nonatomic, copy, readonly, nullable) NSString *musicBrainzId;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithName:(NSString *)name
                thumbnailURL:(nullable NSURL *)thumbnailURL
               musicBrainzId:(nullable NSString *)mbid NS_DESIGNATED_INITIALIZER;

@end

#pragma mark - BiographyData

/// Immutable data model - construct via builder, thread-safe after creation
@interface BiographyData : NSObject

// Artist identification
@property (nonatomic, copy, readonly) NSString *artistName;
@property (nonatomic, copy, readonly, nullable) NSString *musicBrainzId;

// Biography content
@property (nonatomic, copy, readonly, nullable) NSString *biography;
@property (nonatomic, copy, readonly, nullable) NSString *biographySummary;
@property (nonatomic, assign, readonly) BiographySource biographySource;
@property (nonatomic, copy, readonly, nullable) NSString *language;

// Images
@property (nonatomic, strong, readonly, nullable) NSImage *artistImage;
@property (nonatomic, copy, readonly, nullable) NSURL *artistImageURL;
@property (nonatomic, assign, readonly) BiographySource imageSource;
@property (nonatomic, assign, readonly) BiographyImageType imageType;

// Metadata
@property (nonatomic, copy, readonly, nullable) NSArray<NSString *> *tags;
@property (nonatomic, copy, readonly, nullable) NSArray<SimilarArtistRef *> *similarArtists;
@property (nonatomic, copy, readonly, nullable) NSString *genre;
@property (nonatomic, copy, readonly, nullable) NSString *country;

// Statistics (from Last.fm)
@property (nonatomic, assign, readonly) NSUInteger listeners;
@property (nonatomic, assign, readonly) NSUInteger playcount;

// Cache metadata
@property (nonatomic, strong, readonly) NSDate *fetchedAt;
@property (nonatomic, assign, readonly) BOOL isFromCache;
@property (nonatomic, assign, readonly) BOOL isStale;  // TTL expired but still usable

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithBuilder:(BiographyDataBuilder *)builder NS_DESIGNATED_INITIALIZER;

/// Check if biography content is available
@property (nonatomic, assign, readonly) BOOL hasBiography;

/// Check if artist image is available
@property (nonatomic, assign, readonly) BOOL hasImage;

/// Source display name for UI
- (NSString *)biographySourceDisplayName;
- (NSString *)imageSourceDisplayName;

@end

#pragma mark - BiographyDataBuilder

/// Builder for constructing BiographyData
@interface BiographyDataBuilder : NSObject

@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy, nullable) NSString *musicBrainzId;
@property (nonatomic, copy, nullable) NSString *biography;
@property (nonatomic, copy, nullable) NSString *biographySummary;
@property (nonatomic, assign) BiographySource biographySource;
@property (nonatomic, copy, nullable) NSString *language;
@property (nonatomic, strong, nullable) NSImage *artistImage;
@property (nonatomic, copy, nullable) NSURL *artistImageURL;
@property (nonatomic, assign) BiographySource imageSource;
@property (nonatomic, assign) BiographyImageType imageType;
@property (nonatomic, copy, nullable) NSArray<NSString *> *tags;
@property (nonatomic, copy, nullable) NSArray<SimilarArtistRef *> *similarArtists;
@property (nonatomic, copy, nullable) NSString *genre;
@property (nonatomic, copy, nullable) NSString *country;
@property (nonatomic, assign) NSUInteger listeners;
@property (nonatomic, assign) NSUInteger playcount;
@property (nonatomic, strong, nullable) NSDate *fetchedAt;
@property (nonatomic, assign) BOOL isFromCache;
@property (nonatomic, assign) BOOL isStale;

- (instancetype)initWithArtistName:(NSString *)artistName;
- (BiographyData *)build;

@end

NS_ASSUME_NONNULL_END
