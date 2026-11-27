//
//  SVArtistImageProvider.mm
//  foo_jl_shellvanced_mac
//
//  Decision rule (never show a stranger's photo):
//    - exactly one exact-name Deezer artist with a real picture -> use it
//    - several exact-name artists -> only one whose Deezer album titles overlap
//      the user's album/track titles; otherwise no photo
//    - Deezer picture that equals one of the artist's album covers (dHash) or no Deezer photo ->
//      Spotify (optional, credentials in Keychain) with the same verification; cover-like Deezer
//      picture is the fallback after Spotify
//    - no photo -> newest album's cover, else initials
//

#import "SVArtistImageProvider.h"
#import "SVArtistLibrary.h"
#import "SVDeezerClient.h"
#import "SVSpotifyClient.h"
#include "ImageHashCore.h"
#include "DeezerMatchCore.h"
#include "../../../../shared/ArtistNames.h"

#import <CommonCrypto/CommonDigest.h>

NSNotificationName const SVArtistImagesDidChangeNotification = @"SVArtistImagesDidChangeNotification";

static const NSTimeInterval kNegativeTTL = 30.0 * 24 * 60 * 60;

@interface SVPendingRequest : NSObject
@property CGFloat size;
@property (copy) void (^completion)(NSImage *);
@end
@implementation SVPendingRequest
@end

#pragma mark - Drawing

static NSString *Initials(NSString *name) {
    NSMutableString *s = [NSMutableString string];
    for (NSString *w in [name componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (w.length == 0) continue;
        unichar c = [w characterAtIndex:0];
        if (![[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]) continue;
        [s appendString:[[w substringToIndex:[w rangeOfComposedCharacterSequenceAtIndex:0].length] uppercaseString]];
        if (s.length >= 2) break;
    }
    return s.length ? s : @"?";
}

// Round crop at `points`. `source` nil draws a placeholder with initials.
static NSImage *RoundImage(NSImage *source, NSString *name, CGFloat points) {
    NSSize size = NSMakeSize(points, points);
    NSString *initials = source ? nil : Initials(name);
    BOOL (^draw)(NSRect) = ^BOOL(NSRect rect) {
        NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:rect];
        [NSGraphicsContext saveGraphicsState];
        [circle addClip];
        if (source) {
            NSSize s = source.size;
            if (s.width > 0 && s.height > 0) {
                CGFloat side = MIN(s.width, s.height);
                NSRect from = NSMakeRect((s.width - side) / 2, (s.height - side) / 2, side, side);  // center square
                [source drawInRect:rect fromRect:from operation:NSCompositingOperationSourceOver
                          fraction:1.0 respectFlipped:YES
                             hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
            }
        } else {
            [[NSColor colorWithWhite:0.5 alpha:0.35] setFill];
            NSRectFill(rect);
            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:rect.size.height * 0.38 weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.85]};
            NSSize t = [initials sizeWithAttributes:attrs];
            [initials drawAtPoint:NSMakePoint(NSMidX(rect) - t.width / 2, NSMidY(rect) - t.height / 2)
                   withAttributes:attrs];
        }
        [NSGraphicsContext restoreGraphicsState];
        return YES;
    };

    // Render once into a bitmap at points x backing scale (2x when unknown): no lazy
    // re-decode/re-scale of the full-size source on every redraw.
    CGFloat scale = NSScreen.mainScreen.backingScaleFactor;
    if (scale < 1) scale = 2;
    NSInteger px = (NSInteger)ceil(points * scale);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:px pixelsHigh:px bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = size;
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    ctx.imageInterpolation = NSImageInterpolationHigh;
    draw(NSMakeRect(0, 0, points, points));
    [NSGraphicsContext restoreGraphicsState];
    NSImage *img = [[NSImage alloc] initWithSize:size];
    [img addRepresentation:rep];
    return img;
}

static const CGFloat kMaxSourcePixels = 512.0;

