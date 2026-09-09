//
//  HTTPResponsePolicy.mm
//  foo_jl_tidal_mac
//

#import "HTTPResponsePolicy.h"

@interface JLTidalHTTPDecision ()
- (instancetype)initWithAction:(JLTidalHTTPAction)action
                     errorCode:(JLTidalErrorCode)errorCode
                       message:(NSString *)message
             retryAfterSeconds:(NSTimeInterval)retryAfterSeconds;
@end

@implementation JLTidalHTTPDecision

- (instancetype)initWithAction:(JLTidalHTTPAction)action
                     errorCode:(JLTidalErrorCode)errorCode
                       message:(NSString *)message
             retryAfterSeconds:(NSTimeInterval)retryAfterSeconds {
    self = [super init];
    if (self) {
        _action = action;
        _errorCode = errorCode;
        _message = [message copy];
        _retryAfterSeconds = retryAfterSeconds;
    }
    return self;
}

@end

static JLTidalHTTPDecision *decision(JLTidalHTTPAction action,
                                     JLTidalErrorCode errorCode,
                                     NSString *message,
                                     NSTimeInterval retryAfterSeconds) {
    return [[JLTidalHTTPDecision alloc] initWithAction:action
                                              errorCode:errorCode
                                                message:message
                                      retryAfterSeconds:retryAfterSeconds];
}

@implementation JLTidalHTTPResponsePolicy

+ (JLTidalHTTPDecision *)decisionForStatusCode:(NSInteger)statusCode
                              retryAfterHeader:(NSString *)retryAfterHeader
                                       isRetry:(BOOL)isRetry {
    // Rate limiting (RFC 6585). Retry-After <= 0 or unparsable clamps to 1s;
    // absent header -> -1 (caller applies its own exponential backoff).
    if (statusCode == 429) {
        NSTimeInterval retryAfter = -1;
        if (retryAfterHeader.length > 0) {
            retryAfter = [retryAfterHeader doubleValue];
            if (retryAfter <= 0) retryAfter = 1.0;
        }
        return decision(JLTidalHTTPActionRateLimited, JLTidalErrorRateLimited, nil, retryAfter);
    }

    // Auth: attempt token refresh + retry on first 401 only.
    if (statusCode == 401) {
        if (!isRetry) {
            return decision(JLTidalHTTPActionRetryAuth, JLTidalErrorNotAuthenticated, nil, 0);
        }
        return decision(JLTidalHTTPActionFail, JLTidalErrorNotAuthenticated,
                        @"Authentication required", 0);
    }

    if (statusCode == 403) {
        return decision(JLTidalHTTPActionFail, JLTidalErrorSubscriptionRequired,
                        @"Subscription required", 0);
    }

    if (statusCode == 404) {
        return decision(JLTidalHTTPActionFail, JLTidalErrorTrackNotFound,
                        @"Track not found", 0);
    }

    if (statusCode >= 500) {
        return decision(JLTidalHTTPActionFail, JLTidalErrorServerError,
                        [NSString stringWithFormat:@"Server error: HTTP %ld", (long)statusCode], 0);
    }

    // Accept 200 (OK), 201 (Created), 204 (No Content)
    if (statusCode != 200 && statusCode != 201 && statusCode != 204) {
        return decision(JLTidalHTTPActionFail, JLTidalErrorInvalidResponse,
                        [NSString stringWithFormat:@"Unexpected status: HTTP %ld", (long)statusCode], 0);
    }

    return decision(JLTidalHTTPActionSuccess, JLTidalErrorInternal, nil, 0);
}

@end
