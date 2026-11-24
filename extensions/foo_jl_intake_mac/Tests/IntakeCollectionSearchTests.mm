//
//  IntakeCollectionSearchTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeCollectionSearch: the picker's matcher (case,
//  diacritics, brackets, substring, ranking), its Recent list (parse,
//  format, move to front, cap, repeats, unknown names), the Suggested
//  section, the rows and the highlight. Synthetic names;
//  "[Folktronica & Ezo techno]" and "[Psytrance & Goa]" are the user's own
//  examples.
//
// TEST_DEPS: src/Core/IntakeCollections.mm src/Core/IntakeEnvelope.mm src/Core/IntakeErrorMap.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeCollectionSearch.h"
#include "TestHarness.h"

#include <initializer_list>
#include <string>
#include <vector>

using namespace intake;

namespace {

// The names `indices` point at, in order.
std::vector<std::string> pick(const std::vector<std::string> &names, const std::vector<size_t> &indices) {
    std::vector<std::string> out;
    for (size_t i : indices) out.push_back(names[i]);
    return out;
}

bool are(const std::vector<std::string> &got, std::initializer_list<const char *> want) {
    if (got.size() != want.size()) return false;
    size_t i = 0;
    for (const char *w : want) {
        if (got[i++] != w) return false;
    }
    return true;
}

const std::vector<std::string> kNames = {
    "[Psytrance & Goa]",          "[Folktronica & Ezo techno]", "[Ambient]",      "[Dub Techno]",
    "[Techno]",                   "[Caf\xC3\xA9 Lounge]",       "[Goa Classics]", "[Downtempo]",
    "[Psychill & Chillout & Psydub]",
};

} // anonymous namespace

static void testKey() {
    g_context = "key";
    CHECK(searchKey("[Psytrance & Goa]") == "psytrance & goa", "lowercase, brackets gone");
    CHECK(searchKey("  [Ambient]  ") == "ambient", "trimmed");
    CHECK(searchKey("Caf\xC3\xA9") == "cafe", "a composed diacritic is ignored");
    CHECK(searchKey("Cafe\xCC\x81") == "cafe", "a decomposed one too");
    CHECK(searchKey("\xC3\x89LAN") == "elan", "an uppercase letter with a diacritic");
    CHECK(searchKey("[]").empty() && searchKey("   ").empty(), "nothing left");
}

static void testMatch() {
    g_context = "match";
    CHECK(are(pick(kNames, matchCollections(kNames, "folk")), {"[Folktronica & Ezo techno]"}),
          "\"folk\" finds the bracketed name (no prefix completion needed)");
    CHECK(are(pick(kNames, matchCollections(kNames, "goa")), {"[Goa Classics]", "[Psytrance & Goa]"}),
          "\"goa\": the name starting with it first, then the word start");
    CHECK(are(pick(kNames, matchCollections(kNames, "GOA")), {"[Goa Classics]", "[Psytrance & Goa]"}),
          "case is ignored");
    CHECK(are(pick(kNames, matchCollections(kNames, "cafe")), {"[Caf\xC3\xA9 Lounge]"}), "diacritics are ignored");
    CHECK(are(pick(kNames, matchCollections(kNames, "caf\xC3\xA9")), {"[Caf\xC3\xA9 Lounge]"}),
          "and typed ones match too");
    CHECK(are(pick(kNames, matchCollections(kNames, "[ambient]")), {"[Ambient]"}), "typed brackets are ignored");
    CHECK(are(pick(kNames, matchCollections(kNames, "techno")), {"[Techno]", "[Dub Techno]", "[Folktronica & Ezo techno]"}),
          "prefix first, then word starts alphabetically");
    CHECK(are(pick(kNames, matchCollections(kNames, "tempo")), {"[Downtempo]"}), "a substring inside a word");
    CHECK(are(pick(kNames, matchCollections(kNames, "psy")), {"[Psychill & Chillout & Psydub]", "[Psytrance & Goa]"}),
          "two prefix matches: alphabetical");
    CHECK(are(pick(kNames, matchCollections(kNames, "chill")), {"[Psychill & Chillout & Psydub]"}),
          "inside a word and at a word start in one name: listed once");
    CHECK(are(pick(kNames, matchCollections(kNames, "& goa")), {"[Psytrance & Goa]"}), "spaces and & count");
    CHECK(matchCollections(kNames, "zzz").empty(), "no match");
    const std::vector<size_t> all = matchCollections(kNames, "  ");
    CHECK(all.size() == kNames.size() && all.front() == 0 && all.back() == kNames.size() - 1,
          "an empty query lists everything in the CLI's order");
    CHECK(matchCollections({}, "goa").empty(), "no names");

    g_context = "rank-order";
    // Word start beats a match inside a word even when it sorts later.
    const std::vector<std::string> names = {"[Aab]", "[Zz Ab]", "[Ab]"};
    CHECK(are(pick(names, matchCollections(names, "ab")), {"[Ab]", "[Zz Ab]", "[Aab]"}),
          "prefix, then word start, then inside a word");
}

