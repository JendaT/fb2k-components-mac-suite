//
//  IntakeCollectionsTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeCollections: tolerant parsing of the
//  `collections --json` data (doc 03 v1.2: [{collection, artists,
//  releases}], releases may be fractional; at most kMaxCollectionEntries
//  entries), the name check behind the picker's OK button (exact bytes
//  first, else one canonically equivalent name), and the one-line failure
//  text. Synthetic names only.
//
// TEST_DEPS: src/Core/IntakeEnvelope.mm src/Core/IntakeErrorMap.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeCollections.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using namespace intake;

namespace {

id json(const char *text) {
    return parseJsonValue(text);
}

std::vector<std::string> v(std::initializer_list<std::string> items) {
    return std::vector<std::string>(items);
}

// The mock's responses/collections.json (scenario default).
const char *const kMockCollections =
    "[{\"collection\":\"Fixture Downtempo\",\"artists\":3,\"releases\":5},"
    "{\"collection\":\"Test & Ambient\",\"artists\":2,\"releases\":4},"
    "{\"collection\":\"Test Collection A\",\"artists\":6,\"releases\":11},"
    "{\"collection\":\"Test Collection B\",\"artists\":4,\"releases\":7},"
    "{\"collection\":\"Test Collection C\",\"artists\":2,\"releases\":2.5}]";

} // namespace

static void testValid() {
    g_context = "valid";
    CollectionsParseResult r = parseCollections(json(kMockCollections));
    CHECK(r.ok && r.error.empty(), "an array is a usable reply");
    CHECK(collectionNames(r.collections) == v({"Fixture Downtempo", "Test & Ambient", "Test Collection A",
                                               "Test Collection B", "Test Collection C"}),
          "every name, in the CLI's order");
    CHECK(r.skipped == 0 && r.duplicates == 0, "nothing skipped");
    CHECK(r.collections[2].hasArtists && r.collections[2].artists == 6, "artists read");
    CHECK(r.collections[4].hasReleases, "releases read");
    CHECK_FLOAT_EQ(r.collections[4].releases, 2.5, "fractional releases kept");

    // Through a full envelope, as the runner hands it over.
    std::string stdoutText = std::string("{\"ok\":true,\"data\":") + kMockCollections + ",\"errors\":[]}\n";
    EnvelopeResult env = parseEnvelope(stdoutText, 0);
    CHECK(env.outcome == CliOutcome::Ok, "the mock's envelope is Ok");
    CHECK(parseCollections(env.data).collections.size() == 5, "five collections from the envelope's data");

    CollectionsParseResult unsorted =
        parseCollections(json("[{\"collection\":\"Zeta\"},{\"collection\":\"Alpha\"},{\"collection\":\"Mid\"}]"));
    CHECK(collectionNames(unsorted.collections) == v({"Zeta", "Alpha", "Mid"}), "never re-sorted");

    CollectionsParseResult empty = parseCollections(json("[]"));
    CHECK(empty.ok && empty.collections.empty() && empty.skipped == 0, "[]: ok, no collections");
}

static void testFields() {
    g_context = "fields";
    CollectionsParseResult r = parseCollections(json(
        "[{\"collection\":\"Only Name\"},"
        "{\"collection\":\"Extra Fields\",\"artists\":1,\"releases\":0.25,\"genre\":\"x\",\"nested\":{\"a\":[1]}},"
        "{\"collection\":\"Bad Counts\",\"artists\":\"3\",\"releases\":true},"
        "{\"collection\":\"Null Counts\",\"artists\":null,\"releases\":null},"
        "{\"collection\":\"Float Artists\",\"artists\":2.0,\"releases\":false}]"));
    CHECK(r.ok && r.collections.size() == 5 && r.skipped == 0, "entries with odd counts are kept");
    CHECK(!r.collections[0].hasArtists && !r.collections[0].hasReleases, "missing counts: absent");
    CHECK(r.collections[1].hasArtists && r.collections[1].hasReleases, "extra fields ignored, counts read");
    CHECK_FLOAT_EQ(r.collections[1].releases, 0.25, "a fraction below 1");
    CHECK(!r.collections[2].hasArtists, "a string is not a count");
    CHECK(!r.collections[2].hasReleases, "a boolean is not a count");
    CHECK(!r.collections[3].hasArtists && !r.collections[3].hasReleases, "null counts: absent");
    CHECK(r.collections[4].hasArtists && r.collections[4].artists == 2.0 && !r.collections[4].hasReleases,
          "2.0 is a number; false is not");
}

