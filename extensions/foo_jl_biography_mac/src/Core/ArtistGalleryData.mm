//
//  ArtistGalleryData.mm
//  foo_jl_biography_mac
//
//  Container for artist gallery images - fetched separately from biography
//

#import "ArtistGalleryData.h"

#pragma mark - ArtistGalleryData

@implementation ArtistGalleryData

- (instancetype)initWithBuilder:(ArtistGalleryDataBuilder *)builder {
    self = [super init];
    if (self) {
        _artistName = [builder.artistName copy];
        _mbid = [builder.mbid copy];
        _images = [builder.images copy] ?: @[];
        _fetchedAt = builder.fetchedAt ?: [NSDate date];
        _isFromCache = builder.isFromCache;
        _isStale = builder.isStale;
    }
    return self;
}

#pragma mark - Properties

- (BOOL)isEmpty {
    return self.images.count == 0;
}

- (NSUInteger)imageCount {
    return self.images.count;
}

#pragma mark - Filtering

- (NSArray<ArtistImage *> *)imagesOfType:(ArtistImageType)type {
    NSMutableArray<ArtistImage *> *result = [NSMutableArray array];
    for (ArtistImage *image in self.images) {
        if (image.imageType == type) {
            [result addObject:image];
        }
    }
    return [result copy];
}

- (NSArray<ArtistImage *> *)imagesFromSource:(BiographySource)source {
    NSMutableArray<ArtistImage *> *result = [NSMutableArray array];
    for (ArtistImage *image in self.images) {
        if (image.source == source) {
            [result addObject:image];
        }
    }
    return [result copy];
}

#pragma mark - NSObject

- (NSString *)description {
    return [NSString stringWithFormat:@"<ArtistGalleryData: %@ (%lu images, mbid: %@)>",
            self.artistName,
            (unsigned long)self.images.count,
            self.mbid ?: @"nil"];
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.artistName forKey:@"artistName"];
    [coder encodeObject:self.mbid forKey:@"mbid"];
    [coder encodeObject:self.images forKey:@"images"];
    [coder encodeObject:self.fetchedAt forKey:@"fetchedAt"];
    [coder encodeBool:self.isFromCache forKey:@"isFromCache"];
    [coder encodeBool:self.isStale forKey:@"isStale"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    NSString *artistName = [coder decodeObjectOfClass:[NSString class] forKey:@"artistName"];
    if (!artistName) return nil;

    ArtistGalleryDataBuilder *builder = [[ArtistGalleryDataBuilder alloc] initWithArtistName:artistName];
    builder.mbid = [coder decodeObjectOfClass:[NSString class] forKey:@"mbid"];

    NSSet *allowedClasses = [NSSet setWithObjects:[NSArray class], [ArtistImage class], nil];
    builder.images = [coder decodeObjectOfClasses:allowedClasses forKey:@"images"];

    builder.fetchedAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"fetchedAt"];
    builder.isFromCache = [coder decodeBoolForKey:@"isFromCache"];
    builder.isStale = [coder decodeBoolForKey:@"isStale"];

    return [self initWithBuilder:builder];
}

@end

#pragma mark - ArtistGalleryDataBuilder

@implementation ArtistGalleryDataBuilder {
    NSMutableArray<ArtistImage *> *_mutableImages;
    NSMutableSet<NSURL *> *_seenURLs;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableImages = [NSMutableArray array];
        _seenURLs = [NSMutableSet set];
        _isFromCache = NO;
        _isStale = NO;
    }
    return self;
}

- (instancetype)initWithArtistName:(NSString *)artistName {
    self = [self init];
    if (self) {
        _artistName = [artistName copy];
    }
    return self;
}

- (NSArray<ArtistImage *> *)images {
    return [_mutableImages copy];
}

- (void)setImages:(NSArray<ArtistImage *> *)images {
    [_mutableImages removeAllObjects];
    [_seenURLs removeAllObjects];

    for (ArtistImage *image in images) {
        if (![_seenURLs containsObject:image.url]) {
            [_mutableImages addObject:image];
            [_seenURLs addObject:image.url];
        }
    }
}

- (void)addImages:(NSArray<ArtistImage *> *)images {
    for (ArtistImage *image in images) {
        // Deduplicate by URL
        if (![_seenURLs containsObject:image.url]) {
            [_mutableImages addObject:image];
            [_seenURLs addObject:image.url];
        }
    }
}

- (void)sortImagesByPreference {
    [_mutableImages sortUsingComparator:^NSComparisonResult(ArtistImage *a, ArtistImage *b) {
        // 1. Source priority: FanartTV > AudioDB
        NSInteger sourceA = (a.source == BiographySourceFanartTv) ? 0 : 1;
        NSInteger sourceB = (b.source == BiographySourceFanartTv) ? 0 : 1;
        if (sourceA != sourceB) {
            return sourceA < sourceB ? NSOrderedAscending : NSOrderedDescending;
        }

        // 2. Image type priority: Background > Thumbnail > Logo > Banner
        NSInteger typeA = [self typeOrder:a.imageType];
        NSInteger typeB = [self typeOrder:b.imageType];
        if (typeA != typeB) {
            return typeA < typeB ? NSOrderedAscending : NSOrderedDescending;
        }

        // 3. Likes (higher first)
        if (a.likes != b.likes) {
            return a.likes > b.likes ? NSOrderedAscending : NSOrderedDescending;
        }

        return NSOrderedSame;
    }];
}

- (NSInteger)typeOrder:(ArtistImageType)type {
    switch (type) {
        case ArtistImageTypeBackground: return 0;
        case ArtistImageTypeThumbnail: return 1;
        case ArtistImageTypeLogo: return 2;
        case ArtistImageTypeBanner: return 3;
        default: return 4;
    }
}

- (ArtistGalleryData *)build {
    NSAssert(self.artistName.length > 0, @"Artist name is required");
    return [[ArtistGalleryData alloc] initWithBuilder:self];
}

@end