// Downscales (aspect preserved) so the long side is at most kMaxSourcePixels; returns img if already small.
static NSImage *Downscaled(NSImage *img) {
    NSImageRep *best = nil;
    for (NSImageRep *r in img.representations)
        if (!best || r.pixelsWide > best.pixelsWide) best = r;
    CGFloat w = best ? best.pixelsWide : img.size.width, h = best ? best.pixelsHigh : img.size.height;
    CGFloat longSide = MAX(w, h);
    if (longSide <= kMaxSourcePixels || longSide <= 0) return img;
    CGFloat f = kMaxSourcePixels / longSide;
    NSInteger pw = MAX(1, (NSInteger)round(w * f)), ph = MAX(1, (NSInteger)round(h * f));
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:pw pixelsHigh:ph bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = NSMakeSize(pw, ph);
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    ctx.imageInterpolation = NSImageInterpolationHigh;
    [img drawInRect:NSMakeRect(0, 0, pw, ph) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    NSImage *out = [[NSImage alloc] initWithSize:rep.size];
    [out addRepresentation:rep];
    return out;
}

static NSUInteger CostOf(NSImage *img) {
    NSImageRep *r = img.representations.firstObject;
    return (NSUInteger)(r ? r.pixelsWide * r.pixelsHigh : img.size.width * img.size.height) * 4;
}

static NSImage *DecodeImage(NSData *data) {
    if (data.length == 0) return nil;
    NSImage *img = [[NSImage alloc] initWithData:data];
    return (img && img.size.width > 0 && img.size.height > 0) ? Downscaled(img) : nil;
}

static const NSTimeInterval kRetryDelay = 60.0;
static const NSUInteger kMaxTransientEntries = 2000;

// In-memory short-circuit for transient failures (60 s) and "no photo, no cover" (this session).
@interface SVTransientResult : NSObject
@property BOOL hasCover;  // the cover itself lives in the cost-limited _transientCovers cache
@property (strong) NSDate *until;
@end
@implementation SVTransientResult
@end

@interface SVDeezerPick : NSObject
@property (strong) NSData *data;
@property (strong) NSImage *image;
@end
@implementation SVDeezerPick
@end

#pragma mark - Provider

@implementation SVArtistImageProvider {
    NSCache<NSString *, NSImage *> *_sourceCache;   // key -> square source (photo or cover)
    NSCache<NSString *, NSImage *> *_roundCache;    // key|size -> rounded
    NSMutableDictionary<NSString *, NSMutableArray<SVPendingRequest *> *> *_pending;  // main thread only
    NSOperationQueue *_workQueue;
    dispatch_queue_t _diskQueue;                    // serial: writes + negative store
    NSURL *_cacheDir;
    NSMutableDictionary<NSString *, NSNumber *> *_negative;  // key -> epoch; _diskQueue only
    BOOL _negativeSavePending;                               // _diskQueue only
    NSMutableSet<NSString *> *_spotifyInFlight;     // main thread only: keys with a background Spotify lookup
    NSString *_headerKey;                           // main thread: artist page header's key (Spotify priority)
    NSString *_latestKey;                           // main thread: most recently requested key
    NSMutableDictionary<NSString *, SVTransientResult *> *_transient;  // main thread only; no images
    NSCache<NSString *, NSImage *> *_transientCovers;   // 60 s covers, cost-limited
    NSCache<NSString *, NSImage *> *_transientRounds;   // rounded images for transient hits, cost-limited
}

+ (instancetype)shared {
    static SVArtistImageProvider *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[SVArtistImageProvider alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _sourceCache = [[NSCache alloc] init];
        _sourceCache.totalCostLimit = 64 * 1024 * 1024;
        _roundCache = [[NSCache alloc] init];
        _roundCache.totalCostLimit = 32 * 1024 * 1024;
        _transient = [NSMutableDictionary dictionary];
        _spotifyInFlight = [NSMutableSet set];
        _transientCovers = [[NSCache alloc] init];
        _transientCovers.totalCostLimit = 16 * 1024 * 1024;
        _transientRounds = [[NSCache alloc] init];
        _transientRounds.totalCostLimit = 8 * 1024 * 1024;
        // A new library snapshot may know artists/albums the old one did not: forget session/transient results.
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(clearTransient)
            name:SVArtistLibraryDidChangeNotification object:nil];
        _pending = [NSMutableDictionary dictionary];
        _workQueue = [[NSOperationQueue alloc] init];
        _workQueue.maxConcurrentOperationCount = 3;
        _workQueue.qualityOfService = NSQualityOfServiceUtility;
        _diskQueue = dispatch_queue_create("foo_jl_shellvanced.artistimages.disk", DISPATCH_QUEUE_SERIAL);
        NSURL *caches = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
        _cacheDir = [[caches URLByAppendingPathComponent:@"foo_jl_shellvanced" isDirectory:YES]
                        URLByAppendingPathComponent:@"artists" isDirectory:YES];
        [[NSFileManager defaultManager] createDirectoryAtURL:_cacheDir withIntermediateDirectories:YES
                                                  attributes:nil error:nil];
        [self migrateCacheIfNeeded];
    }
    return self;
}

#pragma mark - Keys and disk

static NSString *const kCacheFormat = @"4";