static void testBadEntries() {
    g_context = "bad-entries";
    CollectionsParseResult r = parseCollections(json(
        "[\"Bare String\", 42, null, [\"x\"], true,"
        "{\"artists\":1},"
        "{\"collection\":null},"
        "{\"collection\":7},"
        "{\"collection\":\"\"},"
        "{\"collection\":[\"Test Collection A\"]},"
        "{\"collection\":{\"name\":\"x\"}},"
        "{\"collection\":\"Nul\\u0000Name\"},"
        "{\"collection\":\"Good One\"}]"));
    CHECK(r.ok, "bad entries do not make the reply unusable");
    CHECK(collectionNames(r.collections) == v({"Good One"}), "only the usable entry is kept");
    CHECK_EQ(r.skipped, 12, "every bad entry is counted");

    CollectionsParseResult allBad = parseCollections(json("[{\"name\":\"x\"},1]"));
    CHECK(allBad.ok && allBad.collections.empty() && allBad.skipped == 2, "all bad: ok, empty, counted");
}

static void testNotArray() {
    g_context = "not-array";
    CollectionsParseResult obj = parseCollections(json("{\"collection\":\"Test Collection A\"}"));
    CHECK(!obj.ok && obj.error == "data is not an array" && obj.collections.empty(), "an object is not a list");
    CollectionsParseResult str = parseCollections(@"Test Collection A");
    CHECK(!str.ok && str.error == "data is not an array", "a string is not a list");
    CollectionsParseResult num = parseCollections(@3);
    CHECK(!num.ok && num.error == "data is not an array", "a number is not a list");
    EnvelopeResult env = parseEnvelope("{\"ok\":true,\"data\":{\"collections\":[]},\"errors\":[]}", 0);
    CHECK(env.outcome == CliOutcome::Ok && !parseCollections(env.data).ok, "an object as data: not usable");
    CollectionsParseResult none = parseCollections(nil);
    CHECK(!none.ok && none.error == "data is null", "null data");
    CollectionsParseResult nsnull = parseCollections([NSNull null]);
    CHECK(!nsnull.ok && nsnull.error == "data is null", "NSNull data");
}

static void testDuplicates() {
    g_context = "duplicates";
    CollectionsParseResult r = parseCollections(
        json("[{\"collection\":\"Test Collection A\",\"artists\":6},"
             "{\"collection\":\"Test Collection B\"},"
             "{\"collection\":\"Test Collection A\",\"artists\":1},"
             "{\"collection\":\"test collection a\"},"
             "{\"collection\":\"Test Collection A \"},"
             "{\"collection\":\"Test Collection B\"}]"));
    CHECK(collectionNames(r.collections) ==
              v({"Test Collection A", "Test Collection B", "test collection a", "Test Collection A "}),
          "exact repeats dropped; other case or a trailing space is another name");
    CHECK_EQ(r.duplicates, 2, "two repeats counted");
    CHECK(r.collections[0].artists == 6, "the first occurrence wins");
    CHECK(r.skipped == 0, "repeats are not counted as skipped");
}

