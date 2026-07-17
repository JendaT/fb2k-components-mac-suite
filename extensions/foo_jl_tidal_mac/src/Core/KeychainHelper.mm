//
//  KeychainHelper.mm
//  foo_jl_tidal_mac
//
//  Secure storage for Tidal OAuth tokens using macOS Keychain
//

#import "KeychainHelper.h"
#import "TidalLog.h"
#import "../API/TidalConstants.h"
#import <Security/Security.h>

// UserDefaults keys (not secret, can be in defaults)
static NSString * const kTokenExpiryKey = @"com.foobar2000.tidal.token_expiry";
static NSString * const kUserIdKey = @"com.foobar2000.tidal.user_id";
static NSString * const kUsernameKey = @"com.foobar2000.tidal.username";
static NSString * const kCountryCodeKey = @"com.foobar2000.tidal.country_code";

@implementation JLTidalKeychainHelper

#pragma mark - Private Helpers

+ (BOOL)storeValue:(NSString *)value forAccount:(NSString *)account {
    if (!value || !account) {
        return NO;
    }

    // Delete existing first
    [self deleteValueForAccount:account];

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kTidalKeychainService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
    };

    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    if (status != errSecSuccess) {
        tidal::logError([[NSString stringWithFormat:@"Keychain: SecItemAdd failed for account %@ (OSStatus %d)",
                          account, (int)status] UTF8String]);
    }
    return status == errSecSuccess;
}

+ (nullable NSString *)loadValueForAccount:(NSString *)account {
    if (!account) {
        return nil;
    }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kTidalKeychainService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };

    CFDataRef dataRef = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&dataRef);

    if (status == errSecSuccess && dataRef) {
        NSData *data = (__bridge_transfer NSData *)dataRef;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }

    return nil;
}

+ (BOOL)deleteValueForAccount:(NSString *)account {
    if (!account) {
        return NO;
    }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kTidalKeychainService,
        (__bridge id)kSecAttrAccount: account,
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess || status == errSecItemNotFound;
}

#pragma mark - Token Storage

+ (BOOL)storeAccessToken:(NSString *)token {
    return [self storeValue:token forAccount:kTidalKeychainAccessTokenKey];
}

+ (nullable NSString *)loadAccessToken {
    return [self loadValueForAccount:kTidalKeychainAccessTokenKey];
}

+ (BOOL)storeRefreshToken:(NSString *)token {
    return [self storeValue:token forAccount:kTidalKeychainRefreshTokenKey];
}

+ (nullable NSString *)loadRefreshToken {
    return [self loadValueForAccount:kTidalKeychainRefreshTokenKey];
}

+ (BOOL)deleteAllTokens {
    BOOL accessDeleted = [self deleteValueForAccount:kTidalKeychainAccessTokenKey];
    BOOL refreshDeleted = [self deleteValueForAccount:kTidalKeychainRefreshTokenKey];

    // Also clear expiry and user profile from UserDefaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:kTokenExpiryKey];
    [defaults removeObjectForKey:kUserIdKey];
    [defaults removeObjectForKey:kUsernameKey];
    [defaults removeObjectForKey:kCountryCodeKey];

    return accessDeleted && refreshDeleted;
}

#pragma mark - Token Expiry

+ (void)storeTokenExpiry:(NSDate *)expiryDate {
    [[NSUserDefaults standardUserDefaults] setObject:expiryDate forKey:kTokenExpiryKey];
}

+ (nullable NSDate *)loadTokenExpiry {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kTokenExpiryKey];
}

+ (BOOL)isAccessTokenExpired {
    NSDate *expiry = [self loadTokenExpiry];
    if (!expiry) {
        return YES;  // No expiry stored, assume expired
    }

    // Add refresh buffer - refresh before actual expiry
    NSDate *bufferDate = [NSDate dateWithTimeIntervalSinceNow:kTidalTokenRefreshBuffer];
    return [expiry compare:bufferDate] != NSOrderedDescending;
}

+ (BOOL)hasStoredCredentials {
    NSString *accessToken = [self loadAccessToken];
    NSString *refreshToken = [self loadRefreshToken];
    return (accessToken != nil || refreshToken != nil);
}

#pragma mark - User Profile

+ (void)storeUserId:(nullable NSString *)userId {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (userId) {
        [defaults setObject:userId forKey:kUserIdKey];
    } else {
        [defaults removeObjectForKey:kUserIdKey];
    }
}

+ (void)storeUsername:(nullable NSString *)username {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (username) {
        [defaults setObject:username forKey:kUsernameKey];
    } else {
        [defaults removeObjectForKey:kUsernameKey];
    }
}

+ (void)storeCountryCode:(nullable NSString *)countryCode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (countryCode) {
        [defaults setObject:countryCode forKey:kCountryCodeKey];
    } else {
        [defaults removeObjectForKey:kCountryCodeKey];
    }
}

+ (nullable NSString *)loadUserId {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kUserIdKey];
}

+ (nullable NSString *)loadUsername {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kUsernameKey];
}

+ (nullable NSString *)loadCountryCode {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kCountryCodeKey];
}

@end
