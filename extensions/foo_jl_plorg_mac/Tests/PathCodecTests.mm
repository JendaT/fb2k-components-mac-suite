//
//  PathCodecTests.mm
//  foo_plorg_mac
//
//  Unit tests for PathCodec (guillemet escaping, path-encoded name codec).
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/PathCodec.h"

#include <string>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what)                                                        \
    do {                                                                         \
        g_checks++;                                                             \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            printf("FAIL [%s] %s\n", g_context.c_str(), what);                  \
        }                                                                       \
    } while (0)

static BOOL objEq(id a, id b) {
    return (a == b) || [a isEqual:b];
}

#define CHECK_EQ(got, want, what)                                                \
    do {                                                                         \
        g_checks++;                                                             \
        if (!objEq((got), (want))) {                                            \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got %s, expected %s\n", g_context.c_str(),    \
                   what, [(got) description].UTF8String ?: "(nil)",             \
                   [(want) description].UTF8String ?: "(nil)");                 \
        }                                                                        \
    } while (0)

static NSString *guil(void) {
    unichar c = 0x00BB;
    return [NSString stringWithCharacters:&c length:1];
}

int main(void) {
    @autoreleasepool {

    NSString *sep = PlorgPathSeparator;
    NSString *g = guil();

    // --- Escaping ---
    {
        g_context = "escape";
        CHECK_EQ([PathCodec escapeComponent:@"Ambient"], @"Ambient", "plain name unchanged");
        CHECK_EQ([PathCodec escapeComponent:nil], @"", "nil becomes empty");
        NSString *withGuil = [NSString stringWithFormat:@"A %@ B", g];
        NSString *escaped = [PathCodec escapeComponent:withGuil];
        CHECK_EQ(escaped, ([NSString stringWithFormat:@"A %@%@ B", g, g]), "guillemet doubled");
        CHECK_EQ([PathCodec unescapeComponent:escaped], withGuil, "unescape round-trips");
        CHECK_EQ([PathCodec unescapeComponent:nil], @"", "nil unescape becomes empty");
    }

    // --- Encoding components ---
    {
        g_context = "encode";
        CHECK_EQ([PathCodec encodedNameForComponents:@[@"Ambient"]], @"Ambient",
                 "single component has no separator");
        NSString *want = [NSString stringWithFormat:@"music.hq%@Ambient", sep];
        CHECK_EQ([PathCodec encodedNameForComponents:(@[@"music.hq", @"Ambient"])], want,
                 "two components joined by separator");
        CHECK_EQ([PathCodec encodedNameForComponents:(@[@"", @"Ambient"])], @"Ambient",
                 "empty components skipped");
        CHECK_EQ([PathCodec encodedNameForComponents:@[]], @"", "no components -> empty string");
        CHECK_EQ([PathCodec encodedNameForComponents:(@[@"", @""])], @"", "all-empty -> empty string");

        // Component containing the guillemet is escaped before joining
        NSString *dirty = [NSString stringWithFormat:@"A %@ B", g];
        NSString *encoded = [PathCodec encodedNameForComponents:(@[@"Top", dirty])];
        NSString *wantDirty = [NSString stringWithFormat:@"Top%@A %@%@ B", sep, g, g];
        CHECK_EQ(encoded, wantDirty, "guillemet in component escaped");
    }

    // --- Splitting ---
    {
        g_context = "split";
        NSString *encoded = [NSString stringWithFormat:@"music.hq%@Ambient", sep];
        NSArray *parts = [PathCodec splitEncodedName:encoded];
        CHECK_EQ(parts, (@[@"music.hq", @"Ambient"]), "split on separator");

        CHECK_EQ([PathCodec splitEncodedName:@"Plain"], @[@"Plain"], "no separator -> one component");

        // Escaped guillemet survives the round trip
        NSString *dirty = [NSString stringWithFormat:@"A %@ B", g];
        NSString *roundTrip = [PathCodec encodedNameForComponents:(@[@"Top", @"Mid", dirty])];
        CHECK_EQ([PathCodec splitEncodedName:roundTrip], (@[@"Top", @"Mid", dirty]),
                 "encode/split round-trips with escaping");
    }

    // --- Separator-in-name edge (the corruption scenario) ---
    {
        g_context = "separator-in-name";
        // A leaf whose name already contains " >> " style separator text: the
        // separator itself contains an unescaped guillemet, so splitting an
        // encoded name that embeds it will split there too. Encoding only
        // escapes the guillemet characters, not the full separator.
        NSString *leafWithSep = [NSString stringWithFormat:@"music.hq%@Ambient", sep];
        NSString *encoded = [PathCodec encodedNameForComponents:@[leafWithSep]];
        // Escaping doubles the guillemet inside the separator
        NSString *wantEscaped = [leafWithSep stringByReplacingOccurrencesOfString:g
                                    withString:[NSString stringWithFormat:@"%@%@", g, g]];
        CHECK_EQ(encoded, wantEscaped, "separator text inside a leaf name gets escaped");
    }

    }
    printf("PathCodecTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
