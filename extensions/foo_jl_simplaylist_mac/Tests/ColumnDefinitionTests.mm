//
//  ColumnDefinitionTests.mm
//  foo_simplaylist_mac
//
//  Unit tests for the ColumnDefinition model, its JSON codec and the pure
//  layout transforms behind the config-backed Store category.
//
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//  Nothing here touches the config store — ColumnDefinition.mm is deliberately
//  free of the foobar2000 SDK, and everything that is not lives in
//  ColumnDefinitionStore.mm, which these tests never link.
//
//  What this covers that nothing did before: the corrupt-config hardening in
//  columnsFromJSON:, the NaN/Inf width clamps on both the read and write paths,
//  and both silent data migrations — including the Playing-column one that
//  someone has to delete at the end of 2026 and until now had no test to
//  confirm removing it is safe.
//

#import <Foundation/Foundation.h>
#import "../src/Core/ColumnDefinition.h"
#import "TestHarness.h"

// -Wnonnull fires on a *literal* nil passed to a parameter inside an
// NS_ASSUME_NONNULL region. Several tests below pass nil on purpose: the
// annotations state the contract callers ought to honour, and neither a corrupt
// config nor a buggy caller honours anything. Routing nil through an opaque
// function keeps the diagnostic enabled for real code while letting the
// hostile-input tests say exactly what they mean.
static NSString *nilString(void) { return nil; }

static ColumnDefinition *col(NSString *name, NSString *pattern, CGFloat width) {
    return [ColumnDefinition columnWithName:name
                                    pattern:pattern
                                      width:width
                                  alignment:ColumnAlignmentLeft];
}

static NSArray<NSString *> *namesOf(NSArray<ColumnDefinition *> *columns) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (ColumnDefinition *c in columns) [names addObject:c.name];
    return names;
}

// Round-trip a column array through the codec and hand back what comes out.
static NSArray<ColumnDefinition *> *roundTrip(NSArray<ColumnDefinition *> *columns) {
    NSString *json = [ColumnDefinition columnsToJSON:columns];
    return [ColumnDefinition columnsFromJSON:json];
}