// v4: earlier caches may hold wrong-artist photos, Deezer placeholders and cover-like pictures; wipe once.
- (void)migrateCacheIfNeeded {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *marker = [_cacheDir URLByAppendingPathComponent:@"format"];
    NSString *cur = [NSString stringWithContentsOfURL:marker encoding:NSUTF8StringEncoding error:nil];
    if ([cur isEqualToString:kCacheFormat]) return;
    for (NSURL *u in [fm contentsOfDirectoryAtURL:_cacheDir includingPropertiesForKeys:nil options:0 error:nil])
        if ([u.pathExtension isEqualToString:@"jpg"] || [u.pathExtension isEqualToString:@"cl"] ||
            [u.lastPathComponent isEqualToString:@"negative.json"])
            [fm removeItemAtURL:u error:nil];
    [kCacheFormat writeToURL:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// Classifies a decoded image on a 24x24 downscale; also rejects the known placeholder bytes.
static BOOL IsPlaceholderPhoto(NSData *data, NSImage *img) {
    unsigned char md[CC_SHA1_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(data.bytes, (CC_LONG)data.length, md);
#pragma clang diagnostic pop
    NSString *hex = @"";
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) hex = [hex stringByAppendingFormat:@"%02x", md[i]];
    if ([hex isEqualToString:@"b92c0575e728b71f120618a25c1c52716007ed96"]) return YES;
    CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) return NO;
    const int N = 24;
    uint8_t buf[N * N * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, N, N, 8, N * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NO;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, N, N), cg);
    CGContextRelease(ctx);
    return deezermatch::looksLikePlaceholderPhoto(buf, N, N);
}

static NSString *SHA1Hex(NSString *s) {
    const char *utf8 = s.UTF8String;
    unsigned char md[CC_SHA1_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(utf8, (CC_LONG)strlen(utf8), md);
#pragma clang diagnostic pop
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", md[i]];
    return hex;
}

- (NSURL *)photoURLForKey:(NSString *)key {
    return [_cacheDir URLByAppendingPathComponent:[SHA1Hex(key) stringByAppendingString:@".jpg"]];
}

// Cover-like Deezer picture kept as the fallback while Spotify is unavailable/negative (30-day TTL by mtime).
- (NSURL *)coverLikeURLForKey:(NSString *)key {
    return [_cacheDir URLByAppendingPathComponent:[SHA1Hex(key) stringByAppendingString:@".cl"]];
}

- (NSURL *)negativeURL { return [_cacheDir URLByAppendingPathComponent:@"negative.json"]; }

// Must be called on _diskQueue.
- (NSMutableDictionary<NSString *, NSNumber *> *)negativeStoreLocked {
    if (!_negative) {
        _negative = [NSMutableDictionary dictionary];
        NSData *data = [NSData dataWithContentsOfURL:[self negativeURL]];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        // v3 format: {"v":3,"e":{key:epoch}}. Older (unversioned) files were recorded under the previous
        // matching rule and are ignored so the new rule can retry those artists.
        NSDictionary *entries = nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"v"] isEqual:@3] &&
            [json[@"e"] isKindOfClass:[NSDictionary class]])
            entries = json[@"e"];
        if (entries) {
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            [entries enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
                if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSNumber class]] &&
                    now - [v doubleValue] < kNegativeTTL)
                    self->_negative[k] = v;
            }];
        }
    }
    return _negative;
}

- (void)isNegativeKey:(NSString *)key completion:(void (^)(BOOL negative))completion {
    dispatch_async(_diskQueue, ^{
        NSNumber *when = [self negativeStoreLocked][key];
        BOOL neg = when && [NSDate date].timeIntervalSince1970 - when.doubleValue < kNegativeTTL;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(neg); });
    });
}

- (void)recordNegativeKey:(NSString *)key {
    dispatch_async(_diskQueue, ^{
        NSMutableDictionary *store = [self negativeStoreLocked];
        store[key] = @([NSDate date].timeIntervalSince1970);
        if (self->_negativeSavePending) return;  // a coalesced write is already scheduled
        self->_negativeSavePending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), self->_diskQueue, ^{
            self->_negativeSavePending = NO;
            NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"v": @3, @"e": [self negativeStoreLocked]} options:0 error:nil];
            [data writeToURL:[self negativeURL] atomically:YES];
        });
    });
}

#pragma mark - Public

- (void)imageForArtist:(NSString *)name size:(CGFloat)points completion:(void (^)(NSImage *))completion {
    [self imageForArtist:name size:points priority:NO completion:completion];
}

