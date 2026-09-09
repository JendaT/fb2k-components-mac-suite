//
//  PlorgPathCodec.mm
//  foo_plorg_mac
//

#import "PlorgPathCodec.h"

NSString * const PlorgPathSeparator = @" \u00BB ";

// Single guillemet character used for escaping, and its doubled (escaped) form
static NSString *guillemet(void) {
    static NSString *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unichar c = 0x00BB;
        s = [NSString stringWithCharacters:&c length:1];
    });
    return s;
}

static NSString *doubledGuillemet(void) {
    static NSString *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [guillemet() stringByAppendingString:guillemet()];
    });
    return s;
}

@implementation PlorgPathCodec

+ (NSString *)escapeComponent:(NSString *)component {
    if (!component) return @"";  // Handle nil gracefully
    return [component stringByReplacingOccurrencesOfString:guillemet()
                                                withString:doubledGuillemet()];
}

+ (NSString *)unescapeComponent:(NSString *)component {
    if (!component) return @"";  // Handle nil gracefully
    return [component stringByReplacingOccurrencesOfString:doubledGuillemet()
                                                withString:guillemet()];
}

+ (NSString *)encodedNameForComponents:(NSArray<NSString *> *)components {
    NSMutableArray<NSString *> *escaped = [NSMutableArray arrayWithCapacity:components.count];
    for (NSString *component in components) {
        NSString *e = [self escapeComponent:component];
        if (e.length > 0) {  // Skip empty/nil components
            [escaped addObject:e];
        }
    }

    // Root-level playlists have only 1 component -> no prefix
    if (escaped.count <= 1) {
        return escaped.firstObject ?: @"";
    }

    return [escaped componentsJoinedByString:PlorgPathSeparator];
}

+ (NSArray<NSString *> *)splitEncodedName:(NSString *)encodedName {
    // Split on " \u00BB " (the 3-char separator), then unescape each component
    NSArray<NSString *> *rawComponents = [encodedName componentsSeparatedByString:PlorgPathSeparator];
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:rawComponents.count];
    for (NSString *raw in rawComponents) {
        [result addObject:[self unescapeComponent:raw]];
    }
    return result;
}

@end
