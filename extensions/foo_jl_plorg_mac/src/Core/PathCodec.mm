//
//  PathCodec.mm
//  foo_plorg_mac
//

#import "PathCodec.h"

NSString * const PlorgPathSeparator = @" \u00BB ";

// Single guillemet character used for escaping
static unichar const kGuillemet = 0x00BB;

@implementation PathCodec

+ (NSString *)escapeComponent:(NSString *)component {
    if (!component) return @"";  // Handle nil gracefully
    NSString *guilStr = [NSString stringWithCharacters:&kGuillemet length:1];
    NSString *doubled = [NSString stringWithFormat:@"%@%@", guilStr, guilStr];
    return [component stringByReplacingOccurrencesOfString:guilStr withString:doubled];
}

+ (NSString *)unescapeComponent:(NSString *)component {
    if (!component) return @"";  // Handle nil gracefully
    NSString *guilStr = [NSString stringWithCharacters:&kGuillemet length:1];
    NSString *doubled = [NSString stringWithFormat:@"%@%@", guilStr, guilStr];
    return [component stringByReplacingOccurrencesOfString:doubled withString:guilStr];
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