- (void)imageForArtist:(NSString *)name size:(CGFloat)points priority:(BOOL)priority
            completion:(void (^)(NSImage *))completion {
    NSAssert([NSThread isMainThread], @"main thread only");
    if (points < 1) points = 1;
    std::string stdName = name.UTF8String ? name.UTF8String : "";
    NSString *key = [NSString stringWithUTF8String:artistnames::artistKey(stdName).c_str()] ?: @"";
    if (key.length == 0) { completion(RoundImage(nil, name, points)); return; }
    if (priority) _headerKey = key;
    _latestKey = key;

    NSString *roundKey = [NSString stringWithFormat:@"%@|%g", key, points];
    NSImage *cached = [_roundCache objectForKey:roundKey];
    if (cached) { completion(cached); return; }

    NSImage *source = [_sourceCache objectForKey:key];
    if (source) {
        NSImage *round = RoundImage(source, name, points);
        [_roundCache setObject:round forKey:roundKey cost:CostOf(round)];
        completion(round);
        return;
    }

    SVTransientResult *t = _transient[key];
    if (t) {
        if ([t.until timeIntervalSinceNow] > 0) {
            NSString *tKey = [self transientRoundKeyForKey:key size:points entry:t];
            NSImage *tRound = [_transientRounds objectForKey:tKey];
            if (tRound) { completion(tRound); return; }
            NSImage *cover = t.hasCover ? [_transientCovers objectForKey:key] : nil;
            if (!t.hasCover || cover) {  // (cover evicted under memory pressure -> rerun below)
                NSImage *round = RoundImage(cover, name, points);
                [_transientRounds setObject:round forKey:tKey cost:CostOf(round)];
                completion(round);
                return;
            }
        }
        [_transient removeObjectForKey:key];  // expired or cover evicted: run the pipeline again
    }

    SVPendingRequest *req = [[SVPendingRequest alloc] init];
    req.size = points;
    req.completion = completion;
    NSMutableArray *list = _pending[key];
    if (list) { [list addObject:req]; return; }  // load already in flight
    _pending[key] = [NSMutableArray arrayWithObject:req];
    [self loadForName:name key:key];
}

// Main thread. `source` nil = placeholder. `cache` NO for transient failures so a retry can happen.
// With cache NO the result is remembered for kRetryDelay only (transient failure); with cache YES
// and no image (no photo, no cover) it is remembered for the session.
- (void)finishKey:(NSString *)key name:(NSString *)name source:(NSImage *)source cache:(BOOL)cache {
    if (source && cache) {
        [_sourceCache setObject:source forKey:key cost:CostOf(source)];
        [_transient removeObjectForKey:key];
    } else {
        // Bounded: prune expired entries on write; hard cap as a backstop.
        if (_transient.count >= kMaxTransientEntries) {
            NSDate *now = [NSDate date];
            for (NSString *k in [_transient allKeys])
                if ([_transient[k].until compare:now] != NSOrderedDescending) [_transient removeObjectForKey:k];
            if (_transient.count >= kMaxTransientEntries) [_transient removeAllObjects];
        }
        SVTransientResult *t = [[SVTransientResult alloc] init];
        t.until = cache ? [NSDate distantFuture] : [NSDate dateWithTimeIntervalSinceNow:kRetryDelay];
        t.hasCover = source != nil;
        _transient[key] = t;
        if (source) [_transientCovers setObject:source forKey:key cost:CostOf(source)];
        else [_transientCovers removeObjectForKey:key];
    }
    SVTransientResult *tr = _transient[key];
    NSArray<SVPendingRequest *> *list = _pending[key];
    [_pending removeObjectForKey:key];
    for (SVPendingRequest *req in list) {
        NSImage *round = RoundImage(source, name, req.size);
        if (source && cache)
            [_roundCache setObject:round forKey:[NSString stringWithFormat:@"%@|%g", key, req.size]
                              cost:CostOf(round)];
        else if (tr)
            [_transientRounds setObject:round forKey:[self transientRoundKeyForKey:key size:req.size entry:tr]
                                   cost:CostOf(round)];
        req.completion(round);
    }
}

// Includes the expiry so a round rendered for an earlier transient result is never reused.
- (NSString *)transientRoundKeyForKey:(NSString *)key size:(CGFloat)points entry:(SVTransientResult *)t {
    return [NSString stringWithFormat:@"%@|%g|%.0f", key, points, t.until.timeIntervalSinceReferenceDate];
}

- (void)clearTransient {
    [_transient removeAllObjects];
    [_transientCovers removeAllObjects];
    [_transientRounds removeAllObjects];
}

#pragma mark - Pipeline

static NSString *const kSpotifyNegPrefix = @"sp:";

static std::vector<std::string> NormalizedUserTitles(NSString *name) {
    std::vector<std::string> user;
    for (NSString *t in [[SVArtistLibrary shared] userTitlesForArtist:name])
        user.push_back(deezermatch::normalizeTitle(t.UTF8String ?: ""));
    return user;
}

static std::vector<std::string> NormalizedTitles(NSArray<NSString *> *titles) {
    std::vector<std::string> out;
    for (NSString *t in titles) out.push_back(deezermatch::normalizeTitle(t.UTF8String ?: ""));
    return out;
}

