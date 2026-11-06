//
//  GroupPresetTests.mm
//  foo_simplaylist_mac
//
//  Unit tests for the GroupPreset model and its JSON codec.
//
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//  Nothing here touches the config store — GroupPreset.mm is deliberately free
//  of the foobar2000 SDK, and the two config-backed accessors live in
//  GroupPresetStore.mm, which these tests never link.
//

#import <Foundation/Foundation.h>
#import "../src/Core/GroupPreset.h"
#import "TestHarness.h"

// See the note in ColumnDefinitionTests.mm: an opaque nil keeps -Wnonnull
// enabled for real code while the hostile-input tests still pass nil.
static NSString *nilString(void) { return nil; }

static NSArray<NSString *> *namesOf(NSArray<GroupPreset *> *presets) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (GroupPreset *p in presets) [names addObject:p.name];
    return names;
}

int main(void) {
    @autoreleasepool {

    // ---------------------------------------------------------------- model
    {
        g_context = "preset-defaults";
        GroupPreset *p = [GroupPreset presetWithName:@"Album"];
        CHECK([p.name isEqualToString:@"Album"], "name set");
        CHECK([p.sortingPattern isEqualToString:@"%path_sort%"], "sorting default");
        CHECK([p.headerPattern isEqualToString:@""], "header default empty");
        CHECK_EQ(p.headerDisplayType, GroupDisplayTypeText, "header display default");
        CHECK([p.groupColumnPattern isEqualToString:@""], "group column default empty");
        CHECK_EQ(p.groupColumnDisplayType, GroupDisplayTypeFront, "group column display default");
        CHECK_EQ(p.subgroups.count, 0, "no subgroups by default");
    }

    {
        g_context = "display-type-strings";
        CHECK_EQ([GroupPreset displayTypeFromString:@"front"], GroupDisplayTypeFront, "front");
        CHECK_EQ([GroupPreset displayTypeFromString:@"back"], GroupDisplayTypeBack, "back");
        CHECK_EQ([GroupPreset displayTypeFromString:@"disc"], GroupDisplayTypeDisc, "disc");
        CHECK_EQ([GroupPreset displayTypeFromString:@"artist"], GroupDisplayTypeArtist, "artist");
        CHECK_EQ([GroupPreset displayTypeFromString:@"text"], GroupDisplayTypeText, "text");
        CHECK_EQ([GroupPreset displayTypeFromString:@"FRONT"], GroupDisplayTypeFront, "case-insensitive");
        CHECK_EQ([GroupPreset displayTypeFromString:@"nonsense"], GroupDisplayTypeText, "unknown -> text");

        GroupDisplayType all[] = {GroupDisplayTypeText, GroupDisplayTypeFront,
                                  GroupDisplayTypeBack, GroupDisplayTypeDisc,
                                  GroupDisplayTypeArtist};
        for (GroupDisplayType t : all) {
            NSString *s = [GroupPreset stringFromDisplayType:t];
            CHECK_EQ([GroupPreset displayTypeFromString:s], t, "display type round trip");
        }
    }

    // ------------------------------------------------------- subgroupPattern
    //
    // The getter and setter are the single-valued face the preferences page
    // puts on the subgroups array, and they must be mirror images. A non-empty
    // value used to edit subgroups[0] while an empty value assigned @[] — so a
    // preset defining two or more subgroups lost all of them the first time the
    // field was cleared, invisibly, because the UI only ever shows subgroup 0.
    {
        g_context = "subgroup-pattern-empty-preset";
        GroupPreset *p = [GroupPreset presetWithName:@"P"];
        CHECK([[p subgroupPattern] isEqualToString:@""], "empty array reads as empty");

        [p setSubgroupPattern:@"[Disc %discnumber%]"];
        CHECK_EQ(p.subgroups.count, 1, "setting on an empty preset creates one subgroup");
        CHECK([[p subgroupPattern] isEqualToString:@"[Disc %discnumber%]"], "reads back");
        CHECK_EQ(p.subgroups[0].displayType, GroupDisplayTypeText, "created as text");

        // Clearing an empty preset must not fabricate an entry.
        GroupPreset *q = [GroupPreset presetWithName:@"Q"];
        [q setSubgroupPattern:@""];
        CHECK_EQ(q.subgroups.count, 0, "clearing an empty preset creates nothing");
    }

    {
        g_context = "subgroup-pattern-single";
        GroupPreset *p = [GroupPreset presetWithName:@"P"];
        p.subgroups = @[[SubgroupDefinition subgroupWithPattern:@"[Disc %discnumber%]"
                                                    displayType:GroupDisplayTypeDisc]];

        [p setSubgroupPattern:@"%genre%"];
        CHECK_EQ(p.subgroups.count, 1, "still one subgroup");
        CHECK([[p subgroupPattern] isEqualToString:@"%genre%"], "pattern replaced");
        CHECK_EQ(p.subgroups[0].displayType, GroupDisplayTypeDisc,
                 "display type preserved across a pattern edit");

        [p setSubgroupPattern:@""];
        CHECK([[p subgroupPattern] isEqualToString:@""], "reads back as empty");
        // Consumers gate on subgroupPattern.length, so an empty element 0
        // disables subgrouping exactly as an empty array did.
        CHECK_EQ([p subgroupPattern].length, 0, "subgrouping disabled");
    }

    {
        g_context = "subgroup-pattern-multi-no-data-loss";
        GroupPreset *p = [GroupPreset presetWithName:@"P"];
        p.subgroups = @[
            [SubgroupDefinition subgroupWithPattern:@"[Disc %discnumber%]" displayType:GroupDisplayTypeDisc],
            [SubgroupDefinition subgroupWithPattern:@"%genre%" displayType:GroupDisplayTypeText],
            [SubgroupDefinition subgroupWithPattern:@"%year%" displayType:GroupDisplayTypeText],
        ];

        // This is the regression: clearing the single-line preferences field
        // must not take the other two subgroups with it.
        [p setSubgroupPattern:@""];
        CHECK_EQ(p.subgroups.count, 3, "siblings survive a clear");
        CHECK([p.subgroups[1].pattern isEqualToString:@"%genre%"], "sibling 1 intact");
        CHECK([p.subgroups[2].pattern isEqualToString:@"%year%"], "sibling 2 intact");
        CHECK([[p subgroupPattern] isEqualToString:@""], "and the field still reads empty");

        // Setting a value again edits element 0 only, as the getter implies.
        [p setSubgroupPattern:@"%album%"];
        CHECK_EQ(p.subgroups.count, 3, "still three");
        CHECK([[p subgroupPattern] isEqualToString:@"%album%"], "element 0 updated");
        CHECK([p.subgroups[1].pattern isEqualToString:@"%genre%"], "sibling 1 still intact");
    }

    {
        g_context = "subgroup-pattern-nil";
        GroupPreset *p = [GroupPreset presetWithName:@"P"];
        p.subgroups = @[[SubgroupDefinition subgroupWithPattern:@"%x%"
                                                    displayType:GroupDisplayTypeText]];
        [p setSubgroupPattern:nilString()];
        CHECK([[p subgroupPattern] isEqualToString:@""], "nil is treated as clear, not stored");
        CHECK_EQ(p.subgroups.count, 1, "subgroup kept");
    }

    // ----------------------------------------------------- activeIndexFromJSON
    {
        g_context = "active-index";
        CHECK_EQ([GroupPreset activeIndexFromJSON:nilString()], 0, "nil -> 0");
        CHECK_EQ([GroupPreset activeIndexFromJSON:@""], 0, "empty -> 0");
        CHECK_EQ([GroupPreset activeIndexFromJSON:@"not json"], 0, "garbage -> 0");
        CHECK_EQ([GroupPreset activeIndexFromJSON:@"[1,2]"], 0, "top-level array -> 0");
        CHECK_EQ([GroupPreset activeIndexFromJSON:@"{}"], 0, "missing key -> 0");
        CHECK_EQ([GroupPreset activeIndexFromJSON:@"{\"active_index\":\"2\"}"], 0, "string value -> 0");
        CHECK_EQ([GroupPreset activeIndexFromJSON:@"{\"active_index\":null}"], 0, "null value -> 0");
        CHECK_EQ([GroupPreset activeIndexFromJSON:@"{\"active_index\":2}"], 2, "integer read");

        // Out-of-range values are NOT clamped here — callers clamp against
        // their own preset count, which this function does not know.
        CHECK_EQ([GroupPreset activeIndexFromJSON:@"{\"active_index\":99}"], 99, "large value passed through");
        CHECK_EQ([GroupPreset activeIndexFromJSON:@"{\"active_index\":-3}"], -3, "negative passed through");
    }

    // ------------------------------------------------------------ JSON: read
    {
        g_context = "fromJSON-garbage";
        checkArray([GroupPreset presetsFromJSON:nilString()], @[], "nil -> empty");
        checkArray([GroupPreset presetsFromJSON:@""], @[], "empty -> empty");
        checkArray([GroupPreset presetsFromJSON:@"nope"], @[], "garbage -> empty");
        checkArray([GroupPreset presetsFromJSON:@"[{\"name\":\"A\"}]"], @[], "top-level array -> empty");
        checkArray([GroupPreset presetsFromJSON:@"{}"], @[], "no presets key -> empty");
        checkArray([GroupPreset presetsFromJSON:@"{\"presets\":\"x\"}"], @[], "presets not an array -> empty");
    }

    {
        g_context = "fromJSON-shape";
        NSString *json = @"{\"active_index\":1,\"presets\":["
                          "{\"name\":\"Album\",\"sorting_pattern\":\"%path_sort%\","
                           "\"header\":{\"pattern\":\"%album%\",\"display\":\"front\"},"
                           "\"group_column\":{\"pattern\":\"[%album%]\",\"display\":\"back\"},"
                           "\"subgroups\":[{\"pattern\":\"[Disc %discnumber%]\",\"display\":\"disc\"}]},"
                          "{\"name\":\"Artist\"}"
                          "]}";
        NSArray<GroupPreset *> *presets = [GroupPreset presetsFromJSON:json];
        CHECK_EQ(presets.count, 2, "both presets parsed");
        checkArray(namesOf(presets), (@[@"Album", @"Artist"]), "names and order");

        GroupPreset *a = presets[0];
        CHECK([a.headerPattern isEqualToString:@"%album%"], "header pattern");
        CHECK_EQ(a.headerDisplayType, GroupDisplayTypeFront, "header display");
        CHECK([a.groupColumnPattern isEqualToString:@"[%album%]"], "group column pattern");
        CHECK_EQ(a.groupColumnDisplayType, GroupDisplayTypeBack, "group column display");
        CHECK_EQ(a.subgroups.count, 1, "subgroup parsed");
        CHECK([a.subgroups[0].pattern isEqualToString:@"[Disc %discnumber%]"], "subgroup pattern");
        CHECK_EQ(a.subgroups[0].displayType, GroupDisplayTypeDisc, "subgroup display");

        CHECK_EQ([GroupPreset activeIndexFromJSON:json], 1, "active index alongside presets");
    }

    {
        g_context = "fromJSON-hostile-entries";
        // Wrong types anywhere must not send messages to objects that cannot
        // take them; bad entries are skipped or fall back to defaults.
        NSString *json = @"{\"presets\":["
                          "\"a bare string\","
                          "{\"name\":7},"
                          "{\"name\":\"OK\",\"header\":\"not a dict\","
                           "\"group_column\":42,\"subgroups\":\"not an array\"},"
                          "{\"name\":\"Subs\",\"subgroups\":[\"x\",{\"pattern\":5},"
                           "{\"pattern\":\"%good%\"}]}"
                          "]}";
        NSArray<GroupPreset *> *presets = [GroupPreset presetsFromJSON:json];
        CHECK(presets.count >= 2, "well-formed entries survive");

        GroupPreset *ok = nil, *subs = nil;
        for (GroupPreset *p in presets) {
            if ([p.name isEqualToString:@"OK"]) ok = p;
            if ([p.name isEqualToString:@"Subs"]) subs = p;
        }
        CHECK(ok != nil, "entry with bad sub-dictionaries still parsed");
        if (ok) {
            CHECK([ok.headerPattern isEqualToString:@""], "bad header dict -> default");
            CHECK_EQ(ok.subgroups.count, 0, "bad subgroups value -> none");
        }
        CHECK(subs != nil, "entry with mixed subgroups parsed");
        if (subs) {
            CHECK_EQ(subs.subgroups.count, 1, "only the well-typed subgroup kept");
            CHECK([subs.subgroups[0].pattern isEqualToString:@"%good%"], "the right one kept");
        }
    }

    // ----------------------------------------------------------- JSON: write
    {
        g_context = "toJSON-round-trip";
        GroupPreset *a = [GroupPreset presetWithName:@"Album"];
        a.headerPattern = @"[$if2(%album artist%,%artist%) - ][%album%]";
        a.headerDisplayType = GroupDisplayTypeFront;
        a.groupColumnPattern = @"[%album%]";
        a.groupColumnDisplayType = GroupDisplayTypeDisc;
        a.sortingPattern = @"%path_sort%";
        a.subgroups = @[
            [SubgroupDefinition subgroupWithPattern:@"[Disc %discnumber%]" displayType:GroupDisplayTypeDisc],
            [SubgroupDefinition subgroupWithPattern:@"%genre%" displayType:GroupDisplayTypeText],
        ];
        GroupPreset *b = [GroupPreset presetWithName:@"Artist"];
        b.headerPattern = @"%artist%";

        NSString *json = [GroupPreset presetsToJSON:@[a, b] activeIndex:1];
        CHECK(json != nil, "serialises");

        NSArray<GroupPreset *> *out = [GroupPreset presetsFromJSON:json];
        CHECK_EQ(out.count, 2, "both come back");
        checkArray(namesOf(out), (@[@"Album", @"Artist"]), "names and order preserved");
        CHECK_EQ([GroupPreset activeIndexFromJSON:json], 1, "active index preserved");

        GroupPreset *ra = out[0];
        CHECK([ra.headerPattern isEqualToString:a.headerPattern], "header pattern preserved");
        CHECK_EQ(ra.headerDisplayType, GroupDisplayTypeFront, "header display preserved");
        CHECK([ra.groupColumnPattern isEqualToString:@"[%album%]"], "group column preserved");
        CHECK_EQ(ra.groupColumnDisplayType, GroupDisplayTypeDisc, "group column display preserved");
        CHECK([ra.sortingPattern isEqualToString:@"%path_sort%"], "sorting preserved");

        // Both subgroups must survive, even though the UI only shows the first.
        CHECK_EQ(ra.subgroups.count, 2, "both subgroups preserved");
        CHECK([ra.subgroups[0].pattern isEqualToString:@"[Disc %discnumber%]"], "subgroup 0 pattern");
        CHECK_EQ(ra.subgroups[0].displayType, GroupDisplayTypeDisc, "subgroup 0 display");
        CHECK([ra.subgroups[1].pattern isEqualToString:@"%genre%"], "subgroup 1 pattern");
    }

    {
        g_context = "toJSON-cleared-subgroup-round-trip";
        // The empty pattern left in element 0 by -setSubgroupPattern:@"" has to
        // survive persistence, or the fix only holds until the next restart.
        GroupPreset *p = [GroupPreset presetWithName:@"P"];
        p.subgroups = @[
            [SubgroupDefinition subgroupWithPattern:@"[Disc %discnumber%]" displayType:GroupDisplayTypeDisc],
            [SubgroupDefinition subgroupWithPattern:@"%genre%" displayType:GroupDisplayTypeText],
        ];
        [p setSubgroupPattern:@""];

        NSString *json = [GroupPreset presetsToJSON:@[p] activeIndex:0];
        GroupPreset *reread = [GroupPreset presetsFromJSON:json][0];
        CHECK_EQ(reread.subgroups.count, 2, "sibling survives the save/load cycle");
        CHECK([[reread subgroupPattern] isEqualToString:@""], "still reads as cleared");
        CHECK([reread.subgroups[1].pattern isEqualToString:@"%genre%"], "sibling content intact");
    }

    {
        g_context = "toJSON-edges";
        NSString *empty = [GroupPreset presetsToJSON:@[] activeIndex:0];
        CHECK(empty != nil, "empty list serialises");
        checkArray([GroupPreset presetsFromJSON:empty], @[], "and reads back empty");

        // Convenience overload pins the active index at 0.
        GroupPreset *p = [GroupPreset presetWithName:@"Only"];
        CHECK_EQ([GroupPreset activeIndexFromJSON:[GroupPreset presetsToJSON:@[p]]], 0,
                 "one-argument overload writes index 0");

        // nil name/pattern would crash the dictionary assignment.
        GroupPreset *nils = [GroupPreset presetWithName:@"X"];
        nils.name = nilString();
        nils.headerPattern = nilString();
        nils.groupColumnPattern = nilString();
        nils.sortingPattern = nilString();
        NSString *json = [GroupPreset presetsToJSON:@[nils] activeIndex:0];
        CHECK(json != nil, "nil fields serialise");
        NSArray<GroupPreset *> *out = [GroupPreset presetsFromJSON:json];
        CHECK_EQ(out.count, 1, "and read back");
        CHECK([out[0].name isEqualToString:@""], "nil name becomes empty");
        CHECK([out[0].headerPattern isEqualToString:@""], "nil header becomes empty");
    }

    }
    TEST_MAIN_END();
}
