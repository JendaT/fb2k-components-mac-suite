//
//  ColumnDefinition.mm
//  foo_simplaylist_mac
//

// Deliberately no ConfigHelper or fb2k_sdk import: this file is the pure model,
// JSON codec and layout transforms, and must stay compilable without the
// foobar2000 SDK so Tests/ColumnDefinitionTests.mm can link it standalone.
// Everything config-backed or SDK-backed lives in ColumnDefinitionStore.mm.
#import "ColumnDefinition.h"

@implementation ColumnDefinition

- (instancetype)init {
    self = [super init];
    if (self) {
        _name = @"";
        _pattern = @"";
        _width = 100;
        _minWidth = 30;
        _alignment = ColumnAlignmentLeft;
        _autoResize = NO;
        _clickable = NO;
    }
    return self;
}

- (id)copyWithZone:(nullable NSZone *)zone {
    ColumnDefinition *copy = [[ColumnDefinition allocWithZone:zone] init];
    copy.name = self.name;
    copy.pattern = self.pattern;
    copy.width = self.width;
    copy.minWidth = self.minWidth;
    copy.alignment = self.alignment;
    copy.autoResize = self.autoResize;
    copy.clickable = self.clickable;
    return copy;
}

+ (instancetype)columnWithName:(NSString *)name
                       pattern:(NSString *)pattern
                         width:(CGFloat)width
                     alignment:(ColumnAlignment)alignment {
    return [self columnWithName:name pattern:pattern width:width alignment:alignment autoResize:NO];
}

+ (instancetype)columnWithName:(NSString *)name
                       pattern:(NSString *)pattern
                         width:(CGFloat)width
                     alignment:(ColumnAlignment)alignment
                    autoResize:(BOOL)autoResize {
    ColumnDefinition *col = [[ColumnDefinition alloc] init];
    col.name = name;
    col.pattern = pattern;
    col.width = width;
    col.alignment = alignment;
    col.autoResize = autoResize;
    return col;
}

+ (ColumnAlignment)alignmentFromString:(NSString *)str {
    NSString *lower = [str lowercaseString];
    if ([lower isEqualToString:@"center"]) {
        return ColumnAlignmentCenter;
    } else if ([lower isEqualToString:@"right"]) {
        return ColumnAlignmentRight;
    }
    return ColumnAlignmentLeft;
}

+ (NSString *)stringFromAlignment:(ColumnAlignment)alignment {
    switch (alignment) {
        case ColumnAlignmentCenter:
            return @"center";
        case ColumnAlignmentRight:
            return @"right";
        default:
            return @"left";
    }
}

+ (NSArray<ColumnDefinition *> *)availableColumnTemplates {
    // Return all available column types for the column chooser menu
    // Organized in same order as default playlist UI
    return @[
        // Standard columns (first group)
        [ColumnDefinition columnWithName:@"#"
                                 pattern:@"%tracknumber%"
                                   width:32
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Item index"
                                 pattern:@"%list_index%"
                                   width:50
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Artist"
                                 pattern:@"%artist%"
                                   width:150
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Album"
                                 pattern:@"%album%"
                                   width:150
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Artist/album"
                                 pattern:@"$if2(%album artist%,%artist%)[ / %album%]"
                                   width:200
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Title"
                                 pattern:@"%title%"
                                   width:250
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Title / track artist"
                                 pattern:@"%title%[ / %track artist%]"
                                   width:250
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Date"
                                 pattern:@"%date%"
                                   width:60
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"Duration"
                                 pattern:@"%length%"
                                   width:50
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Codec"
                                 pattern:@"%codec%"
                                   width:60
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"Bitrate"
                                 pattern:@"%bitrate%"
                                   width:60
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Sample Rate"
                                 pattern:@"[%samplerate% Hz][, %__bitspersample%-bit]"
                                   width:100
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"BPM"
                                 pattern:@"%BPM%"
                                   width:50
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Key"
                                 pattern:@"%INITIALKEY%"
                                   width:50
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"Queue #"
                                 pattern:@"__queue_position__"
                                   width:40
                               alignment:ColumnAlignmentCenter],
        [ColumnDefinition columnWithName:@"Playing"
                                 pattern:@""
                                   width:24
                               alignment:ColumnAlignmentCenter],
        [ColumnDefinition columnWithName:@"File name"
                                 pattern:@"%filename%"
                                   width:200
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"File extension"
                                 pattern:@"%filename_ext%"
                                   width:50
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"File path"
                                 pattern:@"%path%"
                                   width:300
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"File size"
                                 pattern:@"%filesize%"
                                   width:60
                               alignment:ColumnAlignmentRight],
        // Note: Play Count, First Played, Last Played, Date Added, Rating
        // are provided by SDK playlistColumnProvider, not hardcoded here
    ];
}

