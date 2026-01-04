//
//  CloudTrack.mm
//  foo_jl_cloud_streamer_mac
//
//  Track model for cloud search results
//

#import "CloudTrack.h"
#include "URLUtils.h"

@implementation CloudTrack

- (instancetype)initWithTitle:(NSString*)title
                       artist:(NSString*)artist
                       webURL:(NSString*)webURL
                     duration:(NSTimeInterval)duration
                      trackId:(NSString*)trackId
                 thumbnailURL:(NSString*)thumbnailURL {
    self = [super init];
    if (self) {
        _title = [title copy];
        _artist = [artist copy];
        _webURL = [webURL copy];
        _duration = duration;
        _trackId = [trackId copy];
        _thumbnailURL = [thumbnailURL copy];
        _internalURL = @"";
        [self generateInternalURL];
    }
    return self;
}

- (NSString*)formattedDuration {
    if (_duration <= 0) {
        return @"--:--";
    }

    NSInteger totalSeconds = (NSInteger)_duration;
    NSInteger hours = totalSeconds / 3600;
    NSInteger minutes = (totalSeconds % 3600) / 60;
    NSInteger seconds = totalSeconds % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)seconds];
    } else {
        return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
    }
}

- (void)generateInternalURL {
    if (_webURL.length == 0) {
        _internalURL = @"";
        return;
    }

    std::string webURLStr = std::string([_webURL UTF8String]);

    // Convert web URL to internal scheme
    std::string internalStr = cloud_streamer::URLUtils::webURLToInternalScheme(webURLStr);
    if (!internalStr.empty()) {
        _internalURL = [NSString stringWithUTF8String:internalStr.c_str()];
    } else {
        // Fallback to web URL if conversion fails
        _internalURL = _webURL;
    }
}

@end
