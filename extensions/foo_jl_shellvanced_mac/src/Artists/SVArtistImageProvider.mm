//
//  SVArtistImageProvider.mm
//  foo_jl_shellvanced_mac
//
//  Decision rule (never show a stranger's photo):
//    - exactly one exact-name Deezer artist with a real picture -> use it
//    - several exact-name artists -> only one whose Deezer album titles overlap
//      the user's album/track titles; otherwise no photo
//    - no photo -> newest album's cover, else initials
//

#import "SVArtistImageProvider.h"
#import "SVArtistLibrary.h"
#import "SVDeezerClient.h"
#include "DeezerMatchCore.h"
#include "../../../../shared/ArtistNames.h"

#import <CommonCrypto/CommonDigest.h>

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
    }
    return self;
}

#pragma mark - Keys and disk

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

- (NSURL *)negativeURL { return [_cacheDir URLByAppendingPathComponent:@"negative.json"]; }

// Must be called on _diskQueue.
- (NSMutableDictionary<NSString *, NSNumber *> *)negativeStoreLocked {
    if (!_negative) {
        _negative = [NSMutableDictionary dictionary];
        NSData *data = [NSData dataWithContentsOfURL:[self negativeURL]];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        // v2 format: {"v":2,"e":{key:epoch}}. Older (unversioned) files were recorded under the previous
        // matching rule and are ignored so the new rule can retry those artists.
        NSDictionary *entries = nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"v"] isEqual:@2] &&
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
            NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"v": @2, @"e": [self negativeStoreLocked]} options:0 error:nil];
            [data writeToURL:[self negativeURL] atomically:YES];
        });
    });
}

#pragma mark - Public

- (void)imageForArtist:(NSString *)name size:(CGFloat)points completion:(void (^)(NSImage *))completion {
    NSAssert([NSThread isMainThread], @"main thread only");
    if (points < 1) points = 1;
    std::string stdName = name.UTF8String ? name.UTF8String : "";
    NSString *key = [NSString stringWithUTF8String:artistnames::artistKey(stdName).c_str()] ?: @"";
    if (key.length == 0) { completion(RoundImage(nil, name, points)); return; }

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

// Step 1: disk photo.
- (void)loadForName:(NSString *)name key:(NSString *)key {
    NSURL *photo = [self photoURLForKey:key];
    [_workQueue addOperationWithBlock:^{
        NSImage *img = [[NSImage alloc] initWithContentsOfURL:photo];
        img = (img && img.size.width > 0 && img.size.height > 0) ? Downscaled(img) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (img) [self finishKey:key name:name source:img cache:YES];
            else [self checkNegativeForName:name key:key];
        });
    }];
}

// Step 2: negative cache.
- (void)checkNegativeForName:(NSString *)name key:(NSString *)key {
    [self isNegativeKey:key completion:^(BOOL negative) {
        if (negative) [self fallbackForName:name key:key cacheResult:YES];
        else [self searchDeezerForName:name key:key];
    }];
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
                [self recordNegativeKey:key];
                [self fallbackForName:name key:key cacheResult:YES];
            } else if (exact.size() == 1) {
                [self downloadPhotoUrl:usable[0].pictureUrl name:name key:key];
            } else {
                // Several same-name artists: only a candidate whose albums overlap the user's library.
                std::vector<std::string> user;
                for (NSString *t in [[SVArtistLibrary shared] userTitlesForArtist:name])
                    user.push_back(deezermatch::normalizeTitle(t.UTF8String ?: ""));
                [self confirmCandidates:usable index:0 remote:{} userTitles:user name:name key:key];
            }
        });
    }];
}

// Step 3b: fetch every usable candidate's albums sequentially, then let the pure rule pick.
// Zero or several acceptable candidates (ambiguous) -> no photo, fallback.
- (void)confirmCandidates:(std::vector<deezermatch::Candidate>)cands
                    index:(size_t)i
                   remote:(std::vector<std::vector<std::string>>)remote
               userTitles:(std::vector<std::string>)user
                     name:(NSString *)name
                      key:(NSString *)key {
    if (i >= cands.size()) {
        int chosen = deezermatch::chooseCandidate(user, remote);
        if (chosen < 0) {
            [self recordNegativeKey:key];
            [self fallbackForName:name key:key cacheResult:YES];
        } else {
            [self downloadPhotoUrl:cands[(size_t)chosen].pictureUrl name:name key:key];
        }
        return;
    }
    NSString *cid = [NSString stringWithUTF8String:cands[i].id.c_str()];
    [[SVDeezerClient shared] albumTitlesForArtistId:cid completion:^(NSArray<NSString *> *titles) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!titles) { [self fallbackForName:name key:key cacheResult:NO]; return; }  // transient failure
            std::vector<std::string> titlesNorm;
            for (NSString *t in titles) titlesNorm.push_back(deezermatch::normalizeTitle(t.UTF8String ?: ""));
            auto all = remote;
            all.push_back(std::move(titlesNorm));
            [self confirmCandidates:cands index:i + 1 remote:std::move(all) userTitles:user name:name key:key];
        });
    }];
}

// Step 4: download + persist.
- (void)downloadPhotoUrl:(const std::string &)urlString name:(NSString *)name key:(NSString *)key {
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:urlString.c_str()]];
    if (!url) { [self fallbackForName:name key:key cacheResult:NO]; return; }
    [[SVDeezerClient shared] downloadImageAtURL:url completion:^(NSData *data) {
        NSImage *img = DecodeImage(data);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!img) { [self fallbackForName:name key:key cacheResult:NO]; return; }
            NSURL *dest = [self photoURLForKey:key];
            dispatch_async(self->_diskQueue, ^{ [data writeToURL:dest atomically:YES]; });
            [self finishKey:key name:name source:img cache:YES];
        });
    }];
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
