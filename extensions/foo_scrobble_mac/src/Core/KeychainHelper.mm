//
//  KeychainHelper.mm
//  foo_scrobble_mac
//
//  Secure storage for Last.fm session key using macOS Keychain
//

#import "KeychainHelper.h"
#import <Security/Security.h>

static NSString * const kServiceName = @"com.foobar2000.foo_scrobble_mac";
static NSString * const kUsernameKey = @"foo_scrobble.username";

@implementation KeychainHelper

+ (BOOL)setSessionKey:(NSString *)sessionKey forUsername:(NSString *)username {
    if (!sessionKey || !username) {
        return NO;
    }

    // Delete existing first
    [self deleteCredentials];

    // Store session key
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kServiceName,
        (__bridge id)kSecAttrAccount: username,
        (__bridge id)kSecValueData: [sessionKey dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
    };

    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);

    if (status == errSecSuccess) {
        // Also store username in UserDefaults for easy retrieval
        [[NSUserDefaults standardUserDefaults] setObject:username forKey:kUsernameKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return YES;
    }

    return NO;
}

+ (nullable NSString *)sessionKeyForUsername:(NSString *)username {
    if (!username) {
        return nil;
    }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kServiceName,
        (__bridge id)kSecAttrAccount: username,
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

+ (nullable NSString *)storedUsername {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kUsernameKey];
}

+ (BOOL)deleteCredentials {
    // Delete from Keychain
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kServiceName,
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);

    // Also remove username from UserDefaults
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kUsernameKey];
    [[NSUserDefaults standardUserDefaults] synchronize];

    return status == errSecSuccess || status == errSecItemNotFound;
}

#pragma mark - Generic Password API

+ (BOOL)savePassword:(NSString *)password forAccount:(NSString *)account {
    if (!password || !account) {
        return NO;
    }

    // Delete existing first
    [self deletePassword:account];

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kServiceName,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecValueData: [password dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
    };

    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    return status == errSecSuccess;
}

+ (nullable NSString *)loadPassword:(NSString *)account {
    if (!account) {
        return nil;
    }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kServiceName,
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

+ (BOOL)deletePassword:(NSString *)account {
    if (!account) {
        return NO;
    }

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kServiceName,
        (__bridge id)kSecAttrAccount: account,
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess || status == errSecItemNotFound;
}

@end
