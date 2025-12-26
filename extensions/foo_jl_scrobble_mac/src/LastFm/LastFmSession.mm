//
//  LastFmSession.mm
//  foo_scrobble_mac
//
//  Last.fm session implementation
//

#import "LastFmSession.h"

@implementation LastFmSession

#pragma mark - Initialization

- (instancetype)initWithSessionKey:(NSString*)sessionKey
                          username:(NSString*)username
                      isSubscriber:(BOOL)isSubscriber {
    self = [super init];
    if (self) {
        _sessionKey = [sessionKey copy];
        _username = [username copy];
        _isSubscriber = isSubscriber;
    }
    return self;
}

+ (instancetype)sessionFromResponse:(NSDictionary*)response {
    // Response format: { "session": { "name": "...", "key": "...", "subscriber": 0/1 } }
    NSDictionary* session = response[@"session"];
    if (![session isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString* key = session[@"key"];
    NSString* name = session[@"name"];
    NSNumber* subscriber = session[@"subscriber"];

    if (![key isKindOfClass:[NSString class]] || key.length == 0) {
        return nil;
    }
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        return nil;
    }

    BOOL isSubscriber = [subscriber isKindOfClass:[NSNumber class]] && subscriber.boolValue;

    return [[LastFmSession alloc] initWithSessionKey:key
                                            username:name
                                        isSubscriber:isSubscriber];
}

- (BOOL)isValid {
    return _sessionKey.length > 0;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)initWithCoder:(NSCoder*)coder {
    NSString* sessionKey = [coder decodeObjectOfClass:[NSString class] forKey:@"sessionKey"];
    NSString* username = [coder decodeObjectOfClass:[NSString class] forKey:@"username"];
    BOOL isSubscriber = [coder decodeBoolForKey:@"isSubscriber"];

    if (!sessionKey || !username) {
        return nil;
    }

    return [self initWithSessionKey:sessionKey username:username isSubscriber:isSubscriber];
}

- (void)encodeWithCoder:(NSCoder*)coder {
    [coder encodeObject:_sessionKey forKey:@"sessionKey"];
    [coder encodeObject:_username forKey:@"username"];
    [coder encodeBool:_isSubscriber forKey:@"isSubscriber"];
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone*)zone {
    // Immutable, so return self
    return self;
}

#pragma mark - NSObject

- (NSString*)description {
    return [NSString stringWithFormat:@"<LastFmSession: %@ (subscriber: %@)>",
            _username,
            _isSubscriber ? @"yes" : @"no"];
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[LastFmSession class]]) return NO;

    LastFmSession* other = (LastFmSession*)object;
    return [_sessionKey isEqualToString:other.sessionKey];
}

- (NSUInteger)hash {
    return _sessionKey.hash;
}

@end
