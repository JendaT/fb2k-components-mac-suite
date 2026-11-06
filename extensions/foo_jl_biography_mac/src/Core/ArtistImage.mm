//
//  ArtistImage.mm
//  foo_jl_biography_mac
//
//  Immutable data model for artist images from FanartTV and AudioDB
//

#import "ArtistImage.h"

@implementation ArtistImage

#pragma mark - Initializers

- (instancetype)initWithURL:(NSURL *)url
               thumbnailURL:(nullable NSURL *)thumbnailURL
                  imageType:(ArtistImageType)imageType
                     source:(BiographySource)source
                      likes:(NSInteger)likes
               originalSize:(CGSize)originalSize {
    self = [super init];
    if (self) {
        _url = [url copy];
        _thumbnailURL = [thumbnailURL copy];
        _imageType = imageType;
        _source = source;
        _likes = likes;
        _originalSize = originalSize;
    }
    return self;
}

- (instancetype)initWithURL:(NSURL *)url
               thumbnailURL:(nullable NSURL *)thumbnailURL
                  imageType:(ArtistImageType)imageType
                     source:(BiographySource)source
                      likes:(NSInteger)likes {
    return [self initWithURL:url
                thumbnailURL:thumbnailURL
                   imageType:imageType
                      source:source
                       likes:likes
                originalSize:CGSizeZero];
}

#pragma mark - Convenience Methods

- (NSURL *)bestThumbnailURL {
    return self.thumbnailURL ?: self.url;
}

- (NSString *)imageTypeDisplayName {
    switch (self.imageType) {
        case ArtistImageTypeBackground:
            return @"Background";
        case ArtistImageTypeThumbnail:
            return @"Thumbnail";
        case ArtistImageTypeLogo:
            return @"Logo";
        case ArtistImageTypeBanner:
            return @"Banner";
        default:
            return @"Unknown";
    }
}

#pragma mark - NSObject

- (NSString *)description {
    return [NSString stringWithFormat:@"<ArtistImage: %@ (%@, likes: %ld)>",
            self.url.lastPathComponent,
            [self imageTypeDisplayName],
            (long)self.likes];
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[ArtistImage class]]) return NO;

    ArtistImage *other = (ArtistImage *)object;
    return [self.url isEqual:other.url];
}

- (NSUInteger)hash {
    return self.url.hash;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.url forKey:@"url"];
    [coder encodeObject:self.thumbnailURL forKey:@"thumbnailURL"];
    [coder encodeInteger:self.imageType forKey:@"imageType"];
    [coder encodeInteger:self.source forKey:@"source"];
    [coder encodeInteger:self.likes forKey:@"likes"];
    [coder encodeDouble:self.originalSize.width forKey:@"originalWidth"];
    [coder encodeDouble:self.originalSize.height forKey:@"originalHeight"];
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder {
    NSURL *url = [coder decodeObjectOfClass:[NSURL class] forKey:@"url"];
    if (!url) return nil;

    NSURL *thumbnailURL = [coder decodeObjectOfClass:[NSURL class] forKey:@"thumbnailURL"];
    ArtistImageType imageType = (ArtistImageType)[coder decodeIntegerForKey:@"imageType"];
    BiographySource source = (BiographySource)[coder decodeIntegerForKey:@"source"];
    NSInteger likes = [coder decodeIntegerForKey:@"likes"];
    CGFloat width = [coder decodeDoubleForKey:@"originalWidth"];
    CGFloat height = [coder decodeDoubleForKey:@"originalHeight"];

    return [self initWithURL:url
                thumbnailURL:thumbnailURL
                   imageType:imageType
                      source:source
                       likes:likes
                originalSize:CGSizeMake(width, height)];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    // Immutable, return self
    return self;
}

@end
