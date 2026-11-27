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

    g_context = "splitArtists brackets";
    CHECK(splitArtists("Audio Syntax and Varaboro (ft Varazslo)") == (V{"Audio Syntax and Varaboro", "Varazslo"}), "paren ft");
    CHECK(splitArtists("Osom [Psykovsky & Kindzadza] & Maramba") == (V{"Osom", "Maramba", "Psykovsky", "Kindzadza"}), "mid bracket");
    CHECK(splitArtists("Anthropus [The Endless Knot]") == (V{"Anthropus", "The Endless Knot"}), "bracket");
    CHECK(splitArtists("ritual zynth [ The Endless Knot ]") == (V{"ritual zynth", "The Endless Knot"}), "bracket spaces");
    CHECK(splitArtists("Kara\xC3\xA1 [Kataclysmic][The Endless Knot]") == (V{"Kara\xC3\xA1", "Kataclysmic", "The Endless Knot"}), "two brackets");
    CHECK(splitArtists("Oroboro (Official)") == (V{"Oroboro"}), "official");
    CHECK(splitArtists("TikbaH (KinetiK Flux and MacromhO)") == (V{"TikbaH", "KinetiK Flux and MacromhO"}), "and in paren");
    CHECK(splitArtists("Post Modern Music (PMM)") == (V{"Post Modern Music", "PMM"}), "PMM");
    CHECK(splitArtists("KERAMIK (Metacortex Records)") == (V{"KERAMIK", "Metacortex Records"}), "records");
    CHECK(splitArtists("A ft B") == (V{"A", "B"}), "ft word");
    CHECK(splitArtists("A Featuring B") == (V{"A", "B"}), "featuring");
    CHECK(splitArtists("A feat B") == (V{"A", "B"}), "feat word");
    CHECK(splitArtists("A (unclosed") == (V{"A (unclosed"}), "unbalanced");
    CHECK(splitArtists("A & B (A)") == (V{"A", "B"}), "dedupe");

    g_context = "splitArtists guards";
    CHECK(splitArtists("Florence and the Machine") == (V{"Florence and the Machine"}), "and");
    CHECK(splitArtists("Mumford and Sons") == (V{"Mumford and Sons"}), "and 2");
    CHECK(splitArtists("AT&T") == (V{"AT&T"}), "AT&T");
    CHECK(splitArtists("Drum&Bass") == (V{"Drum&Bass"}), "Drum&Bass");
    CHECK(splitArtists("Sunn O)))") == (V{"Sunn O)))"}), "Sunn O");
    CHECK(splitArtists("Malcolm X") == (V{"Malcolm X"}), "Malcolm X");
    CHECK(splitArtists("Project X") == (V{"Project X"}), "Project X");
    CHECK(splitArtists("A,B") == (V{"A,B"}), "bare comma");

    g_context = "isVariousArtists";
    CHECK(!isVariousArtists("Various"), "Various alone");
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

    CHECK(artistKey("Beyonce\xCC\x81") == artistKey("beyonce"), "NFD acute");
    CHECK(artistKey("Beyonc\xC3\xA9") == artistKey("Beyonce\xCC\x81"), "NFC==NFD");
    CHECK(artistKey("Guns N\xE2\x80\x99 Roses") == artistKey("Guns N' Roses"), "curly apostrophe");
    CHECK(artistKey("a\xE2\x80\x93" "b") == artistKey("ab"), "en dash");

    g_context = "artistKey unicode case";
    CHECK(artistKey("KiLL\xCE\x94TK") == artistKey("Kill\xCE\xB4tk"), "delta case");
    CHECK(artistKey("\xCE\xA3\xCE\xA9\xCE\x9A\xCE\xA1\xCE\x91\xCE\xA4\xCE\x97\xCE\xA3") ==
              artistKey("\xCF\x83\xCF\x89\xCE\xBA\xCF\x81\xCE\xB1\xCF\x84\xCE\xB7\xCF\x82"),
          "greek incl final sigma");
    CHECK(artistKey("\xD0\x9C\xD0\x90\xD0\xA8\xD0\x90") == artistKey("\xD0\xBC\xD0\xB0\xD1\x88\xD0\xB0"), "cyrillic");
    CHECK(artistKey("\xC3\x89" "LAN") == artistKey("\xC3\xA9" "lan"), "latin1 case");
    CHECK(artistKey("\xC3\x89" "LAN") == artistKey("Elan"), "latin1 accent");
    CHECK(artistKey("\xC5\x81\xC3\x93" "D\xC5\xB9") == artistKey("\xC5\x82\xC3\xB3" "d\xC5\xBA"), "latin ext-a");
    CHECK(artistKey("\xCE\x94\xCE\x94") != artistKey("\xCE\x94\xCE\x95"), "greek differ");
    CHECK(artistKey("\xD0\x9C\xD0\x90\xD0\xA8\xD0\x90") != artistKey("\xD0\x9C\xD0\x90\xD0\xA8"), "cyrillic differ");
    CHECK(artistKey("Armec") != artistKey("Fele"), "unrelated");
    // Greek accents: "Ελένη" (NFC), all-caps without tonos, NFD
    CHECK(artistKey("\xCE\x95\xCE\xBB\xCE\xAD\xCE\xBD\xCE\xB7") == artistKey("\xCE\x95\xCE\x9B\xCE\x95\xCE\x9D\xCE\x97"), "greek tonos vs caps");
    CHECK(artistKey("\xCE\x95\xCE\xBB\xCE\xAD\xCE\xBD\xCE\xB7") == artistKey("\xCE\x95\xCE\xBB\xCE\xB5\xCC\x81\xCE\xBD\xCE\xB7"), "greek NFC==NFD");
    CHECK(artistKey("\xCE\xAA") == artistKey("\xCF\x8A"), "dialytika case");
    CHECK(artistKey("\xCF\x8A") == artistKey("\xCE\xB9"), "dialytika vs iota");
    CHECK(artistKey("\xD2\x90") == artistKey("\xD2\x91"), "cyrillic ghe upturn");

    TEST_MAIN_END();
}