static void testNames() {
    g_context = "names";
    // U+00E9 precomposed vs e + U+0301: different bytes, different names.
    CollectionsParseResult r =
        parseCollections(json("[{\"collection\":\"Caf\\u00e9 Fixture\"},{\"collection\":\"Cafe\\u0301 Fixture\"},"
                              "{\"collection\":\"[Test & Ambient]\"}]"));
    const std::vector<std::string> names = collectionNames(r.collections);
    CHECK(names.size() == 3, "NFC and NFD spellings are both kept");
    CHECK(names[0] == "Caf\xC3\xA9 Fixture" && names[1] == "Cafe\xCC\x81 Fixture", "bytes kept as written");
    CHECK(names[2] == "[Test & Ambient]", "brackets and & kept");

    CHECK(isListedCollection(names, "[Test & Ambient]"), "an exact name is listed");
    CHECK(!isListedCollection(names, "[test & ambient]"), "case-sensitive");
    CHECK(!isListedCollection(names, "[Test & Ambient] "), "no trimming");
    CHECK(!isListedCollection(names, "[Test &"), "a prefix is not listed");
    CHECK(!isListedCollection(names, "Cafe Fixture"), "no folding");
    CHECK(isListedCollection(names, "Cafe\xCC\x81 Fixture"), "the NFD spelling is listed as itself");
    CHECK(!isListedCollection(names, ""), "empty text is never listed");
    CHECK(!isListedCollection({}, "x"), "nothing is listed in an empty list");
}

static void testEquivalent() {
    g_context = "equivalent";
    const std::string nfc = "Caf\xC3\xA9 Fixture";    // U+00E9, as typed
    const std::string nfd = "Cafe\xCC\x81 Fixture";   // e + U+0301, as a folder name over SMB
    const std::vector<std::string> onlyNfd = {"Test Collection A", nfd};
    const std::string *hit = listedCollectionFor(onlyNfd, nfc);
    CHECK(hit != nullptr && *hit == nfd, "typed NFC finds the NFD name and returns its own bytes");
    CHECK(hit == &onlyNfd[1], "the pointer is into the list");
    const std::vector<std::string> onlyNfc = {nfc};
    hit = listedCollectionFor(onlyNfc, nfd);
    CHECK(hit != nullptr && *hit == nfc, "NFD text finds the NFC name");
    CHECK(listedCollectionFor(onlyNfd, "caf\xC3\xA9 fixture") == nullptr, "still case-sensitive");
    CHECK(listedCollectionFor(onlyNfd, nfc + " ") == nullptr, "still no trimming");
    CHECK(listedCollectionFor(onlyNfd, "Cafe Fixture") == nullptr, "no accent folding");

    // Both spellings listed: the exact bytes win.
    const std::vector<std::string> both = {nfc, nfd};
    CHECK(listedCollectionFor(both, nfc) == &both[0], "both listed, NFC text: the NFC name");
    CHECK(listedCollectionFor(both, nfd) == &both[1], "both listed, NFD text: the NFD name");

    // d + dot below + dot above has several equivalent spellings: two of
    // them listed, a third typed (NFC: U+1E0D U+0307) is ambiguous.
    const std::vector<std::string> twoOthers = {"d\xCC\x87\xCC\xA3 Fixture", "\xE1\xB8\x8B\xCC\xA3 Fixture"};
    CHECK(listedCollectionFor(twoOthers, "\xE1\xB8\x8D\xCC\x87 Fixture") == nullptr,
          "two equivalent names, neither exact: none");
    CHECK(listedCollectionFor(twoOthers, twoOthers[1]) == &twoOthers[1], "an exact one still wins");
    const std::vector<std::string> oneOther = {twoOthers[0]};
    CHECK(listedCollectionFor(oneOther, "\xE1\xB8\x8D\xCC\x87 Fixture") == &oneOther[0],
          "mark order differs, same NFC: found");

    CHECK(listedCollectionFor(onlyNfd, "") == nullptr, "empty text: none");
    CHECK(listedCollectionFor(onlyNfd, "\xFF\xFE") == nullptr, "invalid UTF-8 text: none, no crash");
    CHECK(isListedCollection(onlyNfd, nfc), "isListedCollection follows listedCollectionFor");
}

