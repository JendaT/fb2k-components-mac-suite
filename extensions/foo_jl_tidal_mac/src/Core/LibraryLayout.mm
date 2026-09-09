//
//  LibraryLayout.mm
//  foo_jl_tidal_mac
//

#import "LibraryLayout.h"

NSString *const JLTidalLibraryReleasesSlot = @"[Releases]";
NSString *const JLTidalLibraryCompilationsSlot = @"[Compilations]";

// Max length of a single path component. Well under the 255-byte limit on
// APFS/ext4/btrfs to leave room for extensions and NAS encodings.
static const NSUInteger kMaxComponentLength = 180;

@implementation JLTidalLibraryLayout

+ (NSString *)sanitizeComponent:(NSString *)name {
    if (name.length == 0) return @"Unknown";

    static NSCharacterSet *forbidden;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet characterSetWithCharactersInString:@"/:\\*?\"<>|"];
        [set formUnionWithCharacterSet:[NSCharacterSet controlCharacterSet]];
        // Whitespace-like controls (tab, newline) collapse to spaces below
        // instead of being replaced
        [set formIntersectionWithCharacterSet:
             [[NSCharacterSet whitespaceAndNewlineCharacterSet] invertedSet]];
        forbidden = set;
    });

    NSMutableString *out = [NSMutableString stringWithCapacity:name.length];
    [name enumerateSubstringsInRange:NSMakeRange(0, name.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *sub, NSRange, NSRange, BOOL *) {
        if (sub.length == 1 && [forbidden characterIsMember:[sub characterAtIndex:0]]) {
            [out appendString:[sub isEqualToString:@"\""] ? @"'" : @"-"];
        } else {
            [out appendString:sub];
        }
    }];

    // Collapse whitespace runs to a single space
    NSArray<NSString *> *words = [out componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *nonEmpty = [NSMutableArray array];
    for (NSString *w in words) {
        if (w.length > 0) [nonEmpty addObject:w];
    }
    NSString *result = [nonEmpty componentsJoinedByString:@" "];

    // Trailing dots break SMB/Windows interop
    while ([result hasSuffix:@"."]) {
        result = [result substringToIndex:result.length - 1];
    }
    result = [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if (result.length > kMaxComponentLength) {
        result = [[result substringToIndex:kMaxComponentLength]
                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }

    // "." and ".." as path components escape the library subtree
    if ([result isEqualToString:@"."] || [result isEqualToString:@".."]) {
        result = @"Unknown";
    }
    return result.length > 0 ? result : @"Unknown";
}

+ (NSString *)yearStringFromDate:(NSDate *)date {
    if (!date) return nil;
    static NSCalendar *cal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        cal.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    NSInteger year = [cal component:NSCalendarUnitYear fromDate:date];
    return [NSString stringWithFormat:@"%04ld", (long)year];
}

+ (BOOL)isVariousArtists:(NSString *)albumArtist {
    if (albumArtist.length == 0) return NO;
    NSString *lower = [[albumArtist lowercaseString]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return [lower isEqualToString:@"various artists"] ||
           [lower isEqualToString:@"various"] ||
           [lower isEqualToString:@"va"] ||
           [lower isEqualToString:@"v.a."];
}

+ (NSString *)releaseFolderNameForArtist:(NSString *)artist
                                    year:(NSString *)year
                                   title:(NSString *)title {
    return [NSString stringWithFormat:@"%@ [%@] %@",
            [self sanitizeComponent:artist],
            year.length > 0 ? year : @"0000",
            [self sanitizeComponent:title]];
}

+ (NSString *)compilationFolderNameForYear:(NSString *)year
                                     title:(NSString *)title {
    return [NSString stringWithFormat:@"VA [%@] %@",
            year.length > 0 ? year : @"0000",
            [self sanitizeComponent:title]];
}

+ (NSString *)albumPathForArtist:(NSString *)artist
                            year:(NSString *)year
                      albumTitle:(NSString *)title
                   isCompilation:(BOOL)isCompilation
                    artistFolder:(NSString *)artistFolder {
    if (isCompilation) {
        return [JLTidalLibraryCompilationsSlot stringByAppendingPathComponent:
                [self compilationFolderNameForYear:year title:title]];
    }
    NSString *release = [self releaseFolderNameForArtist:artist year:year title:title];
    if (artistFolder.length > 0) {
        return [artistFolder stringByAppendingPathComponent:release];
    }
    return [JLTidalLibraryReleasesSlot stringByAppendingPathComponent:release];
}

+ (NSString *)trackFileNameForNumber:(NSInteger)trackNumber
                          discNumber:(NSInteger)discNumber
                               title:(NSString *)title
                           extension:(NSString *)extension {
    NSString *safeTitle = [self sanitizeComponent:title];
    NSString *prefix = @"";
    if (trackNumber > 0) {
        if (discNumber >= 2) {
            prefix = [NSString stringWithFormat:@"%ld-%02ld - ", (long)discNumber, (long)trackNumber];
        } else {
            prefix = [NSString stringWithFormat:@"%02ld - ", (long)trackNumber];
        }
    }
    return [NSString stringWithFormat:@"%@%@.%@", prefix, safeTitle, extension];
}

+ (NSArray<NSString *> *)collectionNamesFromListing:(NSArray<NSString *> *)names {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *name in names) {
        if (name.length < 3) continue;
        if (![name hasPrefix:@"["] || ![name hasSuffix:@"]"]) continue;
        if ([name isEqualToString:JLTidalLibraryReleasesSlot]) continue;
        if ([name isEqualToString:JLTidalLibraryCompilationsSlot]) continue;
        [out addObject:name];
    }
    [out sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return out;
}

+ (NSString *)artistFolderInListing:(NSArray<NSString *> *)names
                             artist:(NSString *)artist {
    if (artist.length == 0) return nil;
    NSString *wanted = [[self sanitizeComponent:artist] lowercaseString];
    for (NSString *name in names) {
        if ([name hasPrefix:@"["]) continue;  // slot folders never match
        if ([[name lowercaseString] isEqualToString:wanted]) return name;
    }
    return nil;
}

// Replace newlines/control characters in a metadata value with spaces —
// they would otherwise confuse ffmpeg's -metadata key=value parsing.
+ (NSString *)stripControlCharacters:(NSString *)value {
    if (value.length == 0) return value;
    NSCharacterSet *controls = [NSCharacterSet controlCharacterSet];
    if ([value rangeOfCharacterFromSet:controls].location == NSNotFound) return value;
    NSArray<NSString *> *parts = [value componentsSeparatedByCharactersInSet:controls];
    NSMutableArray<NSString *> *nonEmpty = [NSMutableArray array];
    for (NSString *p in parts) {
        if (p.length > 0) [nonEmpty addObject:p];
    }
    return [nonEmpty componentsJoinedByString:@" "];
}

+ (NSArray<NSString *> *)ffmpegArgumentsForInput:(NSString *)inputPath
                                          output:(NSString *)outputPath
                                        metadata:(NSDictionary<NSString *, NSString *> *)metadata {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:
        @"-y", @"-i", inputPath, @"-map_metadata", @"-1", @"-vn", @"-c:a", @"copy", nil];
    NSArray<NSString *> *keys = [metadata.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in keys) {
        NSString *value = [self stripControlCharacters:metadata[key]];
        if (value.length == 0) continue;
        [args addObject:@"-metadata"];
        [args addObject:[NSString stringWithFormat:@"%@=%@", key, value]];
    }
    [args addObject:outputPath];
    return args;
}

@end
