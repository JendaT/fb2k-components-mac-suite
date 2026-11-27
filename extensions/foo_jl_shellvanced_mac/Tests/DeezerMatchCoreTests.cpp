#include "../../../shared/Tests/TestHarness.h"
#include "../src/Artists/DeezerMatchCore.h"

using namespace deezermatch;

int main() {
    g_context = "hasRealPicture";
    CHECK(!hasRealPicture("https://e-cdns-images.dzcdn.net/images/artist//250x250-000000-80-0-0.jpg"), "empty hash");
    CHECK(!hasRealPicture(""), "empty url");
    CHECK(hasRealPicture("https://e-cdns-images.dzcdn.net/images/artist/abc123def/250x250-000000-80-0-0.jpg"), "real");

    g_context = "exactCandidates";
    std::vector<Candidate> c = {{"1", "Kaya", "", 10}, {"2", "KAYA", "", 5}, {"3", "Kayah", "", 99}};
    CHECK(exactCandidates("Kaya", c) == (std::vector<size_t>{0, 1}), "Kaya -> 0,1");
    CHECK(exactCandidates("Alice D", {{"9", "Alice DJ", "", 1}}).empty(), "no prefix match");
    CHECK(exactCandidates("", c).empty(), "empty name");

    g_context = "titles";
    CHECK(normalizeTitle("Replication EP") == "replication", "EP dropped");
    CHECK(normalizeTitle("Replication (Remastered)") == "replication", "paren dropped");
    CHECK(normalizeTitle("Foo [Deluxe Edition]") == "foo", "bracket dropped");
    CHECK(titlesOverlap({normalizeTitle("Replication EP")}, {normalizeTitle("Replication (Remastered)")}), "overlap");
    CHECK(!titlesOverlap({"abc"}, {"abcd"}), "short containment rejected");
    CHECK(titlesOverlap({"night drive"}, {"night drive extended"}), "containment >= 6");
    CHECK(!titlesOverlap({""}, {""}), "empty never matches");
    CHECK(!titlesOverlap({"alpha"}, {"beta"}), "disjoint");
    g_context = "chooseCandidate";
    {
        using V = std::vector<std::string>;
        CHECK_EQ(chooseCandidate(V{"home"}, {V{"home"}}), -1, "short lone title does not confirm");
        CHECK_EQ(chooseCandidate(V{"nothing"}, {V{"nothing else matters"}}), -1, "lone containment too weak");
        CHECK_EQ(chooseCandidate(V{"night drive", "blue hour"}, {V{"night drive", "blue hour"}, V{"other"}}), 0, "two overlaps chosen");
        CHECK_EQ(chooseCandidate(V{"night drive", "blue hour"}, {V{"night drive", "blue hour"}, V{"blue hour", "night drive"}}), -1, "two acceptable = ambiguous");
        CHECK_EQ(chooseCandidate(V{"replication"}, {V{"replication"}}), 0, "single strong equality >= 6 chars");
        CHECK_EQ(chooseCandidate(V{"replication", "replication"}, {V{"x"}, V{"replication"}}), 1, "duplicates count once");
        CHECK(!titlesOverlap({"love song"}, {"glove songs"}), "no mid-word containment");
        CHECK_EQ(chooseCandidate(V{"home", "away"}, {V{"home", "away"}}), 0, "two short distinct overlaps");
    }
    TEST_MAIN_END();
}
