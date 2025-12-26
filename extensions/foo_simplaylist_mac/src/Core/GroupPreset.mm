//
//  GroupPreset.mm
//  foo_simplaylist_mac
//

#import "GroupPreset.h"
#import "ConfigHelper.h"

@implementation SubgroupDefinition

+ (instancetype)subgroupWithPattern:(NSString *)pattern displayType:(GroupDisplayType)type {
    SubgroupDefinition *def = [[SubgroupDefinition alloc] init];
    def.pattern = pattern;
    def.displayType = type;
    return def;
}

@end

@implementation GroupPreset

+ (instancetype)presetWithName:(NSString *)name {
    GroupPreset *preset = [[GroupPreset alloc] init];
    preset.name = name;
    preset.sortingPattern = @"%path_sort%";
    preset.headerPattern = @"";
    preset.headerDisplayType = GroupDisplayTypeText;
    preset.groupColumnPattern = @"";
    preset.groupColumnDisplayType = GroupDisplayTypeFront;
    preset.subgroups = @[];
    return preset;
}

+ (GroupDisplayType)displayTypeFromString:(NSString *)str {
    NSString *lower = [str lowercaseString];
    if ([lower isEqualToString:@"front"]) return GroupDisplayTypeFront;
    if ([lower isEqualToString:@"back"]) return GroupDisplayTypeBack;
    if ([lower isEqualToString:@"disc"]) return GroupDisplayTypeDisc;
    if ([lower isEqualToString:@"artist"]) return GroupDisplayTypeArtist;
    return GroupDisplayTypeText;
}

+ (NSString *)stringFromDisplayType:(GroupDisplayType)type {
    switch (type) {
        case GroupDisplayTypeFront: return @"front";
        case GroupDisplayTypeBack: return @"back";
        case GroupDisplayTypeDisc: return @"disc";
        case GroupDisplayTypeArtist: return @"artist";
        default: return @"text";
    }
}

+ (NSArray<GroupPreset *> *)defaultPresets {
    // First try to load from saved config
    std::string savedJSON = simplaylist_config::getConfigString(
        simplaylist_config::kGroupPresets, "");

    if (!savedJSON.empty()) {
        NSString *jsonString = [NSString stringWithUTF8String:savedJSON.c_str()];
        NSArray<GroupPreset *> *presets = [self presetsFromJSON:jsonString];
        if (presets.count > 0) {
            return presets;
        }
    }

    // Fall back to hardcoded default JSON
    const char* jsonCStr = simplaylist_config::getDefaultGroupPresetsJSON();
    NSString *jsonString = [NSString stringWithUTF8String:jsonCStr];

    NSArray<GroupPreset *> *presets = [self presetsFromJSON:jsonString];
    if (presets.count > 0) {
        return presets;
    }

    // Final fallback: create basic preset
    GroupPreset *basic = [GroupPreset presetWithName:@"Album"];
    basic.sortingPattern = @"%path_sort%";
    basic.headerPattern = @"[%album artist% - ]['['%date%']' ][%album%]";
    basic.groupColumnPattern = @"[%album%]";
    basic.groupColumnDisplayType = GroupDisplayTypeFront;
    basic.subgroups = @[
        [SubgroupDefinition subgroupWithPattern:@"[Disc %discnumber%]" displayType:GroupDisplayTypeText]
    ];

    return @[basic];
}

+ (NSInteger)activeIndexFromJSON:(NSString *)jsonString {
    if (!jsonString || jsonString.length == 0) return 0;

    NSError *error = nil;
    NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData
                                                         options:0
                                                           error:&error];
    if (error || !json) return 0;

    NSNumber *activeIndex = json[@"active_index"];
    return activeIndex ? [activeIndex integerValue] : 0;
}