int main(void) {
    @autoreleasepool {

    // ---------------------------------------------------------------- model
    {
        g_context = "model-defaults";
        ColumnDefinition *c = [[ColumnDefinition alloc] init];
        CHECK([c.name isEqualToString:@""], "name defaults to empty");
        CHECK([c.pattern isEqualToString:@""], "pattern defaults to empty");
        CHECK_FLOAT_EQ(c.width, 100, "width default");
        CHECK_FLOAT_EQ(c.minWidth, 30, "minWidth default");
        CHECK_EQ(c.alignment, ColumnAlignmentLeft, "alignment default");
        CHECK(!c.autoResize, "autoResize default off");
        CHECK(!c.clickable, "clickable default off");
    }

    {
        g_context = "model-copy";
        ColumnDefinition *c = col(@"Title", @"%title%", 250);
        c.autoResize = YES;
        c.clickable = YES;
        c.minWidth = 44;
        c.alignment = ColumnAlignmentRight;

        ColumnDefinition *copy = [c copy];
        CHECK(copy != c, "copy is a distinct object");
        CHECK([copy.name isEqualToString:@"Title"], "copy carries name");
        CHECK([copy.pattern isEqualToString:@"%title%"], "copy carries pattern");
        CHECK_FLOAT_EQ(copy.width, 250, "copy carries width");
        CHECK_FLOAT_EQ(copy.minWidth, 44, "copy carries minWidth");
        CHECK_EQ(copy.alignment, ColumnAlignmentRight, "copy carries alignment");
        CHECK(copy.autoResize, "copy carries autoResize");
        CHECK(copy.clickable, "copy carries clickable");

        // Mutating the copy must not reach back into the original — the rename
        // transform relies on this to avoid editing a layout a panel is using.
        copy.name = @"Other";
        CHECK([c.name isEqualToString:@"Title"], "original unaffected by copy mutation");
    }

    {
        g_context = "alignment-strings";
        CHECK_EQ([ColumnDefinition alignmentFromString:@"center"], ColumnAlignmentCenter, "center");
        CHECK_EQ([ColumnDefinition alignmentFromString:@"right"], ColumnAlignmentRight, "right");
        CHECK_EQ([ColumnDefinition alignmentFromString:@"left"], ColumnAlignmentLeft, "left");
        // Case-insensitive, and anything unrecognised falls back to left.
        CHECK_EQ([ColumnDefinition alignmentFromString:@"RIGHT"], ColumnAlignmentRight, "uppercase right");
        CHECK_EQ([ColumnDefinition alignmentFromString:@"sideways"], ColumnAlignmentLeft, "unknown -> left");
        CHECK_EQ([ColumnDefinition alignmentFromString:@""], ColumnAlignmentLeft, "empty -> left");

        CHECK([[ColumnDefinition stringFromAlignment:ColumnAlignmentCenter] isEqualToString:@"center"], "to center");
        CHECK([[ColumnDefinition stringFromAlignment:ColumnAlignmentRight] isEqualToString:@"right"], "to right");
        CHECK([[ColumnDefinition stringFromAlignment:ColumnAlignmentLeft] isEqualToString:@"left"], "to left");

        // Every alignment must survive a string round trip, or a persisted
        // layout silently left-aligns on reload.
        ColumnAlignment all[] = {ColumnAlignmentLeft, ColumnAlignmentCenter, ColumnAlignmentRight};
        for (ColumnAlignment a : all) {
            NSString *s = [ColumnDefinition stringFromAlignment:a];
            CHECK_EQ([ColumnDefinition alignmentFromString:s], a, "alignment round trip");
        }
    }

    // ------------------------------------------------------------ JSON: read
    {
        g_context = "fromJSON-garbage";
        checkArray([ColumnDefinition columnsFromJSON:nilString()], @[], "nil -> empty");
        checkArray([ColumnDefinition columnsFromJSON:@""], @[], "empty string -> empty");
        checkArray([ColumnDefinition columnsFromJSON:@"not json at all"], @[], "non-JSON -> empty");
        checkArray([ColumnDefinition columnsFromJSON:@"{"], @[], "truncated -> empty");

        // A top-level array parses as valid JSON but is not a dictionary;
        // subscripting it would raise on every panel construction.
        checkArray([ColumnDefinition columnsFromJSON:@"[1,2,3]"], @[], "top-level array -> empty");
        checkArray([ColumnDefinition columnsFromJSON:@"\"a string\""], @[], "top-level string -> empty");
        checkArray([ColumnDefinition columnsFromJSON:@"{}"], @[], "no columns key -> empty");
        checkArray([ColumnDefinition columnsFromJSON:@"{\"columns\":\"nope\"}"], @[], "columns not an array -> empty");
        checkArray([ColumnDefinition columnsFromJSON:@"{\"columns\":{}}"], @[], "columns is a dict -> empty");
    }

    {
        g_context = "fromJSON-entry-types";
        // Corrupted entries are skipped individually; the good ones survive.
        NSString *json = @"{\"columns\":["
                          "{\"name\":\"Good\",\"pattern\":\"%title%\",\"width\":120},"
                          "\"just a string\","
                          "{\"name\":42,\"pattern\":\"%x%\"},"
                          "{\"name\":\"NoPattern\"},"
                          "{\"name\":\"BadPattern\",\"pattern\":[1,2]},"
                          "{\"name\":\"AlsoGood\",\"pattern\":\"%artist%\"}"
                          "]}";
        NSArray<ColumnDefinition *> *cols = [ColumnDefinition columnsFromJSON:json];
        checkArray(namesOf(cols), (@[@"Good", @"AlsoGood"]), "only well-typed entries kept");
        CHECK_FLOAT_EQ(cols[0].width, 120, "width parsed");
        CHECK_FLOAT_EQ(cols[1].width, 100, "missing width -> default");
    }

    {
        g_context = "fromJSON-field-types";
        // Wrong types on optional fields fall back to defaults rather than
        // being sent messages they do not respond to.
        NSString *json = @"{\"columns\":[{"
                          "\"name\":\"C\",\"pattern\":\"%p%\","
                          "\"width\":\"wide\",\"alignment\":7,"
                          "\"auto_resize\":\"yes\",\"clickable\":[]"
                          "}]}";
        NSArray<ColumnDefinition *> *cols = [ColumnDefinition columnsFromJSON:json];
        CHECK_EQ(cols.count, 1, "entry survives bad optional fields");
        CHECK_FLOAT_EQ(cols[0].width, 100, "non-number width -> default");
        CHECK_EQ(cols[0].alignment, ColumnAlignmentLeft, "non-string alignment -> left");
        CHECK(!cols[0].autoResize, "non-number auto_resize -> NO");
        CHECK(!cols[0].clickable, "non-number clickable -> NO");
    }

    {
        g_context = "fromJSON-width-clamp";
        // Persisted widths are known to go bad; they flow into NSRect math and
        // hit-testing, so the read path clamps them.
        NSString *json = @"{\"columns\":["
                          "{\"name\":\"Zero\",\"pattern\":\"\",\"width\":0},"
                          "{\"name\":\"Negative\",\"pattern\":\"\",\"width\":-500},"
                          "{\"name\":\"Huge\",\"pattern\":\"\",\"width\":1e9},"
                          "{\"name\":\"Small\",\"pattern\":\"\",\"width\":24}"
                          "]}";
        NSArray<ColumnDefinition *> *cols = [ColumnDefinition columnsFromJSON:json];
        CHECK_EQ(cols.count, 4, "all four entries kept");
        CHECK_FLOAT_EQ(cols[0].width, 100, "zero width -> default");
        CHECK_FLOAT_EQ(cols[1].width, 100, "negative width -> default");
        CHECK_FLOAT_EQ(cols[2].width, 10000, "huge width capped");
        // No higher floor: stock columns legitimately persist widths of 24.
        CHECK_FLOAT_EQ(cols[3].width, 24, "small but legitimate width preserved");
    }

    {
        g_context = "fromJSON-track-no-migration";
        // "Track no" was replaced by "#" in v1.1.7; a stored layout containing
        // both must not end up with a duplicate column.
        NSString *json = @"{\"columns\":["
                          "{\"name\":\"Track no\",\"pattern\":\"%tracknumber%\"},"
                          "{\"name\":\"#\",\"pattern\":\"%tracknumber%\"},"
                          "{\"name\":\"Title\",\"pattern\":\"%title%\"}"
                          "]}";
        checkArray(namesOf([ColumnDefinition columnsFromJSON:json]),
                   (@[@"#", @"Title"]), "legacy Track no dropped");
    }

    // ----------------------------------------------------------- JSON: write
    {
        g_context = "toJSON-round-trip";
        ColumnDefinition *a = col(@"Title", @"%title%", 250);
        a.autoResize = YES;
        a.alignment = ColumnAlignmentLeft;
        ColumnDefinition *b = col(@"Duration", @"%length%", 50);
        b.alignment = ColumnAlignmentRight;
        ColumnDefinition *c = col(@"Rating", @"%rating%", 70);
        c.alignment = ColumnAlignmentCenter;
        c.clickable = YES;

        NSArray<ColumnDefinition *> *out = roundTrip(@[a, b, c]);
        CHECK_EQ(out.count, 3, "all columns survive the round trip");
        checkArray(namesOf(out), (@[@"Title", @"Duration", @"Rating"]), "order preserved");
        CHECK([out[0].pattern isEqualToString:@"%title%"], "pattern preserved");
        CHECK_FLOAT_EQ(out[0].width, 250, "width preserved");
        CHECK(out[0].autoResize, "autoResize preserved");
        CHECK_EQ(out[1].alignment, ColumnAlignmentRight, "right alignment preserved");
        CHECK_EQ(out[2].alignment, ColumnAlignmentCenter, "center alignment preserved");
        CHECK(out[2].clickable, "clickable preserved");
        CHECK(!out[1].clickable, "clickable stays off when not set");
    }

    {
        g_context = "toJSON-empty";
        // An empty column list is a legitimate value and must serialise to a
        // non-empty document — the persist funnel treats empty output as
        // failure, because storing "" is the config store's DELETE idiom.
        NSString *json = [ColumnDefinition columnsToJSON:@[]];
        CHECK(json != nil, "empty list serialises to non-nil");
        CHECK(json.length > 0, "empty list serialises to non-empty string");
        checkArray([ColumnDefinition columnsFromJSON:json], @[], "and reads back as empty");
    }

    {
        g_context = "toJSON-nan-width";
        // +dataWithJSONObject: RAISES for a NaN or infinite value rather than
        // setting `error`, so an unclamped width would take down the caller.
        // The write path applies the same fallback as the read path.
        ColumnDefinition *nan = col(@"NaN", @"%x%", NAN);
        ColumnDefinition *inf = col(@"Inf", @"%y%", INFINITY);
        ColumnDefinition *neg = col(@"Neg", @"%z%", -1);

        NSString *json = [ColumnDefinition columnsToJSON:@[nan, inf, neg]];
        CHECK(json != nil, "non-finite widths do not fail serialisation");

        NSArray<ColumnDefinition *> *out = [ColumnDefinition columnsFromJSON:json];
        CHECK_EQ(out.count, 3, "all three survive");
        CHECK_FLOAT_EQ(out[0].width, 100, "NaN width written as default");
        CHECK_FLOAT_EQ(out[1].width, 100, "Inf width written as default");
        CHECK_FLOAT_EQ(out[2].width, 100, "negative width written as default");
    }

    {
        g_context = "toJSON-nil-fields";
        // name/pattern are `copy` properties that can still be set to nil;
        // a nil value in the dictionary literal would crash.
        ColumnDefinition *c = [[ColumnDefinition alloc] init];
        c.name = nilString();
        c.pattern = nilString();
        NSString *json = [ColumnDefinition columnsToJSON:@[c]];
        CHECK(json != nil, "nil name/pattern serialise");
        NSArray<ColumnDefinition *> *out = [ColumnDefinition columnsFromJSON:json];
        CHECK_EQ(out.count, 1, "entry round trips");
        CHECK([out[0].name isEqualToString:@""], "nil name becomes empty");
        CHECK([out[0].pattern isEqualToString:@""], "nil pattern becomes empty");
    }

    // ------------------------------------------------------ orphan filtering
    {
        g_context = "filter-known-names";
        NSArray<ColumnDefinition *> *layout = @[
            col(@"Title", @"%title%", 250),
            col(@"MyCustom", @"%custom%", 100),
            col(@"Deleted", @"%gone%", 100),
            col(@"Duration", @"%length%", 50),
        ];
        NSSet<NSString *> *known = [NSSet setWithArray:@[@"Title", @"Duration", @"MyCustom"]];

        NSArray<ColumnDefinition *> *kept = [ColumnDefinition columns:layout
                                                filteredToKnownNames:known];
        checkArray(namesOf(kept), (@[@"Title", @"MyCustom", @"Duration"]),
                   "unknown name dropped, order preserved");
        CHECK_EQ(layout.count, 4, "input array not mutated");

        // Identity, not equality: the survivors are the same objects, so a
        // caller holding one still sees its live width.
        CHECK(kept[0] == layout[0], "survivors are the same objects");
    }

    {
        g_context = "filter-edges";
        NSArray<ColumnDefinition *> *layout = @[col(@"A", @"", 10), col(@"B", @"", 10)];
        checkArray(namesOf([ColumnDefinition columns:layout filteredToKnownNames:[NSSet set]]),
                   @[], "empty known set drops everything");
        checkArray(namesOf([ColumnDefinition columns:@[] filteredToKnownNames:[NSSet setWithObject:@"A"]]),
                   @[], "empty layout stays empty");

        // A nil name cannot match anything and must not crash the set lookup.
        ColumnDefinition *nameless = [[ColumnDefinition alloc] init];
        nameless.name = nilString();
        checkArray(namesOf([ColumnDefinition columns:@[nameless]
                               filteredToKnownNames:[NSSet setWithObject:@"A"]]),
                   @[], "nil name is never known");
    }

    // -------------------------------------------------------------- renaming
    {
        g_context = "rename";
        NSArray<ColumnDefinition *> *layout = @[
            col(@"Title", @"%title%", 250),
            col(@"OldName", @"%custom%", 100),
            col(@"Duration", @"%length%", 50),
        ];

        NSArray<ColumnDefinition *> *renamed = [ColumnDefinition columns:layout
                                                            renamedFrom:@"OldName"
                                                                     to:@"NewName"];
        CHECK(renamed != nil, "matching rename returns a result");
        checkArray(namesOf(renamed), (@[@"Title", @"NewName", @"Duration"]),
                   "renamed in place, order preserved");

        // The original must be untouched: it may still be the layout a live
        // panel is drawing from.
        checkArray(namesOf(layout), (@[@"Title", @"OldName", @"Duration"]),
                   "source array unchanged");
        CHECK(renamed[1] != layout[1], "renamed entry is a copy");
        CHECK(renamed[0] == layout[0], "untouched entries are shared, not copied");
        CHECK_FLOAT_EQ(renamed[1].width, 100, "rename preserves width");
        CHECK([renamed[1].pattern isEqualToString:@"%custom%"], "rename preserves pattern");
    }

    {
        g_context = "rename-no-op";
        NSArray<ColumnDefinition *> *layout = @[col(@"Title", @"%title%", 250)];
        // nil means "nothing changed", which is what lets the caller skip the
        // persist entirely rather than rewriting an identical layout.
        CHECK([ColumnDefinition columns:layout renamedFrom:@"Absent" to:@"X"] == nil,
              "no match -> nil");
        CHECK([ColumnDefinition columns:layout renamedFrom:@"Title" to:@"Title"] == nil,
              "same name -> nil");
        CHECK([ColumnDefinition columns:layout renamedFrom:nilString() to:@"X"] == nil,
              "nil old name -> nil");
        CHECK([ColumnDefinition columns:layout renamedFrom:@"Title" to:nilString()] == nil,
              "nil new name -> nil");
        CHECK([ColumnDefinition columns:@[] renamedFrom:@"A" to:@"B"] == nil,
              "empty layout -> nil");
    }

    {
        g_context = "rename-duplicates";
        // Two visible columns can carry the same custom name; both must move.
        NSArray<ColumnDefinition *> *layout = @[
            col(@"Dup", @"%a%", 10),
            col(@"Other", @"%b%", 20),
            col(@"Dup", @"%c%", 30),
        ];
        NSArray<ColumnDefinition *> *renamed = [ColumnDefinition columns:layout
                                                            renamedFrom:@"Dup"
                                                                     to:@"Fresh"];
        checkArray(namesOf(renamed), (@[@"Fresh", @"Other", @"Fresh"]), "every match renamed");
        CHECK_FLOAT_EQ(renamed[0].width, 10, "first keeps its own width");
        CHECK_FLOAT_EQ(renamed[2].width, 30, "second keeps its own width");
    }

    // --------------------------------------------- Playing-column migration
    // TODO(2026): this whole block goes when the migration is deleted. Its
    // purpose is to make that deletion safe to do.
    {
        g_context = "playing-migration";
        NSString *const legacy = @"$if(%isplaying%,>,)";
        NSArray<ColumnDefinition *> *layout = @[
            col(@"Playing", legacy, 24),
            col(@"Title", @"%title%", 250),
        ];

        NSArray<ColumnDefinition *> *migrated =
            [ColumnDefinition columnsByMigratingLegacyPlayingPattern:layout];
        CHECK(migrated != nil, "legacy pattern triggers migration");
        CHECK([migrated[0].pattern isEqualToString:@""], "legacy pattern cleared");
        CHECK([migrated[0].name isEqualToString:@"Playing"], "name untouched");
        CHECK_FLOAT_EQ(migrated[0].width, 24, "width untouched");
        CHECK([migrated[1].pattern isEqualToString:@"%title%"], "other columns untouched");

        // Source untouched, as with the rename.
        CHECK([layout[0].pattern isEqualToString:legacy], "source array unchanged");
    }

    {
        g_context = "playing-migration-no-op";
        NSString *const legacy = @"$if(%isplaying%,>,)";
        CHECK([ColumnDefinition columnsByMigratingLegacyPlayingPattern:@[]] == nil,
              "empty layout -> nil");
        CHECK([ColumnDefinition columnsByMigratingLegacyPlayingPattern:
                   @[col(@"Playing", @"", 24)]] == nil,
              "already-migrated Playing -> nil");
        CHECK([ColumnDefinition columnsByMigratingLegacyPlayingPattern:
                   @[col(@"Title", @"%title%", 250)]] == nil,
              "unrelated columns -> nil");

        // The pattern only migrates on a column actually named Playing: a user
        // could have put the same title-format string in a column of their own.
        CHECK([ColumnDefinition columnsByMigratingLegacyPlayingPattern:
                   @[col(@"MyIndicator", legacy, 24)]] == nil,
              "legacy pattern under another name is left alone");
        // ...and a Playing column with a different pattern is the user's, too.
        CHECK([ColumnDefinition columnsByMigratingLegacyPlayingPattern:
                   @[col(@"Playing", @"%isplaying%", 24)]] == nil,
              "Playing with a different pattern is left alone");
    }

    {
        g_context = "migration-is-idempotent";
        // +defaultColumns runs orphan cleanup and this migration on every
        // launch, so a second pass over already-repaired output must report
        // nothing to do — otherwise every launch rewrites the config.
        NSArray<ColumnDefinition *> *layout = @[col(@"Playing", @"$if(%isplaying%,>,)", 24)];
        NSArray<ColumnDefinition *> *once =
            [ColumnDefinition columnsByMigratingLegacyPlayingPattern:layout];
        CHECK(once != nil, "first pass migrates");
        CHECK([ColumnDefinition columnsByMigratingLegacyPlayingPattern:once] == nil,
              "second pass is a no-op");
    }

    {
        g_context = "repair-survives-round-trip";
        // The full +defaultColumns shape: read, filter, migrate, write back,
        // read again. What comes out must equal what went in after repair.
        NSArray<ColumnDefinition *> *stored = @[
            col(@"Playing", @"$if(%isplaying%,>,)", 24),
            col(@"Title", @"%title%", 250),
            col(@"Ghost", @"%gone%", 100),
        ];
        NSSet<NSString *> *known = [NSSet setWithArray:@[@"Playing", @"Title"]];

        NSArray<ColumnDefinition *> *repaired =
            [ColumnDefinition columns:stored filteredToKnownNames:known];
        NSArray<ColumnDefinition *> *migrated =
            [ColumnDefinition columnsByMigratingLegacyPlayingPattern:repaired];
        if (migrated) repaired = migrated;

        checkArray(namesOf(repaired), (@[@"Playing", @"Title"]), "orphan gone");
        CHECK([repaired[0].pattern isEqualToString:@""], "migration applied");

        NSArray<ColumnDefinition *> *reread = roundTrip(repaired);
        checkArray(namesOf(reread), (@[@"Playing", @"Title"]), "names survive persistence");
        CHECK([reread[0].pattern isEqualToString:@""], "cleared pattern survives persistence");
        CHECK_FLOAT_EQ(reread[0].width, 24, "width survives persistence");
        // And the next launch finds nothing left to repair.
        CHECK([ColumnDefinition columnsByMigratingLegacyPlayingPattern:reread] == nil,
              "no further migration after a save/load cycle");
    }

    // ------------------------------------------------------------- templates
    {
        g_context = "available-templates";
        NSArray<ColumnDefinition *> *templates = [ColumnDefinition availableColumnTemplates];
        CHECK(templates.count > 0, "templates are non-empty");

        // The chooser menu keys on name, and orphan cleanup matches on it too:
        // a duplicate would make one template unreachable and mask an orphan.
        NSSet<NSString *> *names = [NSSet setWithArray:namesOf(templates)];
        CHECK_EQ(names.count, templates.count, "template names are unique");

        for (ColumnDefinition *t in templates) {
            CHECK(t.name.length > 0, "template has a name");
            CHECK(t.width > 0, "template has a positive width");
        }

        // Templates must round-trip: they are what a freshly added column
        // persists as.
        NSArray<ColumnDefinition *> *out = roundTrip(templates);
        checkArray(namesOf(out), namesOf(templates), "templates survive the codec");
    }

    }
    TEST_MAIN_END();
}