// 9x8 grayscale-ready render for the dHash.
static BOOL DHashOfImage(NSImage *img, uint64_t *out) {
    CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cg) return NO;
    uint8_t buf[9 * 8 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, 9, 8, 8, 9 * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) return NO;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 9, 8), cg);
    CGContextRelease(ctx);
    *out = imagehash::dHash9x8(buf);
    return YES;
}

// Step 1: disk photo, then a kept cover-like Deezer picture (< 30 days old).
- (void)loadForName:(NSString *)name key:(NSString *)key {
    NSURL *photo = [self photoURLForKey:key];
    NSURL *coverLike = [self coverLikeURLForKey:key];
    [_workQueue addOperationWithBlock:^{
        NSImage *img = [[NSImage alloc] initWithContentsOfURL:photo];
        img = (img && img.size.width > 0 && img.size.height > 0) ? Downscaled(img) : nil;
        if (!img) {
            NSDate *mtime = nil;
            [coverLike getResourceValue:&mtime forKey:NSURLContentModificationDateKey error:nil];
            if (mtime && -[mtime timeIntervalSinceNow] < kNegativeTTL) {
                NSImage *c = [[NSImage alloc] initWithContentsOfURL:coverLike];
                img = (c && c.size.width > 0 && c.size.height > 0) ? Downscaled(c) : nil;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (img) [self finishKey:key name:name source:img cache:YES];
            else [self checkNegativeForName:name key:key];
        });
    }];
}

// Step 2: negative cache. A Deezer negative still lets Spotify try (it has its own negative entry).
- (void)checkNegativeForName:(NSString *)name key:(NSString *)key {
    [self isNegativeKey:key completion:^(BOOL negative) {
        if (negative) [self spotifyStageForName:name key:key pick:nil];
        else [self searchDeezerForName:name key:key];
    }];
}

// Deezer has no usable photo for this artist: remember that, then try Spotify.
- (void)noDeezerPhotoForName:(NSString *)name key:(NSString *)key {
    [self recordNegativeKey:key];
    [self spotifyStageForName:name key:key pick:nil];
}

// Step 3: search.
- (void)searchDeezerForName:(NSString *)name key:(NSString *)key {
    [[SVDeezerClient shared] searchArtist:name completion:^(std::vector<deezermatch::Candidate> cands, BOOL ok) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) { [self fallbackForName:name key:key cacheResult:NO]; return; }  // transient: retry later
            std::vector<size_t> exact = deezermatch::narrowByExactName(
                name.UTF8String, cands, deezermatch::exactCandidates(name.UTF8String, cands));
            std::vector<deezermatch::Candidate> usable;
            for (size_t i : exact)
                if (deezermatch::hasRealPicture(cands[i].pictureUrl)) usable.push_back(cands[i]);

            if (usable.empty()) {
                [self noDeezerPhotoForName:name key:key];
            } else if (exact.size() == 1) {
                [self confirmLoneCandidate:usable[0] userTitles:NormalizedUserTitles(name) name:name key:key];
            } else {
                // Several same-name artists: only a candidate whose albums overlap the user's library.
                [self confirmCandidates:usable index:0 remote:{} coverLists:@[]
                             userTitles:NormalizedUserTitles(name) name:name key:key];
            }
        });
    }];
}

// Step 3a: lone exact-name candidate. Accept on title overlap, else only a small discography
// (nb_album <= 15) and a distinctive name (>= 5 chars); a big catalogue is probably someone else.
- (void)confirmLoneCandidate:(deezermatch::Candidate)cand
                  userTitles:(std::vector<std::string>)user
                        name:(NSString *)name
                         key:(NSString *)key {
    NSString *cid = [NSString stringWithUTF8String:cand.id.c_str()];
    [[SVDeezerClient shared] albumsForArtistId:cid completion:^(NSArray<NSString *> *titles, NSArray<NSString *> *covers) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!titles) { [self fallbackForName:name key:key cacheResult:NO]; return; }  // transient failure
            if (deezermatch::chooseCandidate(user, {NormalizedTitles(titles)}) == 0) {
                [self acceptDeezerPicture:[NSString stringWithUTF8String:cand.pictureUrl.c_str()] covers:covers name:name key:key];
                return;
            }
            void (^decide)(long) = ^(long nb) {
                if (nb < 0) { [self fallbackForName:name key:key cacheResult:NO]; return; }
                if (deezermatch::acceptLoneWithoutOverlap(name.UTF8String ?: "", nb))
                    [self acceptDeezerPicture:[NSString stringWithUTF8String:cand.pictureUrl.c_str()] covers:covers name:name key:key];
                else
                    [self noDeezerPhotoForName:name key:key];
            };
            if (cand.nbAlbum >= 0) { decide(cand.nbAlbum); return; }
            [[SVDeezerClient shared] albumCountForArtistId:cid completion:^(long nb) {
                dispatch_async(dispatch_get_main_queue(), ^{ decide(nb); });
            }];
        });
    }];
}

