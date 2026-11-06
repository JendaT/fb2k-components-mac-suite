//
//  CoverArtArchiveProvider.mm
//  foo_jl_album_art_mac
//
//  Cover Art Archive provider implementation
//

#import "CoverArtArchiveProvider.h"
#import "MusicBrainzProvider.h"

static NSString *const kCAABaseURL = @"https://coverartarchive.org";
static const NSTimeInterval kCAATimeout = 30.0;

@interface CoverArtArchiveProvider ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionTask *metadataTask;

@end

@implementation CoverArtArchiveProvider

#pragma mark - Protocol Properties

- (NSString *)identifier {
    return @"caa";
}

- (NSString *)displayName {
    return @"Cover Art Archive";
}

- (BOOL)requiresAPIKey {
    return NO;
}

- (NSTimeInterval)rateLimitInterval {
    return 0;  // No rate limiting for CAA
}

- (BOOL)canSearchWithMBID {
    return YES;
}

#pragma mark - Singleton

+ (CoverArtArchiveProvider *)sharedInstance {
    static CoverArtArchiveProvider *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CoverArtArchiveProvider alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kCAATimeout;
        config.HTTPAdditionalHeaders = @{
            @"Accept": @"application/json"
        };
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

#pragma mark - ArtworkSourceProvider Protocol

- (void)searchWithMetadata:(TrackMetadata *)metadata
                completion:(ArtworkSearchCompletion)completion {

    [self resetCancelledState];

    // Network check is done by RemoteArtworkSearchController before calling providers

    // First get MBID from metadata or MusicBrainz
    [[MusicBrainzProvider sharedInstance] lookupMBIDForMetadata:metadata
        completion:^(NSString *mbid, NSError *error) {

        if (self.isCancelled) {
            return;
        }

        if (error || !mbid) {
            completion(@[], error);
            return;
        }

        // Now fetch artwork using MBID
        [self searchWithMBID:mbid completion:completion];
    }];
}

- (void)searchWithMBID:(NSString *)mbid
            completion:(ArtworkSearchCompletion)completion {

    [self resetCancelledState];

    // The MBID may originate from a file tag (MUSICBRAINZ_ALBUMID), so it is
    // untrusted. Validate it as a UUID before interpolating into the URL:
    // an invalid value would otherwise make URLWithString: return nil (and
    // dataTaskWithURL:nil throws) or inject an arbitrary path.
    if (![[NSUUID alloc] initWithUUIDString:mbid]) {
        completion(@[], [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorInvalidMetadata
                                                         message:@"Invalid MusicBrainz release ID"]);
        return;
    }

    // Build URL for release metadata
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/release/%@", kCAABaseURL, mbid]];
    if (!url) {
        completion(@[], nil);
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(@[], [ArtworkSourceProviderBase errorFromURLError:error]);
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode == 404) {
                // No artwork for this release
                completion(@[], nil);
                return;
            }

            if (httpResponse.statusCode != 200) {
                NSError *apiError = [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorAPIError
                    message:[NSString stringWithFormat:@"CAA error: %ld", (long)httpResponse.statusCode]];
                completion(@[], apiError);
                return;
            }

            // Parse JSON and create ArtworkResult objects
            NSArray<ArtworkResult *> *results = [strongSelf parseArtworkFromData:data mbid:mbid];
            completion(results, nil);
        });
    }];

    self.metadataTask = task;
    [task resume];
}

- (void)cancel {
    [super cancel];
    [self.metadataTask cancel];
    self.metadataTask = nil;
    [[MusicBrainzProvider sharedInstance] cancel];
}

#pragma mark - Response Parsing

- (NSArray<ArtworkResult *> *)parseArtworkFromData:(NSData *)data mbid:(NSString *)mbid {
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSArray *images = json[@"images"];
    if (![images isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<ArtworkResult *> *results = [NSMutableArray array];

    for (NSDictionary *imageDict in images) {
        if (![imageDict isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        ArtworkResult *result = [self artworkResultFromDict:imageDict];
        if (result) {
            [results addObject:result];
        }
    }

    return [results copy];
}

- (nullable ArtworkResult *)artworkResultFromDict:(NSDictionary *)dict {
    // Get URLs
    NSString *imageURL = dict[@"image"];
    NSDictionary *thumbnails = dict[@"thumbnails"];

    if (![imageURL isKindOfClass:[NSString class]] || imageURL.length == 0) {
        return nil;
    }

    // Get best thumbnail (prefer 500px, fall back to 250px or large)
    NSString *thumbnailURL = nil;
    if ([thumbnails isKindOfClass:[NSDictionary class]]) {
        thumbnailURL = thumbnails[@"500"] ?: thumbnails[@"250"] ?: thumbnails[@"large"];
    }
    if (![thumbnailURL isKindOfClass:[NSString class]]) {
        thumbnailURL = imageURL;  // Use full image as thumbnail
    }

    // Parse types array
    NSArray *types = dict[@"types"];
    RemoteArtworkType artworkType = RemoteArtworkTypeFront;
    NSMutableArray<NSString *> *variants = [NSMutableArray array];

    if ([types isKindOfClass:[NSArray class]]) {
        for (NSString *type in types) {
            if (![type isKindOfClass:[NSString class]]) continue;

            NSString *lowercaseType = [type lowercaseString];

            // Primary type detection
            if ([lowercaseType isEqualToString:@"front"]) {
                artworkType = RemoteArtworkTypeFront;
            } else if ([lowercaseType isEqualToString:@"back"]) {
                artworkType = RemoteArtworkTypeBack;
            } else if ([lowercaseType isEqualToString:@"medium"] ||
                       [lowercaseType containsString:@"disc"] ||
                       [lowercaseType containsString:@"cd"]) {
                artworkType = RemoteArtworkTypeDisc;
            } else if ([lowercaseType isEqualToString:@"booklet"]) {
                artworkType = RemoteArtworkTypeBooklet;
            } else if ([lowercaseType containsString:@"poster"] ||
                       [lowercaseType containsString:@"liner"] ||
                       [lowercaseType containsString:@"obi"] ||
                       [lowercaseType containsString:@"sticker"]) {
                // These are variants, not primary types
                [variants addObject:type];
            }
        }
    }

    // Check for comment (variant description like "Vinyl", "Limited Edition")
    NSString *comment = dict[@"comment"];
    if ([comment isKindOfClass:[NSString class]] && comment.length > 0) {
        [variants addObject:comment];
    }

    // Resolution is not provided by CAA API - will be unknown until downloaded
    CGSize resolution = CGSizeZero;

    return [[ArtworkResult alloc] initWithSourceIdentifier:self.identifier
                                                sourceName:self.displayName
                                              thumbnailURL:[NSURL URLWithString:thumbnailURL]
                                         fullResolutionURL:[NSURL URLWithString:imageURL]
                                                resolution:resolution
                                               artworkType:artworkType
                                                 imageHash:nil
                                                  variants:variants.count > 0 ? variants : nil];
}

@end
