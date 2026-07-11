//
//  ArtistImageCache.mm
//  foo_jl_biography_mac
//
//  Dual-layer cache (memory + disk) for artist images
//

#import "ArtistImageCache.h"
#import "ArtistGalleryData.h"
#import "BiographyAPIConstants.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>

// Cache constants
static const NSUInteger kMemoryCacheLimit = 50;
static const NSUInteger kThumbnailMaxSize = 200;   // 200x200 max for thumbnails
static const NSUInteger kFullMaxSize = 2048;       // 2048x2048 max for full
static const NSTimeInterval kGalleryDataTTL = 24 * 60 * 60;  // 24 hours
static const NSInteger kMaxConcurrentDownloads = 4;

// Logging macro
#define GALLERY_LOG(fmt, ...) NSLog(@"[Gallery/Cache] " fmt, ##__VA_ARGS__)

#pragma mark - Cache Key Helper

static NSString *CacheKeyForURL(NSURL *url, ArtistImageCacheSize size) {
    // SHA256 hash of URL + size suffix
    NSString *urlString = url.absoluteString;
    NSData *data = [urlString dataUsingEncoding:NSUTF8StringEncoding];

    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);

    NSMutableString *hashString = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hashString appendFormat:@"%02x", hash[i]];
    }

    NSString *suffix = (size == ArtistImageCacheSizeThumbnail) ? @"_thumb" : @"_full";
    return [hashString stringByAppendingString:suffix];
}

static NSString *CacheKeyForArtist(NSString *artistName) {
    // Normalize artist name for cache key
    NSString *normalized = [[artistName lowercaseString]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSData *data = [normalized dataUsingEncoding:NSUTF8StringEncoding];

    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);

    NSMutableString *hashString = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hashString appendFormat:@"%02x", hash[i]];
    }

    return [hashString stringByAppendingString:@"_gallery"];
}

@interface ArtistImageCache ()

// Memory cache
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *memoryCache;

// Disk cache
@property (nonatomic, copy) NSURL *diskCacheURL;
@property (nonatomic, copy) NSURL *galleryDataCacheURL;

// Download queue
@property (nonatomic, strong) NSOperationQueue *downloadQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<void (^)(NSImage *)> *> *pendingCompletions;
@property (nonatomic, strong) NSLock *pendingLock;

// URL Session
@property (nonatomic, strong) NSURLSession *session;

@end

@implementation ArtistImageCache

#pragma mark - Singleton

+ (instancetype)shared {
    static ArtistImageCache *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ArtistImageCache alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Memory cache (PERF-9: set cost limit to 100 MB)
        _memoryCache = [[NSCache alloc] init];
        _memoryCache.countLimit = kMemoryCacheLimit;
        _memoryCache.totalCostLimit = 100 * 1024 * 1024;

        // Disk cache directories
        NSArray<NSURL *> *cacheDirs = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                                             inDomains:NSUserDomainMask];
        NSURL *cacheDir = [cacheDirs.firstObject URLByAppendingPathComponent:@"foo_jl_biography"];
        _diskCacheURL = [cacheDir URLByAppendingPathComponent:@"images"];
        _galleryDataCacheURL = [cacheDir URLByAppendingPathComponent:@"gallery"];

        // Create directories if needed
        [[NSFileManager defaultManager] createDirectoryAtURL:_diskCacheURL
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
        [[NSFileManager defaultManager] createDirectoryAtURL:_galleryDataCacheURL
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];

        // Download queue with concurrency limit
        _downloadQueue = [[NSOperationQueue alloc] init];
        _downloadQueue.maxConcurrentOperationCount = kMaxConcurrentDownloads;
        _downloadQueue.name = @"com.foobar2000.biography.imagecache";

        // Pending downloads tracking
        _pendingCompletions = [NSMutableDictionary dictionary];
        _pendingLock = [[NSLock alloc] init];

        // URL Session
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kImageDownloadTimeout;
        config.HTTPAdditionalHeaders = @{@"User-Agent": kBiographyUserAgent};
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

#pragma mark - Image Cache - Synchronous

- (nullable NSImage *)cachedImageForURL:(NSURL *)url size:(ArtistImageCacheSize)size {
    NSString *key = CacheKeyForURL(url, size);

    // Check memory cache
    NSImage *memoryImage = [self.memoryCache objectForKey:key];
    if (memoryImage) {
        GALLERY_LOG(@"Memory hit: %@", url.lastPathComponent);
        return memoryImage;
    }

    // Check disk cache
    NSURL *fileURL = [self.diskCacheURL URLByAppendingPathComponent:key];
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (data) {
        NSImage *diskImage = [[NSImage alloc] initWithData:data];
        if (diskImage) {
            // Promote to memory cache
            [self.memoryCache setObject:diskImage forKey:key];
            GALLERY_LOG(@"Disk hit: %@, size: %.0fx%.0f", url.lastPathComponent, diskImage.size.width, diskImage.size.height);
            return diskImage;
        } else {
            GALLERY_LOG(@"Disk hit but image init failed: %@", url.lastPathComponent);
        }
    }

    return nil;
}

- (void)cacheImage:(NSImage *)image forURL:(NSURL *)url size:(ArtistImageCacheSize)size {
    if (!image || !url) return;

    NSString *key = CacheKeyForURL(url, size);

    // Resize if needed
    NSImage *resizedImage = [self resizeImage:image toMaxSize:(size == ArtistImageCacheSizeThumbnail) ? kThumbnailMaxSize : kFullMaxSize];

    // Memory cache - use pixel area as cost for totalCostLimit (PERF-9)
    NSSize imgSize = resizedImage.size;
    NSUInteger cost = (NSUInteger)(imgSize.width * imgSize.height * 4);
    [self.memoryCache setObject:resizedImage forKey:key cost:cost];

    // Disk cache (async) - PERF-4: Write PNG directly via CGImageDestination
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURL *fileURL = [self.diskCacheURL URLByAppendingPathComponent:key];
        CGImageRef cgImage = [resizedImage CGImageForProposedRect:NULL context:nil hints:nil];
        if (!cgImage) return;

        CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)fileURL, kUTTypePNG, 1, NULL);
        if (!dest) return;

        CGImageDestinationAddImage(dest, cgImage, NULL);
        if (!CGImageDestinationFinalize(dest)) {
            GALLERY_LOG(@"Failed to write image to disk: %@", key);
        }
        CFRelease(dest);
    });
}