// Step 3b: fetch every usable candidate's albums sequentially, then let the pure rule pick.
// Zero or several acceptable candidates (ambiguous) -> no photo.
- (void)confirmCandidates:(std::vector<deezermatch::Candidate>)cands
                    index:(size_t)i
                   remote:(std::vector<std::vector<std::string>>)remote
               coverLists:(NSArray<NSArray<NSString *> *> *)coverLists
               userTitles:(std::vector<std::string>)user
                     name:(NSString *)name
                      key:(NSString *)key {
    if (i >= cands.size()) {
        int chosen = deezermatch::chooseCandidate(user, remote);
        if (chosen < 0) [self noDeezerPhotoForName:name key:key];
        else [self acceptDeezerPicture:[NSString stringWithUTF8String:cands[(size_t)chosen].pictureUrl.c_str()] covers:coverLists[(NSUInteger)chosen]
                                  name:name key:key];
        return;
    }
    NSString *cid = [NSString stringWithUTF8String:cands[i].id.c_str()];
    [[SVDeezerClient shared] albumsForArtistId:cid completion:^(NSArray<NSString *> *titles, NSArray<NSString *> *covers) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!titles) { [self fallbackForName:name key:key cacheResult:NO]; return; }  // transient failure
            auto all = remote;
            all.push_back(NormalizedTitles(titles));
            [self confirmCandidates:cands index:i + 1 remote:std::move(all)
                         coverLists:[coverLists arrayByAddingObject:covers]
                         userTitles:user name:name key:key];
        });
    }];
}

// Step 4: download the confirmed Deezer picture. Placeholder -> no photo. A picture that is really one of
// the artist's album covers (dHash) is only a fallback behind Spotify.
- (void)acceptDeezerPicture:(NSString *)urlString covers:(NSArray<NSString *> *)covers
                       name:(NSString *)name key:(NSString *)key {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { [self fallbackForName:name key:key cacheResult:NO]; return; }
    [[SVDeezerClient shared] downloadImageAtURL:url completion:^(NSData *data) {
        NSImage *img = DecodeImage(data);
        if (!img) { dispatch_async(dispatch_get_main_queue(), ^{ [self fallbackForName:name key:key cacheResult:NO]; }); return; }
        if (IsPlaceholderPhoto(data, img)) {  // Deezer's generic silhouette = no real picture
            dispatch_async(dispatch_get_main_queue(), ^{ [self noDeezerPhotoForName:name key:key]; });
            return;
        }
        uint64_t photoHash = 0;
        // Cannot hash the photo: skip the comparison.
        NSArray<NSString *> *toCompare = DHashOfImage(img, &photoHash) ? covers : @[];
        [self checkCoverLikeHash:photoHash covers:toCompare index:0 done:^(BOOL coverLike) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!coverLike) {
                    NSURL *dest = [self photoURLForKey:key];
                    dispatch_async(self->_diskQueue, ^{ [data writeToURL:dest atomically:YES]; });
                    [self finishKey:key name:name source:img cache:YES];
                    return;
                }
                SVDeezerPick *pick = [[SVDeezerPick alloc] init];
                pick.data = data;
                pick.image = img;
                [self spotifyStageForName:name key:key pick:pick];
            });
        }];
    }];
}

// Downloads the artist's album covers one by one (<= 10, CDN, rate limited) and stops at the first
// whose hash is close to the photo's. Failed covers are skipped. `done` runs on a background queue.
- (void)checkCoverLikeHash:(uint64_t)photoHash covers:(NSArray<NSString *> *)covers index:(NSUInteger)i
                      done:(void (^)(BOOL coverLike))done {
    if (i >= covers.count || i >= 10) { done(NO); return; }
    NSURL *u = [NSURL URLWithString:covers[i]];
    if (!u) { [self checkCoverLikeHash:photoHash covers:covers index:i + 1 done:done]; return; }
    [[SVDeezerClient shared] downloadImageAtURL:u completion:^(NSData *d) {
        NSImage *im = d.length ? [[NSImage alloc] initWithData:d] : nil;
        uint64_t h = 0;
        if (im && DHashOfImage(im, &h) && imagehash::isCoverLike(photoHash, {h})) { done(YES); return; }
        [self checkCoverLikeHash:photoHash covers:covers index:i + 1 done:done];
    }];
}

#pragma mark - Spotify

typedef NS_ENUM(NSInteger, SVPickPersist) { SVPickPersistNone, SVPickPersistNormal, SVPickPersistShort };