#pragma mark - Pure transforms

+ (NSArray<ColumnDefinition *> *)columns:(NSArray<ColumnDefinition *> *)columns
                    filteredToKnownNames:(NSSet<NSString *> *)knownNames {
    NSMutableArray<ColumnDefinition *> *result = [NSMutableArray arrayWithCapacity:columns.count];
    for (ColumnDefinition *col in columns) {
        if (col.name && [knownNames containsObject:col.name]) {
            [result addObject:col];
        }
    }
    return result;
}

+ (nullable NSArray<ColumnDefinition *> *)columns:(NSArray<ColumnDefinition *> *)columns
                                      renamedFrom:(NSString *)oldName
                                               to:(NSString *)newName {
    if (!oldName || !newName || [oldName isEqualToString:newName]) return nil;

    BOOL changed = NO;
    NSMutableArray<ColumnDefinition *> *updated = [NSMutableArray arrayWithCapacity:columns.count];
    for (ColumnDefinition *col in columns) {
        if ([col.name isEqualToString:oldName]) {
            // Copy rather than mutate: the caller's array may be a live layout
            // still held by a panel, and renaming in place would change what it
            // is showing without it knowing.
            ColumnDefinition *renamed = [col copy];
            renamed.name = newName;
            [updated addObject:renamed];
            changed = YES;
        } else {
            [updated addObject:col];
        }
    }
    return changed ? updated : nil;
}

+ (nullable NSArray<ColumnDefinition *> *)columnsByMigratingLegacyPlayingPattern:
    (NSArray<ColumnDefinition *> *)columns {
    static NSString *const kLegacyPlayingPattern = @"$if(%isplaying%,>,)";

    BOOL migrated = NO;
    NSMutableArray<ColumnDefinition *> *updated = [NSMutableArray arrayWithCapacity:columns.count];
    for (ColumnDefinition *col in columns) {
        if ([col.name isEqualToString:@"Playing"] &&
            [col.pattern isEqualToString:kLegacyPlayingPattern]) {
            ColumnDefinition *fixed = [col copy];
            fixed.pattern = @"";
            [updated addObject:fixed];
            migrated = YES;
        } else {
            [updated addObject:col];
        }
    }
    return migrated ? updated : nil;
}

#pragma mark - JSON codec

