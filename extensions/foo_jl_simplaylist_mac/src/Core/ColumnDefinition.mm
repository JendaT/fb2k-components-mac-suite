//
//  ColumnDefinition.mm
//  foo_simplaylist_mac
//

#import "ColumnDefinition.h"
#import "ConfigHelper.h"
#import "../fb2k_sdk.h"
#import <foobar2000/SDK/playlistColumnProvider.h>

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

+ (NSArray<ColumnDefinition *> *)defaultColumns {
    // First try to load from saved config
    std::string savedJSON = simplaylist_config::getConfigString(
        simplaylist_config::kColumns, "");

    if (!savedJSON.empty()) {
        NSString *jsonString = [NSString stringWithUTF8String:savedJSON.c_str()];
        NSArray<ColumnDefinition *> *columns = [self columnsFromJSON:jsonString];
        if (columns.count > 0) {
            return columns;
        }
    }

    // Fall back to hardcoded default JSON
    const char* jsonCStr = simplaylist_config::getDefaultColumnsJSON();
    NSString *jsonString = [NSString stringWithUTF8String:jsonCStr];

    NSArray<ColumnDefinition *> *columns = [self columnsFromJSON:jsonString];
    if (columns.count > 0) {
        return columns;
    }

    // Final fallback to hardcoded defaults
    return @[
        [ColumnDefinition columnWithName:@"Playing"
                                 pattern:@"$if(%isplaying%,>,)"
                                   width:24
                               alignment:ColumnAlignmentCenter],

        [ColumnDefinition columnWithName:@"#"
                                 pattern:@"%tracknumber%"
                                   width:32
                               alignment:ColumnAlignmentRight],

        [ColumnDefinition columnWithName:@"Title"
                                 pattern:@"%title%"
                                   width:250
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],

        [ColumnDefinition columnWithName:@"Artist"
                                 pattern:@"%artist%"
                                   width:150
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],

        [ColumnDefinition columnWithName:@"Duration"
                                 pattern:@"%length%"
                                   width:50
                               alignment:ColumnAlignmentRight]
    ];
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
        [ColumnDefinition columnWithName:@"Playing"
                                 pattern:@"$if(%isplaying%,>,)"
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

        // Playback statistics (second group - after separator)
        [ColumnDefinition columnWithName:@"Play Count"
                                 pattern:@"%play_count%"
                                   width:60
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"First Played"
                                 pattern:@"%first_played%"
                                   width:120
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"Last Played"
                                 pattern:@"%last_played%"
                                   width:120
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"Date Added"
                                 pattern:@"%added%"
                                   width:120
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"Rating"
                                 pattern:@"%rating%"
                                   width:60
                               alignment:ColumnAlignmentCenter
                              autoResize:NO],
    ];
}

+ (NSArray<ColumnDefinition *> *)columnsFromSDKProviders {
    NSMutableArray<ColumnDefinition *> *columns = [NSMutableArray array];
    NSMutableSet<NSString *> *seenNames = [NSMutableSet set];

    @try {
        // Enumerate all playlistColumnProvider services
        for (auto provider : fb2k::playlistColumnProvider::enumerate()) {
            size_t numCols = provider->numColumns();

            for (size_t i = 0; i < numCols; i++) {
                fb2k::stringRef nameRef = provider->columnName(i);
                fb2k::stringRef patternRef = provider->columnFormatSpec(i);
                unsigned flags = provider->columnFlags(i);

                if (!nameRef.is_valid() || !patternRef.is_valid()) continue;

                NSString *name = [NSString stringWithUTF8String:nameRef->c_str()];
                NSString *pattern = [NSString stringWithUTF8String:patternRef->c_str()];

                // Skip if empty or already seen
                if (!name || name.length == 0 || !pattern || pattern.length == 0) continue;
                if ([seenNames containsObject:name]) continue;
                [seenNames addObject:name];

                // Determine alignment from flags
                ColumnAlignment alignment = ColumnAlignmentLeft;
                if (flags & fb2k::playlistColumnProvider::flag_alignRight) {
                    alignment = ColumnAlignmentRight;
                } else if (flags & fb2k::playlistColumnProvider::flag_alignCenter) {
                    alignment = ColumnAlignmentCenter;
                }

                ColumnDefinition *col = [ColumnDefinition columnWithName:name
                                                                  pattern:pattern
                                                                    width:100
                                                                alignment:alignment];
                [columns addObject:col];
            }
        }
    } @catch (NSException *exception) {
        // Ignore enumeration errors
    }

    return columns;
}

+ (NSArray<ColumnDefinition *> *)columnsFromJSON:(NSString *)jsonString {
    if (!jsonString || jsonString.length == 0) {
        return @[];
    }

    NSError *error = nil;
    NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData
                                                         options:0
                                                           error:&error];
    if (error || !json) {
        return @[];
    }

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

        if (!name || !pattern) continue;

        // Migration: "Track no" removed - use "#" instead (v1.1.7+)
        if ([name isEqualToString:@"Track no"]) {
            continue;  // Skip - duplicate of "#"
        }

        ColumnDefinition *col = [[ColumnDefinition alloc] init];
        col.name = name;
        col.pattern = pattern;
        col.width = widthNum ? [widthNum doubleValue] : 100;
        col.alignment = alignmentStr ? [self alignmentFromString:alignmentStr] : ColumnAlignmentLeft;
        col.autoResize = autoResizeNum ? [autoResizeNum boolValue] : NO;
        col.clickable = clickableNum ? [clickableNum boolValue] : NO;

        [result addObject:col];
    }

    return result;
}

+ (NSString *)columnsToJSON:(NSArray<ColumnDefinition *> *)columns {
    NSMutableArray *columnsArray = [NSMutableArray array];

    for (ColumnDefinition *col in columns) {
        NSMutableDictionary *colDict = [NSMutableDictionary dictionary];
        colDict[@"name"] = col.name;
        colDict[@"pattern"] = col.pattern;
        colDict[@"width"] = @(col.width);
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
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (error || !jsonData) {
        return @"";
    }

    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<Column: %@ pattern='%@' width=%.0f>",
            self.name, self.pattern, self.width];
}

@end
