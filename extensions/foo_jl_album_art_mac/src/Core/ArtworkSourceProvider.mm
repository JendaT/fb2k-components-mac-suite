//
//  ArtworkSourceProvider.mm
//  foo_jl_album_art_mac
//
//  Base implementation for artwork source providers
//

#import "ArtworkSourceProvider.h"
#import "../../../../shared/RateLimiter.h"
#import "../../../../shared/NetworkReachability.h"

@implementation ArtworkSourceProviderBase {
    // Written by -cancel on the main thread, read from NSURLSession
    // completion handlers on background threads
    _Atomic(BOOL) _cancelled;
}

#pragma mark - Shared Session

+ (NSURLSession *)sharedSession {
    static NSURLSession *session = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30.0;
        config.timeoutIntervalForResource = 60.0;
        config.waitsForConnectivity = NO;
        session = [NSURLSession sessionWithConfiguration:config];
    });
    return session;
}

#pragma mark - Protocol Stubs (Override in Subclass)

- (NSString *)identifier {
    [NSException raise:NSInternalInconsistencyException
                format:@"Subclass must override %@", NSStringFromSelector(_cmd)];
    return nil;
}

- (NSString *)displayName {
    [NSException raise:NSInternalInconsistencyException
                format:@"Subclass must override %@", NSStringFromSelector(_cmd)];
    return nil;
}

- (BOOL)requiresAPIKey {
    return NO;  // Default: no API key required
}

- (NSTimeInterval)rateLimitInterval {
    return 0;  // Default: no rate limiting
}

- (void)searchWithMetadata:(TrackMetadata *)metadata
                completion:(ArtworkSearchCompletion)completion {
    [NSException raise:NSInternalInconsistencyException
                format:@"Subclass must override %@", NSStringFromSelector(_cmd)];
}

- (void)cancel {
    _cancelled = YES;
    [self.currentTask cancel];
    self.currentTask = nil;
}

#pragma mark - State Management

- (BOOL)isCancelled {
    return _cancelled;
}

- (void)resetCancelledState {
    _cancelled = NO;
}

#pragma mark - Error Helpers

+ (NSError *)errorWithCode:(ArtworkFetchError)code message:(NSString *)message {
    return [NSError errorWithDomain:ArtworkFetchErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (NSError *)errorFromURLError:(NSError *)urlError {
    if ([urlError.domain isEqualToString:NSURLErrorDomain]) {
        switch (urlError.code) {
            case NSURLErrorTimedOut:
                return [self errorWithCode:ArtworkFetchErrorTimeout
                                   message:@"Request timed out"];

            case NSURLErrorNotConnectedToInternet:
            case NSURLErrorNetworkConnectionLost:
                return [self errorWithCode:ArtworkFetchErrorNetworkUnavailable
                                   message:@"Network unavailable"];

            default:
                break;
        }
    }

    return [self errorWithCode:ArtworkFetchErrorAPIError
                       message:urlError.localizedDescription];
}

#pragma mark - User Agent

+ (NSString *)userAgentString {
    static NSString *userAgent = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *appName = bundle.infoDictionary[@"CFBundleName"] ?: @"foobar2000-albumart";
        NSString *version = bundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";
        // MusicBrainz requires contact info in User-Agent
        userAgent = [NSString stringWithFormat:@"%@/%@ (https://github.com/foo-plugins)", appName, version];
    });
    return userAgent;
}

#pragma mark - Request Execution

- (void)executeRequest:(NSURLRequest *)request
            completion:(void(^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completion {

    // Check network availability
    if (![[JLNetworkReachability sharedInstance] isReachable]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, nil, [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorNetworkUnavailable
                                                                  message:@"Network unavailable"]);
        });
        return;
    }

    // Check cancelled
    if (self.isCancelled) {
        return;
    }

    // Apply rate limiting if configured
    if (self.rateLimiter) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // Wait for rate limit token (blocking)
            [self.rateLimiter acquireWithTimeout:30.0];

            if (self.isCancelled) {
                return;
            }

            [self performRequest:request completion:completion];
        });
    } else {
        [self performRequest:request completion:completion];
    }
}

- (void)performRequest:(NSURLRequest *)request
            completion:(void(^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completion {

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [[ArtworkSourceProviderBase sharedSession]
        dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.isCancelled) {
                return;
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (error) {
                    completion(nil, nil, [ArtworkSourceProviderBase errorFromURLError:error]);
                } else {
                    completion(data, response, nil);
                }
            });
        }];

    self.currentTask = task;
    [task resume];
}

@end
