//
//  TidalSession.mm
//  foo_jl_tidal_mac
//
//  OAuth token container implementation
//

#import "TidalSession.h"

@implementation JLTidalSession

- (instancetype)initWithAccessToken:(NSString *)accessToken
                       refreshToken:(NSString *)refreshToken
                          expiresIn:(NSTimeInterval)expiresIn {
    return [self initWithAccessToken:accessToken
                        refreshToken:refreshToken
                           expiresIn:expiresIn
                              userId:nil
                            username:nil
                         countryCode:nil];
}

- (instancetype)initWithAccessToken:(NSString *)accessToken
                       refreshToken:(NSString *)refreshToken
                          expiresIn:(NSTimeInterval)expiresIn
                             userId:(NSString *)userId
                           username:(NSString *)username
                        countryCode:(NSString *)countryCode {
    self = [super init];
    if (self) {
        _accessToken = [accessToken copy];
        _refreshToken = [refreshToken copy];
        _expiryDate = [NSDate dateWithTimeIntervalSinceNow:expiresIn];
        _userId = [userId copy];
        _username = [username copy];
        _countryCode = [countryCode copy];
    }
    return self;
}

- (BOOL)isExpired {
    return [self.expiryDate compare:[NSDate date]] != NSOrderedDescending;
}

- (BOOL)needsRefresh {
    // Refresh if token will expire within buffer time
    NSDate *bufferDate = [NSDate dateWithTimeIntervalSinceNow:kTidalTokenRefreshBuffer];
    return [self.expiryDate compare:bufferDate] != NSOrderedDescending;
}

- (BOOL)isValid {
    return self.accessToken.length > 0 && !self.isExpired;
}

- (JLTidalSession *)sessionByUpdatingAccessToken:(NSString *)newAccessToken
                                       expiresIn:(NSTimeInterval)expiresIn {
    return [[JLTidalSession alloc] initWithAccessToken:newAccessToken
                                          refreshToken:self.refreshToken
                                             expiresIn:expiresIn
                                                userId:self.userId
                                              username:self.username
                                           countryCode:self.countryCode];
}

@end