+ (NSArray<ColumnDefinition *> *)columnsFromJSON:(NSString *)jsonString {
    if (!jsonString || jsonString.length == 0) {
        return @[];
    }

    NSError *error = nil;
    NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData) {
        // Unencodable string (e.g. unpaired surrogates); JSONObjectWithData:
        // would throw on nil data.
        return @[];
    }
    // A top-level JSON array parses fine and is NOT a dictionary; subscripting
    // it would raise NSInvalidArgumentException on every panel construction.
    id root = [NSJSONSerialization JSONObjectWithData:jsonData
                                              options:0
                                                error:&error];
    if (error || ![root isKindOfClass:[NSDictionary class]]) {
        return @[];
    }
    NSDictionary *json = root;

    NSArray *columnsArray = json[@"columns"];
    if (![columnsArray isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<ColumnDefinition *> *result = [NSMutableArray array];

    for (NSDictionary *colDict in columnsArray) {
        if (![colDict isKindOfClass:[NSDictionary class]]) continue;

        NSString *name = colDict[@"name"];
        NSString *pattern = colDict[@"pattern"];
        NSNumber *widthNum = colDict[@"width"];
        NSString *alignmentStr = colDict[@"alignment"];
        NSNumber *autoResizeNum = colDict[@"auto_resize"];
        NSNumber *clickableNum = colDict[@"clickable"];

        // Corrupted config can put non-strings/non-numbers here; wrong types
        // crash later on isEqualToString:/doubleValue sends.
        if (![name isKindOfClass:[NSString class]] ||
            ![pattern isKindOfClass:[NSString class]]) continue;
        if (widthNum && ![widthNum isKindOfClass:[NSNumber class]]) widthNum = nil;
        if (alignmentStr && ![alignmentStr isKindOfClass:[NSString class]]) alignmentStr = nil;
        if (autoResizeNum && ![autoResizeNum isKindOfClass:[NSNumber class]]) autoResizeNum = nil;
        if (clickableNum && ![clickableNum isKindOfClass:[NSNumber class]]) clickableNum = nil;

        // Migration: "Track no" removed - use "#" instead (v1.1.7+)
        if ([name isEqualToString:@"Track no"]) {
            continue;  // Skip - duplicate of "#"
        }

        ColumnDefinition *col = [[ColumnDefinition alloc] init];
        col.name = name;
        col.pattern = pattern;
        // Persisted width may be NaN/Inf/non-positive; that would flow into
        // NSRect math and hit-testing. Fall back to the default and cap.
        // (No higher floor: stock columns legitimately persist widths of 24.)
        double width = widthNum ? [widthNum doubleValue] : 100;
        if (!isfinite(width) || width <= 0) width = 100;
        col.width = MIN(10000.0, width);
        col.alignment = alignmentStr ? [self alignmentFromString:alignmentStr] : ColumnAlignmentLeft;
        col.autoResize = autoResizeNum ? [autoResizeNum boolValue] : NO;
        col.clickable = clickableNum ? [clickableNum boolValue] : NO;

        [result addObject:col];
    }

    return result;
}

+ (nullable NSString *)columnsToJSON:(NSArray<ColumnDefinition *> *)columns {
    NSMutableArray *columnsArray = [NSMutableArray array];

    for (ColumnDefinition *col in columns) {
        NSMutableDictionary *colDict = [NSMutableDictionary dictionary];
        // nil field would crash the dictionary literal-style assignment
        colDict[@"name"] = col.name ?: @"";
        colDict[@"pattern"] = col.pattern ?: @"";
        // A NaN or infinite width makes +dataWithJSONObject: *raise*
        // NSInvalidArgumentException rather than set `error`, so the guard
        // below would never see it. Clamp to the same fallback the read path
        // applies — which exists because such widths are known to occur.
        double width = col.width;
        if (!isfinite(width) || width <= 0) width = 100;
        colDict[@"width"] = @(width);
        colDict[@"alignment"] = [self stringFromAlignment:col.alignment];
        if (col.autoResize) {
            colDict[@"auto_resize"] = @YES;
        }
        if (col.clickable) {
            colDict[@"clickable"] = @YES;
        }
        [columnsArray addObject:colDict];
    }

    NSDictionary *json = @{@"columns": columnsArray};
    // Belt and braces after the width clamp above: anything else unserialisable
    // would raise out of dataWithJSONObject: instead of reporting an error.
    if (![NSJSONSerialization isValidJSONObject:json]) {
        return nil;
    }
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (error || !jsonData) {
        return nil;
    }

    // nil if the data is not valid UTF-8; callers must not persist that either.
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<Column: %@ pattern='%@' width=%.0f>",
            self.name, self.pattern, self.width];
}

@end
