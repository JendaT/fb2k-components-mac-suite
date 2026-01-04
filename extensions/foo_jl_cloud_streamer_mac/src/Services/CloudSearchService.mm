//
//  CloudSearchService.mm
//  foo_jl_cloud_streamer_mac
//
//  Async search service for SoundCloud track search
//

#import "CloudSearchService.h"
#import "../Core/CloudTrack.h"
#include "YtDlpWrapper.h"
#include <atomic>

NSString* const CloudSearchErrorDomain = @"com.jendalen.cloudsearch";

@interface CloudSearchService ()
@property (nonatomic, strong) dispatch_queue_t searchQueue;
@property (atomic, assign) BOOL isSearching;
@end

@implementation CloudSearchService {
    std::atomic<bool> _abortFlag;
}

+ (instancetype)shared {
    static CloudSearchService* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CloudSearchService alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _searchQueue = dispatch_queue_create("com.jendalen.cloudsearch", DISPATCH_QUEUE_SERIAL);
        _isSearching = NO;
        _abortFlag.store(false);
    }
    return self;
}

- (void)searchTracks:(NSString*)query
         bypassCache:(BOOL)bypassCache
          completion:(CloudSearchCompletion)completion {

    if (query.length == 0) {
        if (completion) {
            NSError* error = [NSError errorWithDomain:CloudSearchErrorDomain
                                                 code:CloudSearchErrorNoResults
                                             userInfo:@{NSLocalizedDescriptionKey: @"Empty search query"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
        }
        return;
    }

    // Cancel any existing search
    [self cancelSearch];

    self.isSearching = YES;
    _abortFlag.store(false);

    // Capture abort flag pointer for block
    std::atomic<bool>* abortFlagPtr = &_abortFlag;
    NSString* searchQuery = [query copy];

    __weak typeof(self) weakSelf = self;

    dispatch_async(self.searchQueue, ^{
        @autoreleasepool {
            // Check if cancelled before starting
            if (abortFlagPtr->load()) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf) {
                        strongSelf.isSearching = NO;
                    }
                    if (completion) {
                        NSError* error = [NSError errorWithDomain:CloudSearchErrorDomain
                                                             code:CloudSearchErrorCancelled
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Search cancelled"}];
                        completion(nil, error);
                    }
                });
                return;
            }

            // Perform search
            cloud_streamer::YtDlpWrapper& wrapper = cloud_streamer::YtDlpWrapper::shared();
            cloud_streamer::YtDlpSearchResult result = wrapper.search(
                std::string([searchQuery UTF8String]),
                50,  // Max results
                abortFlagPtr,
                30   // Timeout in seconds
            );

            // Check if cancelled during search
            if (abortFlagPtr->load()) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf) {
                        strongSelf.isSearching = NO;
                    }
                    if (completion) {
                        NSError* error = [NSError errorWithDomain:CloudSearchErrorDomain
                                                             code:CloudSearchErrorCancelled
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Search cancelled"}];
                        completion(nil, error);
                    }
                });
                return;
            }

            // Convert results to CloudTrack array
            NSMutableArray<CloudTrack*>* tracks = nil;
            NSError* error = nil;

            if (result.success) {
                tracks = [NSMutableArray arrayWithCapacity:result.entries.size()];
                for (const auto& entry : result.entries) {
                    NSString* thumbnailURL = entry.thumbnailUrl.empty() ? nil
                        : [NSString stringWithUTF8String:entry.thumbnailUrl.c_str()];
                    CloudTrack* track = [[CloudTrack alloc]
                        initWithTitle:[NSString stringWithUTF8String:entry.title.c_str()]
                               artist:[NSString stringWithUTF8String:entry.uploader.c_str()]
                               webURL:[NSString stringWithUTF8String:entry.webpageUrl.c_str()]
                             duration:entry.duration
                              trackId:[NSString stringWithUTF8String:entry.trackId.c_str()]
                         thumbnailURL:thumbnailURL];
                    [tracks addObject:track];
                }
            } else {
                // Map error code
                CloudSearchErrorCode errorCode = CloudSearchErrorYtDlpFailed;
                switch (result.error) {
                    case cloud_streamer::JLCloudError::SearchNoResults:
                        errorCode = CloudSearchErrorNoResults;
                        break;
                    case cloud_streamer::JLCloudError::SearchCancelled:
                        errorCode = CloudSearchErrorCancelled;
                        break;
                    case cloud_streamer::JLCloudError::SearchTimeout:
                        errorCode = CloudSearchErrorTimeout;
                        break;
                    case cloud_streamer::JLCloudError::NetworkError:
                        errorCode = CloudSearchErrorNetworkError;
                        break;
                    case cloud_streamer::JLCloudError::RateLimited:
                        errorCode = CloudSearchErrorRateLimited;
                        break;
                    case cloud_streamer::JLCloudError::YtDlpNotFound:
                        errorCode = CloudSearchErrorYtDlpNotFound;
                        break;
                    default:
                        errorCode = CloudSearchErrorYtDlpFailed;
                        break;
                }

                NSString* errorMessage = [NSString stringWithUTF8String:result.errorMessage.c_str()];
                if (errorMessage.length == 0) {
                    errorMessage = @"Search failed";
                }

                error = [NSError errorWithDomain:CloudSearchErrorDomain
                                            code:errorCode
                                        userInfo:@{NSLocalizedDescriptionKey: errorMessage}];
            }

            // Dispatch result on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (strongSelf) {
                    strongSelf.isSearching = NO;
                }
                if (completion) {
                    completion(tracks, error);
                }
            });
        }
    });
}

- (void)cancelSearch {
    _abortFlag.store(true);
    // Note: isSearching will be set to NO when the search completes or is cancelled
}

@end