static void testEntryCap() {
    g_context = "entry-cap";
    CHECK(kMaxCollectionEntries == 10000, "default cap");
    const char *three = "[{\"collection\":\"A\"},{\"collection\":\"B\"},7]";
    CollectionsParseResult atCap = parseCollections(json(three), 3);
    CHECK(atCap.ok && atCap.collections.size() == 2 && atCap.skipped == 1, "exactly the cap: parsed");
    CollectionsParseResult over = parseCollections(json(three), 2);
    CHECK(!over.ok && over.error == "more than 2 entries" && over.collections.empty(),
          "one entry over the cap: not usable");
    NSMutableArray *big = [NSMutableArray arrayWithCapacity:kMaxCollectionEntries + 1];
    for (size_t i = 0; i <= kMaxCollectionEntries; i++) [big addObject:@{@"collection" : @"Same Name"}];
    CollectionsParseResult huge = parseCollections(big);
    CHECK(!huge.ok && huge.error == "more than 10000 entries", "10001 entries: not usable by default");
    [big removeLastObject];
    CollectionsParseResult full = parseCollections(big);
    CHECK(full.ok && full.collections.size() == 1 && full.duplicates == kMaxCollectionEntries - 1,
          "10000 entries: parsed");
}

static void testFailureText() {
    g_context = "failure-text";
    CHECK(collectionsFailureText(hostTimeout("no exit within the time budget; terminated")) ==
              "Intake CLI timed out: no exit within the time budget; terminated",
          "timeout");
    EnvelopeResult garbage = parseEnvelope("not json", 0);
    CHECK(garbage.outcome == CliOutcome::NoCli, "garbage is E_NO_CLI");
    CHECK(collectionsFailureText(garbage) == "Intake CLI not available: stdout is not one JSON value",
          "unparseable stdout");
    EnvelopeResult failed = parseEnvelope(
        "{\"ok\":false,\"data\":null,\"errors\":[{\"code\":\"E_NO_RULES\",\"msg\":\"no genre map\",\"path\":null},"
        "{\"code\":\"E_MOCK_ODD\",\"msg\":\"second\",\"path\":null}]}",
        2);
    CHECK(failed.outcome == CliOutcome::Failed, "exit 2 is Failed");
    CHECK(collectionsFailureText(failed) == "Intake rules not configured: no genre map (+1 more)",
          "first error rendered, the rest counted");
    EnvelopeResult unknown =
        parseEnvelope("{\"ok\":false,\"data\":null,\"errors\":[{\"code\":\"E_MOCK_UNKNOWN_CODE\",\"msg\":\"\"}]}", 2);
    CHECK(collectionsFailureText(unknown) == "E_MOCK_UNKNOWN_CODE", "an unknown code without msg: the code");
    EnvelopeResult partial = parseEnvelope(
        "{\"ok\":false,\"data\":[{\"collection\":\"Test Collection A\"}],"
        "\"errors\":[{\"code\":\"E_PARSE\",\"msg\":\"genre map line 3\",\"path\":\"/rules/map.yaml\"}]}",
        1);
    CHECK(partial.outcome == CliOutcome::Partial, "exit 1 is Partial");
    CHECK(collectionsFailureText(partial) == "Unreadable sidecar: genre map line 3 (/rules/map.yaml)",
          "a partial listing is a failure too, with its path");
    EnvelopeResult cancelled;
    cancelled.outcome = CliOutcome::Cancelled;
    CHECK(collectionsFailureText(cancelled) == "cancelled", "no error: the outcome name");
}

int main() {
    @autoreleasepool {
        testValid();
        testFields();
        testBadEntries();
        testNotArray();
        testDuplicates();
        testNames();
        testEquivalent();
        testEntryCap();
        testFailureText();
    }
    TEST_MAIN_END();
}