// Keeps the cover-like Deezer picture on disk (.cl). Normal = 30-day TTL; Short = 1 day (Spotify
// blocked/failing), done by back-dating the file. Skipped when the credentials changed meanwhile.
- (void)persistPick:(SVDeezerPick *)pick mode:(SVPickPersist)mode generation:(NSUInteger)gen key:(NSString *)key {
    if (!pick || mode == SVPickPersistNone || gen != [SVSpotifyClient shared].generation) return;
    NSURL *dest = [self coverLikeURLForKey:key];
    NSData *data = pick.data;
    dispatch_async(_diskQueue, ^{
        [data writeToURL:dest atomically:YES];
        if (mode == SVPickPersistShort)
            [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow:-(kNegativeTTL - 24 * 3600)]}
                                             ofItemAtPath:dest.path error:nil];
    });
}

// Shows the cover-like Deezer pick, or the album-art/initials fallback when there is none.
- (void)showFallbackPick:(SVDeezerPick *)pick name:(NSString *)name key:(NSString *)key {
    if (pick) [self finishKey:key name:name source:pick.image cache:YES];
    else [self fallbackForName:name key:key cacheResult:YES];
}

- (BOOL)isUrgentKey:(NSString *)key {
    return [key isEqualToString:_headerKey] || [key isEqualToString:_latestKey];
}

// Source order: reached for a Deezer miss (pick nil) or a cover-like Deezer picture (pick). The UI is
// never held up: the fallback is shown immediately and replaced when Spotify returns a verified photo.
- (void)spotifyStageForName:(NSString *)name key:(NSString *)key pick:(SVDeezerPick *)pick {
    SVSpotifyClient *sp = [SVSpotifyClient shared];
    const NSUInteger gen = sp.generation;
    if (!spmatch::needsSpotify(pick != nil, pick != nil, sp.isAvailable)) {
        [self showFallbackPick:pick name:name key:key];
        [self persistPick:pick mode:sp.isTemporarilyUnavailable ? SVPickPersistShort : SVPickPersistNormal
               generation:gen key:key];
        return;
    }
    [self showFallbackPick:pick name:name key:key];
    if ([_spotifyInFlight containsObject:key]) return;  // a lookup for this artist is already running
    [_spotifyInFlight addObject:key];
    NSString *spKey = [kSpotifyNegPrefix stringByAppendingString:key];
    [self isNegativeKey:spKey completion:^(BOOL negative) {
        if (negative) {
            [self->_spotifyInFlight removeObject:key];
            [self persistPick:pick mode:SVPickPersistNormal generation:gen key:key];
            return;
        }
        [self spotifyLookupName:name key:key completion:^(NSString *imageUrl, SVSpotifyStatus status) {
            void (^finish)(SVPickPersist) = ^(SVPickPersist mode) {
                [self->_spotifyInFlight removeObject:key];
                [self persistPick:pick mode:mode generation:gen key:key];
            };
            if (status == SVSpotifyStatusOK && imageUrl) {
                NSURL *url = [NSURL URLWithString:imageUrl];
                if (!url) { finish(SVPickPersistShort); return; }
                [[SVSpotifyClient shared] downloadImageAtURL:url completion:^(NSData *data) {
                    NSImage *img = DecodeImage(data);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!img) { finish(SVPickPersistShort); return; }
                        [self->_spotifyInFlight removeObject:key];
                        NSURL *dest = [self photoURLForKey:key];
                        dispatch_async(self->_diskQueue, ^{ [data writeToURL:dest atomically:YES]; });
                        [self upgradeKey:key toImage:img];
                    });
                }];
            } else if (status == SVSpotifyStatusOK) {
                if (gen == [SVSpotifyClient shared].generation) [self recordNegativeKey:spKey];  // verified "no photo"
                finish(SVPickPersistNormal);
            } else {
                // Failed / blocked / rejected: no negative entry. Blocked or failing keeps the pick for a day only.
                finish(status == SVSpotifyStatusAuthFailed ? SVPickPersistNormal : SVPickPersistShort);
            }
        }];
    }];
}

// A verified Spotify photo arrived after the fallback was shown: swap it in and tell observers.
- (void)upgradeKey:(NSString *)key toImage:(NSImage *)img {
    [_sourceCache setObject:img forKey:key cost:CostOf(img)];
    [_transient removeObjectForKey:key];
    [_transientCovers removeObjectForKey:key];
    [_roundCache removeAllObjects];       // round renders are rebuilt from the source cache
    [_transientRounds removeAllObjects];
    [[NSNotificationCenter defaultCenter] postNotificationName:SVArtistImagesDidChangeNotification object:nil];
}