#pragma mark - Image Cache - Asynchronous

- (void)loadImageFromURL:(NSURL *)url
                    size:(ArtistImageCacheSize)size
              completion:(void (^)(NSImage * _Nullable image))completion {

    // Check cache first
    NSImage *cached = [self cachedImageForURL:url size:size];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(cached);
        });
        return;
    }

    NSString *key = CacheKeyForURL(url, size);

    // Check if download already in progress
    [self.pendingLock lock];
    NSMutableArray *existingCompletions = self.pendingCompletions[key];
    if (existingCompletions) {
        // Add to existing pending list
        [existingCompletions addObject:[completion copy]];
        [self.pendingLock unlock];
        return;
    }

    // Start new download
    self.pendingCompletions[key] = [NSMutableArray arrayWithObject:[completion copy]];
    [self.pendingLock unlock];

    // SEC-3: Validate URL scheme before downloading
    if (!url.scheme || (![url.scheme isEqualToString:@"https"] && ![url.scheme isEqualToString:@"http"])) {
        GALLERY_LOG(@"Rejecting non-HTTP URL: %@", url.absoluteString);
        [self.pendingLock lock];
        [self.pendingCompletions removeObjectForKey:key];
        [self.pendingLock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
        return;
    }

    GALLERY_LOG(@"Downloading: %@", url.lastPathComponent);

    // PERF-1: Use NSURLSession instead of synchronous dataWithContentsOfURL
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSImage *image = nil;

        if (error) {
            GALLERY_LOG(@"Download error for %@: %@", url.lastPathComponent, error.localizedDescription);
        }

        if (data) {
            GALLERY_LOG(@"Downloaded %lu bytes from %@", (unsigned long)data.length, url.lastPathComponent);
            image = [self decodeImageFromData:data maxSize:(size == ArtistImageCacheSizeThumbnail) ? kThumbnailMaxSize : kFullMaxSize];
        }

        if (image) {
            [self cacheImage:image forURL:url size:size];
        }

        // Notify all pending completions
        [self.pendingLock lock];
        NSArray *completions = [self.pendingCompletions[key] copy];
        [self.pendingCompletions removeObjectForKey:key];
        [self.pendingLock unlock];

        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^block)(NSImage *) in completions) {
                block(image);
            }
        });
    }];
    [task resume];
}

- (void)prefetchImages:(NSArray<NSURL *> *)urls size:(ArtistImageCacheSize)size {
    for (NSURL *url in urls) {
        // Only prefetch if not already cached
        if (![self cachedImageForURL:url size:size]) {
            [self loadImageFromURL:url size:size completion:^(NSImage * _Nullable image) {
                // Prefetch complete, do nothing
            }];
        }
    }
}

- (void)cancelPendingDownloads {
    [self.downloadQueue cancelAllOperations];

    [self.pendingLock lock];
    [self.pendingCompletions removeAllObjects];
    [self.pendingLock unlock];
}

#pragma mark - Gallery Data Cache

