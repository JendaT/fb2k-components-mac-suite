//
//  HTTPResponsePolicy.mm
//  foo_jl_tidal_mac
//

#import "HTTPResponsePolicy.h"
#include <math.h>

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
    return [self decisionForStatusCode:statusCode
                      retryAfterHeader:retryAfterHeader
                             subStatus:0
                           userMessage:nil
                               isRetry:isRetry];
}

// TIDAL sub-statuses that genuinely mean "your plan does not cover this".
// Everything else on a 403 is a different refusal.
static BOOL isSubscriptionSubStatus(NSInteger subStatus) {
    return subStatus == 4033 || subStatus == 3001 || subStatus == 3002;
}

+ (JLTidalHTTPDecision *)decisionForStatusCode:(NSInteger)statusCode
                              retryAfterHeader:(NSString *)retryAfterHeader
                                     subStatus:(NSInteger)subStatus
                                   userMessage:(NSString *)userMessage
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
        // No sub-status in the body: keep the historical reading so the quality
        // cascade behaves as before. With one, only the subscription codes earn
        // a cascade; a geo-block or a quota is reported as what it is.
        if (subStatus != 0 && !isSubscriptionSubStatus(subStatus)) {
            return decision(JLTidalHTTPActionFail, JLTidalErrorAccessDenied,
                            userMessage.length > 0
                                ? userMessage
                                : [NSString stringWithFormat:@"Access denied (subStatus %ld)", (long)subStatus],
                            0);
        }
        return decision(JLTidalHTTPActionFail, JLTidalErrorSubscriptionRequired,
                        userMessage.length > 0 ? userMessage : @"Subscription required", 0);
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

+ (BOOL)shouldRetryMethod:(NSString *)method
                  attempt:(NSInteger)attempt
          transportFailed:(BOOL)transportFailed
               statusCode:(NSInteger)statusCode {
    if (attempt >= kTidalMaxRequestAttempts - 1) return NO;

    // Idempotent methods only. GET and HEAD can be repeated safely; a repeated
    // POST/DELETE can duplicate or re-apply a mutation whose first attempt may
    // well have reached the server.
    BOOL idempotent = [method isEqualToString:@"GET"] || [method isEqualToString:@"HEAD"];
    if (!idempotent) return NO;

    if (transportFailed) return YES;
    return statusCode == 429 || (statusCode >= 500 && statusCode < 600);
}

+ (NSTimeInterval)retryDelayForAttempt:(NSInteger)attempt
                     retryAfterSeconds:(NSTimeInterval)retryAfterSeconds {
    if (retryAfterSeconds >= 0) {
        return MIN(retryAfterSeconds, kTidalMaxRetryAfterSeconds);
    }
    // 500 ms, 1000 ms, 2000 ms, ... capped so a raised attempt ceiling cannot
    // turn into a minutes-long stall.
    NSTimeInterval delay = 0.5 * pow(2.0, (double)MAX((NSInteger)0, attempt));
    return MIN(delay, kTidalMaxRetryAfterSeconds);
}

@end
