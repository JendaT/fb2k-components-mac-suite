//
//  BiographyRequest.mm
//  foo_jl_biography_mac
//
//  Cancellation token for in-flight requests
//

#import "BiographyRequest.h"

@implementation BiographyRequest {
    BOOL _cancelled;
}

- (instancetype)initWithArtistName:(NSString *)artistName {
    self = [super init];
    if (self) {
        _artistName = [artistName copy];
        _startedAt = [NSDate date];
        _requestId = [[NSUUID UUID] UUIDString];
        _cancelled = NO;
    }
    return self;
}

- (BOOL)isCancelled {
    @synchronized (self) {
        return _cancelled;
    }
}

- (void)cancel {
    @synchronized (self) {
        _cancelled = YES;
    }
}

- (NSTimeInterval)elapsedTime {
    return [[NSDate date] timeIntervalSinceDate:self.startedAt];
}

- (BOOL)hasTimedOutWithTimeout:(NSTimeInterval)timeout {
    return self.elapsedTime > timeout;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<BiographyRequest: %@ (%@, %@)>",
            self.artistName,
            self.requestId,
            self.isCancelled ? @"cancelled" : @"active"];
}

@end
