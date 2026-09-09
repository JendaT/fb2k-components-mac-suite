//
//  CloudSearchService.h
//  foo_jl_cloud_streamer_mac
//
//  Async search service for SoundCloud and Mixcloud track search
//

#import <Foundation/Foundation.h>

@class CloudTrack;

NS_ASSUME_NONNULL_BEGIN

// Cloud service type for search
typedef NS_ENUM(NSInteger, CloudServiceType) {
    CloudServiceTypeSoundCloud = 0,
    CloudServiceTypeMixcloud = 1
};

// Search completion block
typedef void(^CloudSearchCompletion)(NSArray<CloudTrack*>* _Nullable tracks, NSError* _Nullable error);

// Error domain for search errors
extern NSString* const CloudSearchErrorDomain;

// Error codes (matching JLCloudError)
typedef NS_ENUM(NSInteger, CloudSearchErrorCode) {
    CloudSearchErrorNoResults = 100,
    CloudSearchErrorCancelled = 101,
    CloudSearchErrorTimeout = 102,
    CloudSearchErrorNetworkError = 20,
    CloudSearchErrorRateLimited = 24,
    CloudSearchErrorYtDlpNotFound = 10,
    CloudSearchErrorYtDlpFailed = 13
};

@interface CloudSearchService : NSObject

// Singleton access
+ (instancetype)shared;

// Search for tracks on the specified service
// query: search term
// service: which cloud service to search (SoundCloud or Mixcloud)
// bypassCache: if YES, skip cache (not implemented in MVP)
// completion: called on main thread with results or error
- (void)searchTracks:(NSString*)query
             service:(CloudServiceType)service
         bypassCache:(BOOL)bypassCache
          completion:(CloudSearchCompletion)completion;

// Legacy method - searches SoundCloud by default
- (void)searchTracks:(NSString*)query
         bypassCache:(BOOL)bypassCache
          completion:(CloudSearchCompletion)completion;

// Cancel current search
// Fire-and-forget - a new search can start immediately
- (void)cancelSearch;

// Check if a search is in progress
@property (nonatomic, readonly) BOOL isSearching;

// Unavailable
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
