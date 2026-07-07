//
//  TidalSessionTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for OAuth session expiry/refresh-window math.
//

#import <Foundation/Foundation.h>
#import "../src/API/TidalSession.h"
#include "TestHarness.h"

static void testFreshSession(void) {
    JLTidalSession *s = [[JLTidalSession alloc] initWithAccessToken:@"tok"
                                                       refreshToken:@"ref"
                                                          expiresIn:3600];
    CHECK(!s.isExpired, "1h session not expired");
    CHECK(!s.needsRefresh, "1h session outside refresh buffer");
    CHECK(s.isValid, "1h session valid");
}

static void testNearExpiry(void) {
    // Inside the 5-minute refresh buffer but not yet expired
    JLTidalSession *s = [[JLTidalSession alloc] initWithAccessToken:@"tok"
                                                       refreshToken:@"ref"
                                                          expiresIn:100];
    CHECK(!s.isExpired, "100s session not yet expired");
    CHECK(s.needsRefresh, "100s session needs refresh (5min buffer)");
    CHECK(s.isValid, "100s session still valid");
}

static void testExpired(void) {
    JLTidalSession *s = [[JLTidalSession alloc] initWithAccessToken:@"tok"
                                                       refreshToken:@"ref"
                                                          expiresIn:-10];
    CHECK(s.isExpired, "past-expiry session expired");
    CHECK(s.needsRefresh, "expired session needs refresh");
    CHECK(!s.isValid, "expired session invalid");
}

static void testEmptyToken(void) {
    JLTidalSession *s = [[JLTidalSession alloc] initWithAccessToken:@""
                                                       refreshToken:@"ref"
                                                          expiresIn:3600];
    CHECK(!s.isValid, "empty access token invalid even when unexpired");
}

static void testTokenUpdatePreservesIdentity(void) {
    JLTidalSession *s = [[JLTidalSession alloc] initWithAccessToken:@"old"
                                                       refreshToken:@"ref"
                                                          expiresIn:-10
                                                             userId:@"u1"
                                                           username:@"jenda"
                                                        countryCode:@"CZ"];
    JLTidalSession *updated = [s sessionByUpdatingAccessToken:@"new" expiresIn:3600];
    CHECK_STREQ(updated.accessToken, @"new", "access token replaced");
    CHECK_STREQ(updated.refreshToken, @"ref", "refresh token preserved");
    CHECK_STREQ(updated.userId, @"u1", "userId preserved");
    CHECK_STREQ(updated.username, @"jenda", "username preserved");
    CHECK_STREQ(updated.countryCode, @"CZ", "countryCode preserved");
    CHECK(updated.isValid, "updated session valid");
    CHECK(!s.isValid, "original session untouched (immutable)");
}

int main(void) {
    @autoreleasepool {
        testFreshSession();
        testNearExpiry();
        testExpired();
        testEmptyToken();
        testTokenUpdatePreservesIdentity();
    }
    return testHarnessFinish("TidalSession");
}
