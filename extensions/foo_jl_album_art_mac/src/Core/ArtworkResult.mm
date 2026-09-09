//
//  ArtworkResult.mm
//  foo_jl_album_art_mac
//
//  ArtworkResult implementation
//

#import "ArtworkResult.h"
#import <CommonCrypto/CommonDigest.h>

NSString *const ArtworkFetchErrorDomain = @"com.foobar2000.albumart.fetch";

@implementation ArtworkResult

- (instancetype)initWithSourceIdentifier:(NSString *)sourceIdentifier
                              sourceName:(NSString *)sourceName
                            thumbnailURL:(NSURL *)thumbnailURL
                       fullResolutionURL:(NSURL *)fullResolutionURL
                              resolution:(CGSize)resolution
                             artworkType:(RemoteArtworkType)artworkType
                               imageHash:(nullable NSString *)imageHash
                                variants:(nullable NSArray<NSString *> *)variants {
    self = [super init];
    if (self) {
        _sourceIdentifier = [sourceIdentifier copy];
        _sourceName = [sourceName copy];
        _thumbnailURL = thumbnailURL;
        _fullResolutionURL = fullResolutionURL;
        _resolution = resolution;
        _artworkType = artworkType;
        _imageHash = [imageHash copy];
        _variants = [variants copy];
    }
    return self;
}

- (instancetype)initWithSourceIdentifier:(NSString *)sourceIdentifier
                              sourceName:(NSString *)sourceName
                            thumbnailURL:(NSURL *)thumbnailURL
                       fullResolutionURL:(NSURL *)fullResolutionURL
                              resolution:(CGSize)resolution
                             artworkType:(RemoteArtworkType)artworkType {
    return [self initWithSourceIdentifier:sourceIdentifier
                               sourceName:sourceName
                             thumbnailURL:thumbnailURL
                        fullResolutionURL:fullResolutionURL
                               resolution:resolution
                              artworkType:artworkType
                                imageHash:nil
                                 variants:nil];
}

- (ArtworkResult *)resultWithImageHash:(NSString *)hash {
    return [[ArtworkResult alloc] initWithSourceIdentifier:self.sourceIdentifier
                                                sourceName:self.sourceName
                                              thumbnailURL:self.thumbnailURL
                                         fullResolutionURL:self.fullResolutionURL
                                                resolution:self.resolution
                                               artworkType:self.artworkType
                                                 imageHash:hash
                                                  variants:self.variants];
}

- (NSString *)resolutionDescription {
    if (CGSizeEqualToSize(self.resolution, CGSizeZero)) {
        return @"Unknown";
    }
    return [NSString stringWithFormat:@"%.0fx%.0f",
            self.resolution.width, self.resolution.height];
}

- (NSString *)typeDescription {
    NSString *base = RemoteArtworkTypeDisplayName(self.artworkType);

    if (self.variants.count > 0) {
        NSString *variantStr = [self.variants componentsJoinedByString:@", "];
        return [NSString stringWithFormat:@"%@ (%@)", base, variantStr];
    }

    return base;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<ArtworkResult: %@ %@ from %@ [%@]>",
            RemoteArtworkTypeDisplayName(self.artworkType),
            self.resolutionDescription,
            self.sourceName,
            self.imageHash ?: @"no hash"];
}

- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:[ArtworkResult class]]) {
        return NO;
    }

    ArtworkResult *other = (ArtworkResult *)object;

    // If both have hashes, compare by hash (deduplication)
    if (self.imageHash && other.imageHash) {
        return [self.imageHash isEqualToString:other.imageHash];
    }

    // Otherwise compare by full resolution URL
    return [self.fullResolutionURL isEqual:other.fullResolutionURL];
}

- (NSUInteger)hash {
    if (self.imageHash) {
        return self.imageHash.hash;
    }
    return self.fullResolutionURL.hash;
}

@end

#pragma mark - Hash Utility

NSString *ArtworkImageHash(NSData *imageData) {
    if (!imageData || imageData.length == 0) {
        return nil;
    }

    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(imageData.bytes, (CC_LONG)imageData.length, hash);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", hash[i]];
    }

    return [hex copy];
}
