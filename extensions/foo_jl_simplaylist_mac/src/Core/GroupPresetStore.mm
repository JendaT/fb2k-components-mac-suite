//
//  GroupPresetStore.mm
//  foo_simplaylist_mac
//

#import "GroupPresetStore.h"
#import "ConfigHelper.h"

@implementation GroupPreset (Store)

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
    basic.headerPattern = @"[$if2(%album artist%,%artist%) - ]['['%date%']' ][%album%]";
    basic.groupColumnPattern = @"[%album%]";
    basic.groupColumnDisplayType = GroupDisplayTypeFront;
    basic.subgroups = @[
        [SubgroupDefinition subgroupWithPattern:@"[Disc %discnumber%]" displayType:GroupDisplayTypeText]
    ];

    return @[basic];
}

+ (NSInteger)defaultActivePresetIndex {
    std::string savedJSON = simplaylist_config::getConfigString(
        simplaylist_config::kGroupPresets, "");
    if (savedJSON.empty()) return 0;
    // nil on invalid UTF-8 in a corrupt store; activeIndexFromJSON: guards it.
    NSString *jsonString = [NSString stringWithUTF8String:savedJSON.c_str()];
    return [self activeIndexFromJSON:jsonString];
}

@end