// Main-thread completion: verified Spotify image URL, or nil with OK (no confident match) / an error status.
- (void)spotifyLookupName:(NSString *)name key:(NSString *)key
               completion:(void (^)(NSString *_Nullable url, SVSpotifyStatus status))completion {
    [[SVSpotifyClient shared] searchArtist:name urgent:[self isUrgentKey:key]
                                completion:^(std::vector<spmatch::Candidate> cands, SVSpotifyStatus st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st != SVSpotifyStatusOK) { completion(nil, st); return; }
            // Ambiguity is judged on ALL exact-name candidates (image-less ones included); too many = give up.
            std::vector<spmatch::Candidate> use;
            for (size_t i : spmatch::exactCandidates(name.UTF8String ?: "", cands)) use.push_back(cands[i]);
            if (use.empty() || use.size() > 4) { completion(nil, SVSpotifyStatusOK); return; }
            std::vector<std::string> userAll = NormalizedUserTitles(name), userAlbums;
            for (NSString *t in [[SVArtistLibrary shared] albumTitlesForArtist:name])
                userAlbums.push_back(deezermatch::normalizeTitle(t.UTF8String ?: ""));
            [self spotifyConfirm:use index:0 remote:{} key:key userAlbums:userAlbums userAll:userAll completion:completion];
        });
    }];
}

- (void)spotifyConfirm:(std::vector<spmatch::Candidate>)cands
                 index:(size_t)i
                remote:(std::vector<spmatch::RemoteTitles>)remote
                   key:(NSString *)key
            userAlbums:(std::vector<std::string>)userAlbums
               userAll:(std::vector<std::string>)userAll
            completion:(void (^)(NSString *_Nullable, SVSpotifyStatus))completion {
    if (i >= cands.size()) {
        const int chosen = spmatch::chooseConfirmed(userAlbums, userAll, remote);
        NSString *url = (chosen >= 0 && !cands[(size_t)chosen].imageUrl.empty())
            ? [NSString stringWithUTF8String:cands[(size_t)chosen].imageUrl.c_str()] : nil;
        completion(url, SVSpotifyStatusOK);
        return;
    }
    NSString *cid = [NSString stringWithUTF8String:cands[i].id.c_str()];
    [[SVSpotifyClient shared] albumsForArtistId:cid urgent:[self isUrgentKey:key]
        completion:^(NSArray<NSString *> *all, NSArray<NSString *> *primary, long total, SVSpotifyStatus st) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (st != SVSpotifyStatusOK || !all) { completion(nil, st == SVSpotifyStatusOK ? SVSpotifyStatusFailed : st); return; }
            auto r = remote;
            spmatch::RemoteTitles rt;
            rt.all = NormalizedTitles(all);
            rt.primary = NormalizedTitles(primary);
            r.push_back(std::move(rt));
            [self spotifyConfirm:cands index:i + 1 remote:std::move(r) key:key
                      userAlbums:userAlbums userAll:userAll completion:completion];
        });
    }];
}

- (void)spotifyCredentialsDidChange {
    NSAssert([NSThread isMainThread], @"main thread only");
    dispatch_async(_diskQueue, ^{
        NSMutableDictionary *store = [self negativeStoreLocked];
        for (NSString *k in [store allKeys])
            if ([k hasPrefix:kSpotifyNegPrefix]) [store removeObjectForKey:k];
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"v": @3, @"e": store} options:0 error:nil];
        [data writeToURL:[self negativeURL] atomically:YES];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSURL *u in [fm contentsOfDirectoryAtURL:self->_cacheDir includingPropertiesForKeys:nil options:0 error:nil])
            if ([u.pathExtension isEqualToString:@"cl"]) [fm removeItemAtURL:u error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_sourceCache removeAllObjects];
            [self->_roundCache removeAllObjects];
            [self->_spotifyInFlight removeAllObjects];
            [self clearTransient];
            [[NSNotificationCenter defaultCenter] postNotificationName:SVArtistImagesDidChangeNotification object:nil];
        });
    });
}

// Step 5: newest album cover, else placeholder.
- (void)fallbackForName:(NSString *)name key:(NSString *)key cacheResult:(BOOL)cache {
    metadb_handle_ptr handle = [[SVArtistLibrary shared] representativeHandleForArtist:name];
    // Empty handle = snapshot not built yet / artist not indexed: only the 60 s path, never session-long.
    if (handle.is_empty()) { [self finishKey:key name:name source:nil cache:NO]; return; }
    [_workQueue addOperationWithBlock:^{
        NSImage *cover = nil;
        try {
            abort_callback_dummy abort;
            auto manager = album_art_manager_v2::get();
            metadb_handle_list items;
            items.add_item(handle);
            pfc::list_t<GUID> ids;
            ids.add_item(album_art_ids::cover_front);
            auto extractor = manager->open(items, ids, abort);
            album_art_data_ptr art;
            if (extractor->query(album_art_ids::cover_front, art, abort) && art.is_valid() && art->size() > 0)
                cover = DecodeImage([NSData dataWithBytes:art->data() length:art->size()]);
        } catch (...) {}
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishKey:key name:name source:cover cache:cache];
        });
    }];
}

@end