+ (NSArray<GroupPreset *> *)presetsFromJSON:(NSString *)jsonString {
    if (!jsonString || jsonString.length == 0) return @[];

    NSError *error = nil;
    NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData
                                                         options:0
                                                           error:&error];
    if (error || !json) return @[];

    NSArray *presetsArray = json[@"presets"];
    if (![presetsArray isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray<GroupPreset *> *result = [NSMutableArray array];

    for (NSDictionary *presetDict in presetsArray) {
        if (![presetDict isKindOfClass:[NSDictionary class]]) continue;

        NSString *name = presetDict[@"name"];
        if (!name) continue;

        GroupPreset *preset = [GroupPreset presetWithName:name];

        // Sorting pattern
        NSString *sortingPattern = presetDict[@"sorting_pattern"];
        if (sortingPattern) {
            preset.sortingPattern = sortingPattern;
        }

        // Header
        NSDictionary *headerDict = presetDict[@"header"];
        if ([headerDict isKindOfClass:[NSDictionary class]]) {
            NSString *pattern = headerDict[@"pattern"];
            NSString *display = headerDict[@"display"];
            if (pattern) preset.headerPattern = pattern;
            if (display) preset.headerDisplayType = [self displayTypeFromString:display];
        }

        // Group column
        NSDictionary *groupColDict = presetDict[@"group_column"];
        if ([groupColDict isKindOfClass:[NSDictionary class]]) {
            NSString *pattern = groupColDict[@"pattern"];
            NSString *display = groupColDict[@"display"];
            if (pattern) preset.groupColumnPattern = pattern;
            if (display) preset.groupColumnDisplayType = [self displayTypeFromString:display];
        }

        // Subgroups
        NSArray *subgroupsArray = presetDict[@"subgroups"];
        if ([subgroupsArray isKindOfClass:[NSArray class]]) {
            NSMutableArray<SubgroupDefinition *> *subgroups = [NSMutableArray array];
            for (NSDictionary *subDict in subgroupsArray) {
                if (![subDict isKindOfClass:[NSDictionary class]]) continue;

                NSString *pattern = subDict[@"pattern"];
                NSString *display = subDict[@"display"];
                if (pattern) {
                    GroupDisplayType type = display ? [self displayTypeFromString:display] : GroupDisplayTypeText;
                    [subgroups addObject:[SubgroupDefinition subgroupWithPattern:pattern displayType:type]];
                }
            }
            preset.subgroups = subgroups;
        }

        [result addObject:preset];
    }

    return result;
}

+ (nullable NSString *)presetsToJSON:(NSArray<GroupPreset *> *)presets activeIndex:(NSInteger)index {
    NSMutableArray *presetsArray = [NSMutableArray array];

    for (GroupPreset *preset in presets) {
        NSMutableDictionary *presetDict = [NSMutableDictionary dictionary];
        presetDict[@"name"] = preset.name;
        presetDict[@"sorting_pattern"] = preset.sortingPattern;

        // Header
        presetDict[@"header"] = @{
            @"pattern": preset.headerPattern ?: @"",
            @"display": [self stringFromDisplayType:preset.headerDisplayType]
        };

        // Group column
        presetDict[@"group_column"] = @{
            @"pattern": preset.groupColumnPattern ?: @"",
            @"display": [self stringFromDisplayType:preset.groupColumnDisplayType]
        };

        // Subgroups
        NSMutableArray *subgroupsArray = [NSMutableArray array];
        for (SubgroupDefinition *sub in preset.subgroups) {
            [subgroupsArray addObject:@{
                @"pattern": sub.pattern,
                @"display": [self stringFromDisplayType:sub.displayType]
            }];
        }
        presetDict[@"subgroups"] = subgroupsArray;

        [presetsArray addObject:presetDict];
    }

    NSDictionary *json = @{
        @"presets": presetsArray,
        @"active_index": @(index)
    };

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (error || !jsonData) return nil;

    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

+ (nullable NSString *)presetsToJSON:(NSArray<GroupPreset *> *)presets {
    return [self presetsToJSON:presets activeIndex:0];
}

- (NSString *)subgroupPattern {
    if (self.subgroups.count > 0) {
        return self.subgroups[0].pattern ?: @"";
    }
    return @"";
}

- (void)setSubgroupPattern:(NSString *)pattern {
    if (pattern.length == 0) {
        self.subgroups = @[];
    } else if (self.subgroups.count > 0) {
        SubgroupDefinition *sub = self.subgroups[0];
        sub.pattern = pattern;
    } else {
        self.subgroups = @[[SubgroupDefinition subgroupWithPattern:pattern displayType:GroupDisplayTypeText]];
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<GroupPreset: %@ header='%@'>",
            self.name, self.headerPattern];
}

@end
