//
//  GroupPresetStore.h
//  foo_simplaylist_mac
//
//  The config-backed half of GroupPreset.
//
//  GroupPreset itself is a pure model + JSON codec with no dependency on the
//  foobar2000 SDK, which is what lets Tests/GroupPresetTests.mm compile and run
//  it standalone under clang. Everything that reads or writes the config store
//  lives here instead, so that dependency stays out of the pure file.
//
//  The separation has to be at file scope. simplaylist_config's accessors are
//  `inline` in ConfigHelper.h, so the SDK dependency is compile-time, not
//  link-time: a link-time stub cannot replace them, and a fake SDK header on
//  -I cannot shadow the real one either, because the include is a quoted
//  relative path resolved against the including file. Moving the callers out is
//  the only route.
//

#pragma once

#import "GroupPreset.h"

NS_ASSUME_NONNULL_BEGIN

@interface GroupPreset (Store)

// Preset list, from persisted config with a fallback chain: stored JSON, then
// the compiled-in default JSON, then a single hardcoded Album preset.
+ (NSArray<GroupPreset *> *)defaultPresets;

// Active preset index, read from the same persisted JSON as +defaultPresets.
//
// The index belongs to that JSON's "active_index" field and nowhere else. It
// used to be mirrored into a separate `active_preset_index` config key that
// only the preferences page wrote and read, while the playlist panel took the
// index from the JSON — so switching preset in preferences updated the mirror,
// left the JSON untouched, and the panel went on grouping by the old preset
// until some later edit happened to rewrite the JSON. Returns 0 when nothing
// is persisted or the stored value is unusable.
+ (NSInteger)defaultActivePresetIndex;

@end

NS_ASSUME_NONNULL_END
