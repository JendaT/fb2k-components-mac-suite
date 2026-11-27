#include "TestHarness.h"
#include "../ArtistNames.h"

using namespace artistnames;
using V = std::vector<std::string>;

int main() {
    g_context = "splitArtists";
    CHECK(splitArtists("Radice & Uyak") == (V{"Radice", "Uyak"}), "&");
    CHECK(splitArtists("Audiokidnapping vs Der Sandmann") == (V{"Audiokidnapping", "Der Sandmann"}), "vs");
    CHECK(splitArtists("Magnethik Sadhu & Xydur (Trimurti)") == (V{"Magnethik Sadhu", "Xydur", "Trimurti"}), "paren");
    CHECK(splitArtists("Psykovsky & Friends") == (V{"Psykovsky"}), "friends");
    CHECK(splitArtists("A feat. B") == (V{"A", "B"}), "feat.");
    CHECK(splitArtists("A ft. B") == (V{"A", "B"}), "ft.");
    CHECK(splitArtists("A x B") == (V{"A", "B"}), "x");
    CHECK(splitArtists("A, B") == (V{"A", "B"}), "comma");
    CHECK(splitArtists("Armec") == (V{"Armec"}), "single");
    CHECK(splitArtists("Xydur") == (V{"Xydur"}), "Xydur");
    CHECK(splitArtists("Vulkan") == (V{"Vulkan"}), "Vulkan");

    g_context = "isVariousArtists";
    CHECK(isVariousArtists("Various Artists"), "VA full");
    CHECK(isVariousArtists("various artists"), "lower");
    CHECK(isVariousArtists("VA"), "VA");
    CHECK(isVariousArtists("V/A"), "V/A");
    CHECK(!isVariousArtists("Vali"), "Vali");
    CHECK(!isVariousArtists("Vavaa"), "Vavaa");

    g_context = "artistKey";
    CHECK(artistKey("KiLL\xCE\x94TK") != artistKey("KiLLATK"), "delta differs");
    CHECK(artistKey("Beyonc\xC3\xA9") == artistKey("beyonce"), "accent");
    CHECK(artistKey("D.o.c.") == artistKey("doc"), "punct");
    CHECK(artistKey("Alice D") != artistKey("Alice DJ"), "D vs DJ");
    CHECK(artistKey("\xC5\x81\xC3\xB3" "d\xC5\xBA") == artistKey("lodz"), "ext-A");

    TEST_MAIN_END();
}
