//
//  GroupPreset.mm
//  foo_simplaylist_mac
//

// Deliberately no ConfigHelper import: this file is the pure model + JSON codec
// and must stay compilable without the foobar2000 SDK so the unit tests can
// link it standalone. Config-backed accessors live in GroupPresetStore.mm.
#import "GroupPreset.h"

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

+ (NSInteger)activeIndexFromJSON:(NSString *)jsonString {
    if (!jsonString || jsonString.length == 0) return 0;

    NSError *error = nil;
    NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    // Unencodable string (e.g. unpaired surrogates); JSONObjectWithData:
    // would throw on nil data.
    if (!jsonData) return 0;
    // A top-level JSON array parses fine and is NOT a dictionary; subscripting
    // it would raise NSInvalidArgumentException on every panel construction.
    id root = [NSJSONSerialization JSONObjectWithData:jsonData
                                              options:0
                                                error:&error];
    if (error || ![root isKindOfClass:[NSDictionary class]]) return 0;
    NSDictionary *json = root;

    // A corrupted entry can hold any type here; integerValue is not universal.
    NSNumber *activeIndex = json[@"active_index"];
    if (![activeIndex isKindOfClass:[NSNumber class]]) return 0;
    return [activeIndex integerValue];
}

+ (NSArray<GroupPreset *> *)presetsFromJSON:(NSString *)jsonString {
    if (!jsonString || jsonString.length == 0) return @[];

    NSError *error = nil;
    NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData) return @[];
    id root = [NSJSONSerialization JSONObjectWithData:jsonData
                                              options:0
                                                error:&error];
    if (error || ![root isKindOfClass:[NSDictionary class]]) return @[];
    NSDictionary *json = root;

    NSArray *presetsArray = json[@"presets"];
    if (![presetsArray isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray<GroupPreset *> *result = [NSMutableArray array];

    for (NSDictionary *presetDict in presetsArray) {
        if (![presetDict isKindOfClass:[NSDictionary class]]) continue;

        // Corrupted config can put non-strings in these slots; a number here
        // would crash later on isEqualToString:/UTF8String sends.
        NSString *name = presetDict[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;

        GroupPreset *preset = [GroupPreset presetWithName:name];

        // Sorting pattern
        NSString *sortingPattern = presetDict[@"sorting_pattern"];
        if ([sortingPattern isKindOfClass:[NSString class]]) {
            preset.sortingPattern = sortingPattern;
        }

        // Header
        NSDictionary *headerDict = presetDict[@"header"];
        if ([headerDict isKindOfClass:[NSDictionary class]]) {
            NSString *pattern = headerDict[@"pattern"];
            NSString *display = headerDict[@"display"];
            if ([pattern isKindOfClass:[NSString class]]) preset.headerPattern = pattern;
            if ([display isKindOfClass:[NSString class]]) preset.headerDisplayType = [self displayTypeFromString:display];
        }

        // Group column
        NSDictionary *groupColDict = presetDict[@"group_column"];
        if ([groupColDict isKindOfClass:[NSDictionary class]]) {
            NSString *pattern = groupColDict[@"pattern"];
            NSString *display = groupColDict[@"display"];
            if ([pattern isKindOfClass:[NSString class]]) preset.groupColumnPattern = pattern;
            if ([display isKindOfClass:[NSString class]]) preset.groupColumnDisplayType = [self displayTypeFromString:display];
        }

        // Subgroups
        NSArray *subgroupsArray = presetDict[@"subgroups"];
        if ([subgroupsArray isKindOfClass:[NSArray class]]) {
            NSMutableArray<SubgroupDefinition *> *subgroups = [NSMutableArray array];
            for (NSDictionary *subDict in subgroupsArray) {
                if (![subDict isKindOfClass:[NSDictionary class]]) continue;

                NSString *pattern = subDict[@"pattern"];
                NSString *display = subDict[@"display"];
                if ([pattern isKindOfClass:[NSString class]]) {
                    GroupDisplayType type = [display isKindOfClass:[NSString class]]
                        ? [self displayTypeFromString:display] : GroupDisplayTypeText;
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
        // nil field would crash the dictionary assignment
        presetDict[@"name"] = preset.name ?: @"";
        presetDict[@"sorting_pattern"] = preset.sortingPattern ?: @"";

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
                @"pattern": sub.pattern ?: @"",
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

// Mirror image of -subgroupPattern: both address subgroups[0] and nothing else.
//
// The empty case used to assign @[], discarding the whole array. A preset whose
// JSON defines two or more subgroups therefore lost all of them the first time
// the single-line preferences field was cleared, and since the UI only ever
// surfaces subgroup 0 the user could not see the others existed, let alone that
// they had gone. Clearing element 0's pattern instead is what the getter's
// contract implies, loses nothing, and still reads back as "" — consumers gate
// on `subgroupPattern.length > 0`, so an empty element 0 disables subgrouping
// exactly as an empty array did.
- (void)setSubgroupPattern:(NSString *)pattern {
    if (self.subgroups.count > 0) {
        SubgroupDefinition *sub = self.subgroups[0];
        sub.pattern = pattern ?: @"";
    } else if (pattern.length > 0) {
        self.subgroups = @[[SubgroupDefinition subgroupWithPattern:pattern displayType:GroupDisplayTypeText]];
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<GroupPreset: %@ header='%@'>",
            self.name, self.headerPattern];
}

@end
