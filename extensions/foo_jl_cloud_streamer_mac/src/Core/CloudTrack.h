//
//  CloudTrack.h
//  foo_jl_cloud_streamer_mac
//
//  Track model for cloud search results
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CloudTrack : NSObject

@property (nonatomic, copy) NSString* title;
@property (nonatomic, copy) NSString* artist;
@property (nonatomic, copy) NSString* webURL;
@property (nonatomic, copy) NSString* internalURL;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, copy) NSString* trackId;
@property (nonatomic, copy, nullable) NSString* thumbnailURL;

// Convenience initializer
- (instancetype)initWithTitle:(NSString*)title
                       artist:(NSString*)artist
                       webURL:(NSString*)webURL
                     duration:(NSTimeInterval)duration
                      trackId:(NSString*)trackId
                 thumbnailURL:(nullable NSString*)thumbnailURL;

// Formatted duration string (e.g., "3:45")
- (NSString*)formattedDuration;

// Generate internal URL from web URL (soundcloud://...)
- (void)generateInternalURL;

@end

NS_ASSUME_NONNULL_END