static void testRecent() {
    g_context = "recent-parse";
    CHECK(are(parseRecentCollections("[A]\n[B]\r\n\n[A]\n[C]"), {"[A]", "[B]", "[C]"}),
          "one per line, CR and empty lines skipped, repeats dropped");
    CHECK(parseRecentCollections("").empty(), "empty");
    CHECK(parseRecentCollections("1\n2\n3\n4\n5\n6\n7").size() == kRecentCollectionsMax, "at most 5");
    CHECK(formatRecentCollections({"[A]", "[B]"}) == "[A]\n[B]", "joined with newlines");
    CHECK(are(parseRecentCollections(formatRecentCollections({"[A]", "[B]", "[C]"})), {"[A]", "[B]", "[C]"}),
          "round trip");

    g_context = "recent-update";
    const std::vector<std::string> listed = {"[A]", "[B]", "[C]", "[D]", "[E]", "[F]", "[G]"};
    CHECK(are(updateRecentCollections({}, "[C]", listed), {"[C]"}), "the first one");
    CHECK(are(updateRecentCollections({"[A]", "[B]", "[C]"}, "[C]", listed), {"[C]", "[A]", "[B]"}),
          "a repeat moves to the front");
    CHECK(are(updateRecentCollections({"[A]", "[B]", "[C]", "[D]", "[E]"}, "[F]", listed),
              {"[F]", "[A]", "[B]", "[C]", "[D]"}),
          "capped at 5: the oldest goes");
    CHECK(are(updateRecentCollections({"[Gone]", "[A]", "[A]"}, "[B]", listed), {"[B]", "[A]"}),
          "an unknown name and repeats are dropped");
    CHECK(are(updateRecentCollections({"[Gone]", "[A]"}, "[B]", {}), {"[B]", "[Gone]", "[A]"}),
          "no list: nothing is dropped as unknown");
    const std::vector<std::string> nfd = {"[Cafe\xCC\x81]"};
    CHECK(are(updateRecentCollections({}, "[Caf\xC3\xA9]", nfd), {"[Cafe\xCC\x81]"}),
          "kept as the listed bytes (an NFD name chosen as NFC)");

    g_context = "recent-shown";
    CHECK(are(shownRecentCollections({"[C]", "[Gone]", "[A]"}, listed), {"[C]", "[A]"}),
          "names no longer listed drop out, order kept");
    CHECK(shownRecentCollections({"[Gone]"}, listed).empty(), "none left");
    CHECK(shownRecentCollections({"[A]"}, {}).empty(), "no list: nothing shown");
}

static std::string rowsText(const std::vector<PickerRow> &rows) {
    std::string out;
    for (const PickerRow &r : rows) {
        if (!out.empty()) out += '|';
        out += (r.header ? "#" : "") + r.text;
    }
    return out;
}

static void testSections() {
    g_context = "suggested";
    const std::vector<std::string> listed = {"[A]", "[B]", "[C]", "[D]", "[E]"};
    CHECK(are(suggestedCollections({"[B]", "[B]", "[B]"}, listed), {"[B]"}), "all agree: one");
    CHECK(are(suggestedCollections({"[B]", "[A]", "[B]", "[C]", "[D]"}, listed), {"[B]", "[A]", "[C]"}),
          "they differ: the distinct ones in selection order, at most 3");
    CHECK(are(suggestedCollections({"", "[C]", ""}, listed), {"[C]"}), "roots without ranked add nothing");
    CHECK(are(suggestedCollections({"[Gone]", "[A]"}, listed), {"[A]"}), "a collection no longer listed is left out");
    CHECK(suggestedCollections({"", ""}, listed).empty(), "none: no section");
    CHECK(are(suggestedCollections({"[Caf\xC3\xA9]"}, {"[Cafe\xCC\x81]"}), {"[Cafe\xCC\x81]"}),
          "kept as the listed bytes");

    g_context = "rows";
    const std::vector<std::string> names = {"[Psytrance & Goa]", "[Goa Classics]", "[Ambient]"};
    CHECK(rowsText(pickerRows({"[Ambient]"}, {"[Goa Classics]", "[Ambient]"}, names, "")) ==
              "#Suggested|[Ambient]|#Recent|[Goa Classics]|[Ambient]|#All collections|[Psytrance & Goa]|[Goa Classics]|"
              "[Ambient]",
          "empty text: Suggested, Recent, All; a name may repeat across sections");
    CHECK(rowsText(pickerRows({}, {}, names, "  ")) == "#All collections|[Psytrance & Goa]|[Goa Classics]|[Ambient]",
          "empty sections are left out");
    CHECK(rowsText(pickerRows({"[Ambient]"}, {"[Ambient]"}, names, "goa")) == "[Goa Classics]|[Psytrance & Goa]",
          "searching: one ranked list, no sections");
    CHECK(pickerRows({}, {}, names, "zzz").empty(), "no match: no rows");

    g_context = "highlight";
    const std::vector<PickerRow> open = pickerRows({"[Ambient]"}, {}, names, "");
    CHECK_EQ(pickerHighlight(open, names, ""), -1, "empty text: nothing chosen for the user");
    const std::vector<PickerRow> goa = pickerRows({}, {}, names, "goa");
    CHECK_EQ(pickerHighlight(goa, names, "goa"), 0, "the first match");
    const std::vector<PickerRow> exact = pickerRows({}, {}, names, "[Psytrance & Goa]");
    CHECK(pickerHighlight(exact, names, "[Psytrance & Goa]") >= 0 &&
              exact[static_cast<size_t>(pickerHighlight(exact, names, "[Psytrance & Goa]"))].text == "[Psytrance & Goa]",
          "an exact listed name highlights its own row");
    CHECK_EQ(pickerHighlight(pickerRows({}, {}, names, "zzz"), names, "zzz"), -1, "no match: nothing");
    const std::vector<PickerRow> onlyHeader = {{true, "Recent"}};
    CHECK_EQ(pickerHighlight(onlyHeader, names, "x"), -1, "a header is never highlighted");
}

int main(void) {
    @autoreleasepool {
        testKey();
        testMatch();
        testRecent();
        testSections();
    }
    TEST_MAIN_END();
}