- (nullable ArtistGalleryData *)cachedGalleryDataForArtist:(NSString *)artistName {
    if (!artistName) return nil;

    NSString *key = CacheKeyForArtist(artistName);
    NSURL *fileURL = [self.galleryDataCacheURL URLByAppendingPathComponent:key];

    // Check if file exists and is not expired
    NSError *error = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fileURL.path error:&error];
    if (error || !attrs) return nil;

    NSDate *modDate = attrs[NSFileModificationDate];
    if (!modDate || -[modDate timeIntervalSinceNow] > kGalleryDataTTL) {
        // Expired
        return nil;
    }

    // Load and decode
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (!data) return nil;

    @try {
        NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
        if (error) return nil;

        unarchiver.requiresSecureCoding = YES;
        ArtistGalleryData *galleryData = [unarchiver decodeObjectOfClass:[ArtistGalleryData class] forKey:NSKeyedArchiveRootObjectKey];
        [unarchiver finishDecoding];

        if (galleryData) {
            GALLERY_LOG(@"Gallery cache hit: %@", artistName);
        }
        return galleryData;
    } @catch (NSException *exception) {
        return nil;
    }
}

- (void)cacheGalleryData:(ArtistGalleryData *)data {
    if (!data || !data.artistName) return;

    NSString *key = CacheKeyForArtist(data.artistName);
    NSURL *fileURL = [self.galleryDataCacheURL URLByAppendingPathComponent:key];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
        [archiver encodeObject:data forKey:NSKeyedArchiveRootObjectKey];
        [archiver finishEncoding];
        NSData *encoded = archiver.encodedData;

        NSError *writeError = nil;
        if ([encoded writeToURL:fileURL options:NSDataWritingAtomic error:&writeError]) {
            GALLERY_LOG(@"Gallery cached: %@", data.artistName);
        } else {
            GALLERY_LOG(@"Gallery cache write failed: %@", writeError.localizedDescription);
        }
    });
}

#pragma mark - Cache Management

- (void)clearMemoryCache {
    [self.memoryCache removeAllObjects];
    GALLERY_LOG(@"Memory cache cleared");
}

- (void)clearDiskCache {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Clear images
    NSArray *imageFiles = [fm contentsOfDirectoryAtURL:self.diskCacheURL
                            includingPropertiesForKeys:nil
                                               options:0
                                                 error:nil];
    for (NSURL *file in imageFiles) {
        [fm removeItemAtURL:file error:nil];
    }

    // Clear gallery data
    NSArray *galleryFiles = [fm contentsOfDirectoryAtURL:self.galleryDataCacheURL
                              includingPropertiesForKeys:nil
                                                 options:0
                                                   error:nil];
    for (NSURL *file in galleryFiles) {
        [fm removeItemAtURL:file error:nil];
    }

    GALLERY_LOG(@"Disk cache cleared");
}

- (void)clearAllCaches {
    [self clearMemoryCache];
    [self clearDiskCache];
}

- (NSUInteger)memoryCacheCount {
    // NSCache doesn't expose count, return 0
    return 0;
}

- (NSUInteger)diskCacheSize {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger totalSize = 0;

    NSArray *files = [fm contentsOfDirectoryAtURL:self.diskCacheURL
                       includingPropertiesForKeys:@[NSURLFileSizeKey]
                                          options:0
                                            error:nil];
    for (NSURL *file in files) {
        NSNumber *size = nil;
        [file getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        totalSize += size.unsignedIntegerValue;
    }

    return totalSize;
}

#pragma mark - Image Processing

- (NSImage *)resizeImage:(NSImage *)image toMaxSize:(NSUInteger)maxSize {
    NSSize originalSize = image.size;

    // Check if resize needed
    if (originalSize.width <= maxSize && originalSize.height <= maxSize) {
        return image;
    }

    // Calculate new size maintaining aspect ratio
    CGFloat scale = MIN((CGFloat)maxSize / originalSize.width, (CGFloat)maxSize / originalSize.height);
    NSInteger newWidth = (NSInteger)floor(originalSize.width * scale);
    NSInteger newHeight = (NSInteger)floor(originalSize.height * scale);

    // PERF-3: Use CGBitmapContext instead of lockFocus (thread-safe)
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) return image;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, newWidth, newHeight, 8,
                                              newWidth * 4, colorSpace,
                                              kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colorSpace);
    if (!ctx) return image;

    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, newWidth, newHeight), cgImage);
    CGImageRef resizedCG = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);

    if (!resizedCG) return image;
    NSImage *resized = [[NSImage alloc] initWithCGImage:resizedCG size:NSMakeSize(newWidth, newHeight)];
    CGImageRelease(resizedCG);

    return resized;
}

- (nullable NSImage *)decodeImageFromData:(NSData *)data maxSize:(NSUInteger)maxSize {
    // Use CGImageSource for memory-efficient streaming decode
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    // Create thumbnail options for efficient decoding
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxSize),
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES
    };

    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);

    if (!cgImage) return nil;

    NSImage *image = [[NSImage alloc] initWithCGImage:cgImage size:NSZeroSize];
    CGImageRelease(cgImage);

    return image;
}

@end
