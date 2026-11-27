#include "../../../shared/Tests/TestHarness.h"
#include "../src/Artists/ArtistIndexCore.h"

using namespace artistindex;

int main() {
    g_context = "buildIndex";
    std::vector<TrackRow> rows = {
        {"Radice & Uyak", "", "X", "2020", 0},
        {"", "Armec", "Replication EP", "2019", 1},
        {"Various Artists", "Fele", "Comp", "2021", 2},
    };
    auto idx = buildIndex(rows);
    CHECK_EQ(idx.size(), 4, "four artists");
    if (idx.size() == 4) {
        CHECK(idx[0].name == "Armec", "sorted: Armec first");
        CHECK(idx[1].name == "Fele", "Fele second");
        CHECK(idx[2].name == "Radice", "Radice third");
        CHECK(idx[3].name == "Uyak", "Uyak fourth");
        CHECK(idx[0].ownedAlbums == std::vector<std::string>{"Replication EP"}, "Armec owned");
        CHECK(idx[1].ownedAlbums.empty(), "Fele owns nothing");
        CHECK(idx[1].appearsOnAlbums == std::vector<std::string>{"Comp"}, "Fele appears on Comp");
        CHECK(idx[2].ownedAlbums == std::vector<std::string>{"X"}, "Radice owned");
        CHECK(idx[3].ownedAlbums == std::vector<std::string>{"X"}, "Uyak owned");
        CHECK(idx[1].newestAlbum == "Comp", "appears-on newest fallback");
        CHECK(idx[2].trackIndices == std::vector<size_t>{0}, "Radice tracks");
    }
    for (auto& e : idx) CHECK(e.name != "Various Artists", "no VA entry");

    g_context = "newest";
    std::vector<TrackRow> r2 = {
        {"A", "A", "Old", "2001", 0}, {"A", "A", "New", "2010", 1},
        {"A", "A", "Tie", "2010", 2}, {"A", "A", "Old", "2001", 3},
    };
    auto i2 = buildIndex(r2);
    CHECK_EQ(i2.size(), 1, "one artist");
    if (!i2.empty()) {
        CHECK(i2[0].newestAlbum == "New", "max date, ties first seen");
        CHECK_EQ(i2[0].ownedAlbums.size(), 3, "albums deduped");
        CHECK_EQ(i2[0].trackIndices.size(), 4, "all tracks");
    }

    g_context = "appears-on";
    std::vector<TrackRow> r3 = {{"Boss", "Boss feat. Guest", "Album", "2015", 0}};
    auto i3 = buildIndex(r3);
    CHECK_EQ(i3.size(), 2, "owner plus guest");
    if (i3.size() == 2) {
        CHECK(i3[0].name == "Boss" && i3[0].appearsOnAlbums.empty(), "owner not appears-on");
        CHECK(i3[1].name == "Guest" && i3[1].appearsOnAlbums.size() == 1, "guest appears on");
    }

    g_context = "display name";
    const std::string upper = "KiLL\xCE\x94TK", lower = "Kill\xCE\xB4tk";
    std::vector<TrackRow> r4 = {
        {"", lower, "A", "2020", 0}, {"", lower, "B", "2020", 1}, {"", lower, "C", "2020", 2},
        {upper, upper, "D", "2021", 3},
    };
    auto i4 = buildIndex(r4);
    CHECK_EQ(i4.size(), 1, "case variants merge");
    if (i4.size() == 1) CHECK(i4[0].name == upper, "album-artist spelling wins");

    std::vector<TrackRow> r5 = {
        {"", upper, "A", "2020", 0}, {"", lower, "B", "2020", 1}, {"", lower, "C", "2020", 2},
    };
    auto i5 = buildIndex(r5);
    CHECK_EQ(i5.size(), 1, "merge without album artist");
    if (i5.size() == 1) CHECK(i5[0].name == lower, "most frequent spelling wins");
    TEST_MAIN_END();
}
