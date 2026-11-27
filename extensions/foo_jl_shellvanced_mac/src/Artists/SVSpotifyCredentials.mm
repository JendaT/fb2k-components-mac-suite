//
//  SVSpotifyCredentials.mm
//  foo_jl_shellvanced_mac
//

#import "SVSpotifyCredentials.h"
#import <Security/Security.h>

static NSString *const kService = @"foo_jl_shellvanced.spotify";
static NSString *const kAccountId = @"client_id";
static NSString *const kAccountSecret = @"client_secret";

static NSLock *Lock(void) {
    static NSLock *l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [[NSLock alloc] init]; });
    return l;
}

static NSString *gId, *gSecret;
static BOOL gLoaded;

static NSString *Load(NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFDataRef ref = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&ref) != errSecSuccess || !ref) return nil;
    NSData *data = (__bridge_transfer NSData *)ref;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static void Delete(NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
}

static BOOL Store(NSString *account, NSString *value) {
    Delete(account);
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
    };
    return SecItemAdd((__bridge CFDictionaryRef)query, NULL) == errSecSuccess;
}

// Lock held.
static void EnsureLoaded(void) {
    if (gLoaded) return;
    gId = Load(kAccountId);
    gSecret = Load(kAccountSecret);
    gLoaded = YES;
}

@implementation SVSpotifyCredentials

+ (NSString *)clientId {
    [Lock() lock]; EnsureLoaded(); NSString *v = gId; [Lock() unlock];
    return v;
}

+ (NSString *)clientSecret {
    [Lock() lock]; EnsureLoaded(); NSString *v = gSecret; [Lock() unlock];
    return v;
}

+ (BOOL)isConfigured {
    [Lock() lock]; EnsureLoaded();
    BOOL ok = gId.length > 0 && gSecret.length > 0;
    [Lock() unlock];
    return ok;
}

+ (BOOL)saveClientId:(NSString *)clientId secret:(NSString *)secret {
    NSString *i = [clientId stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *s = [secret stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [Lock() lock];
    BOOL ok = YES;
    if (i.length == 0 && s.length == 0) {
        Delete(kAccountId);
        Delete(kAccountSecret);
        gId = nil; gSecret = nil;
    } else {
        ok = Store(kAccountId, i ?: @"") && Store(kAccountSecret, s ?: @"");
        gId = i; gSecret = s;
    }
    gLoaded = YES;
    [Lock() unlock];
    return ok;
}

@end
