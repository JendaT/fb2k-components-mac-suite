//
//  GalleryFetchState.mm
//  foo_jl_biography_mac
//
//  Thread-safe accumulator for a multi-source gallery fetch
//

#import "GalleryFetchState.h"
#import "ArtistImage.h"
#import "ArtistGalleryData.h"
#import "../API/BiographyAPIConstants.h"

@implementation GalleryFetchState {
    NSLock *_lock;
    ArtistGalleryDataBuilder *_builder;
    NSMutableArray<NSError *> *_errors;
    NSUInteger _reportedCount;
    NSUInteger _erroredCount;
    NSUInteger _skippedCount;
    BOOL _completed;
}

- (instancetype)initWithArtistName:(NSString *)artistName mbid:(NSString *)mbid {
    self = [super init];
    if (self) {
        _lock = [[NSLock alloc] init];
        _builder = [[ArtistGalleryDataBuilder alloc] initWithArtistName:artistName];
        _builder.mbid = mbid;
        _errors = [NSMutableArray array];
    }
    return self;
}

- (void)recordImages:(NSArray<ArtistImage *> *)images
               error:(NSError *)error
          fromSource:(BiographySource)source {
    [_lock lock];
    if (!_completed) {
        _reportedCount++;
        if (error) {
            _erroredCount++;
            [_errors addObject:error];
        }
        if (images.count > 0) {
            [_builder addImages:images];
        }
    }
    [_lock unlock];
}

- (void)recordSkippedSource:(BiographySource)source {
    [_lock lock];
    if (!_completed) {
        _skippedCount++;
    }
    [_lock unlock];
}

- (BOOL)tryComplete {
    [_lock lock];
    BOOL won = !_completed;
    _completed = YES;
    [_lock unlock];
    return won;
}

- (BOOL)isCompleted {
    [_lock lock];
    BOOL completed = _completed;
    [_lock unlock];
    return completed;
}

- (BOOL)allSourcesFailed {
    [_lock lock];
    BOOL failed = _reportedCount > 0
        && _erroredCount == _reportedCount
        && _builder.images.count == 0;
    [_lock unlock];
    return failed;
}

- (NSError *)firstError {
    [_lock lock];
    NSError *error = _errors.firstObject;
    [_lock unlock];
    return error;
}

- (NSUInteger)imageCount {
    [_lock lock];
    NSUInteger count = _builder.images.count;
    [_lock unlock];
    return count;
}

- (ArtistGalleryData *)buildGalleryDataWithFallbackURL:(NSURL *)fallbackURL {
    [_lock lock];

    [_builder sortImagesByPreference];

    // If no images from APIs but we have a fallback URL, use it.
    // Skip Last.fm default placeholder (star icon) - hash 2a96cbd8b46e442fc41c2b86b821562f
    BOOL isDefaultPlaceholder = [fallbackURL.absoluteString containsString:kLastFmPlaceholderHash];
    if (_builder.images.count == 0 && fallbackURL && !isDefaultPlaceholder) {
        ArtistImage *fallbackImage = [[ArtistImage alloc] initWithURL:fallbackURL
                                                         thumbnailURL:nil
                                                            imageType:ArtistImageTypeThumbnail
                                                               source:BiographySourceLastFm
                                                                likes:0
                                                         originalSize:CGSizeZero];
        [_builder addImages:@[fallbackImage]];
    }

    ArtistGalleryData *data = [_builder build];
    [_lock unlock];
    return data;
}

@end
