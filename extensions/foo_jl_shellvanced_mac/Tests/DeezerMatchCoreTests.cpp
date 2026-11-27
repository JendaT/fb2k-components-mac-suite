#include "../../../shared/Tests/TestHarness.h"
#include "../src/Artists/DeezerMatchCore.h"
#include "../src/Artists/ImageHashCore.h"
#include "../src/Artists/SpotifyMatchCore.h"

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

    g_context = "narrowByExactName";
    {
        std::vector<Candidate> a = {{"1", "Alps Core", "https://x/images/artist/abc/1.jpg", 1}, {"2", "ALPSCORE", "https://x/images/artist/abc/1.jpg", 1}};
        CHECK(narrowByExactName("Alpscore", a, exactCandidates("Alpscore", a)) == (std::vector<size_t>{1}), "Alpscore -> ALPSCORE");
        std::vector<Candidate> r = {{"1", "Radice.", "https://x/images/artist/abc/1.jpg", 1}, {"2", "Radice", "https://x/images/artist/abc/1.jpg", 1}};
        CHECK(narrowByExactName("Radice", r, exactCandidates("Radice", r)) == (std::vector<size_t>{1}), "Radice -> Radice");
        std::vector<Candidate> k = {{"1", "Kaya", "https://x/images/artist/abc/1.jpg", 1}, {"2", "KAYA", "https://x/images/artist/abc/1.jpg", 1}};
        CHECK(narrowByExactName("kaya", k, exactCandidates("kaya", k)) == (std::vector<size_t>{0, 1}), "two matches: no narrowing");
        std::vector<Candidate> n = {{"1", "Alps Core", "https://x/images/artist/abc/1.jpg", 1}, {"2", "Alpscore!", "https://x/images/artist/abc/1.jpg", 1}};
        CHECK(narrowByExactName("Alpscore", n, exactCandidates("Alpscore", n)) == (std::vector<size_t>{0, 1}), "no match: unchanged");
        std::vector<Candidate> u = {{"1", "BJÖRK", "https://x/images/artist/abc/1.jpg", 1}, {"2", "Bjork", "https://x/images/artist/abc/1.jpg", 1}};
        CHECK(narrowByExactName(" Björk ", u, exactCandidates("Björk", u)) == (std::vector<size_t>{0}), "accent kept, trimmed");
    }
    {
        const std::string pic = "https://x/images/artist/abc/56x56.jpg", none = "https://x/images/artist//56x56.jpg";
        std::vector<Candidate> a = {{"1", "Alps Core", pic, 1}, {"2", "ALPSCORE", none, 1}};
        CHECK(narrowByExactName("Alpscore", a, exactCandidates("Alpscore", a)) == (std::vector<size_t>{0, 1}), "photoless name match: no narrowing");
        std::vector<Candidate> b = {{"1", "Alps Core", none, 1}, {"2", "ALPSCORE", pic, 1}};
        CHECK(narrowByExactName("Alpscore", b, exactCandidates("Alpscore", b)) == (std::vector<size_t>{1}), "name match with photo narrows");
    }
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
    g_context = "loneRule";
    CHECK(!acceptLoneWithoutOverlap("Nala", 43), "Nala 43 rejected");
    CHECK(!acceptLoneWithoutOverlap("Question", 62), "Question 62 rejected");
    CHECK(acceptLoneWithoutOverlap("Nailik Hypnotik", 9), "Nailik 9 accepted");
    CHECK(!acceptLoneWithoutOverlap("Kaya", 3), "short key rejected");
    CHECK(!acceptLoneWithoutOverlap("Nailik Hypnotik", -1), "unknown count rejected");
    CHECK(acceptLoneWithoutOverlap("Nailik Hypnotik", 15) && !acceptLoneWithoutOverlap("Nailik Hypnotik", 16), "15 boundary");
    g_context = "placeholder";
    {
        const int W = 24, H = 24;
        std::vector<uint8_t> a(W * H * 4, 255), b(W * H * 4, 255), c(W * H * 4, 255);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            const int i = (y * W + x) * 4;
            const bool fig = (x > 7 && x < 16 && y > 5);
            const uint8_t v = fig ? 150 : 225;  // two-tone silhouette
            a[i] = v; a[i + 1] = v; a[i + 2] = (uint8_t)(v + 8);
            const uint8_t g = (uint8_t)((x * 10 + y * 3 + ((x * 7 + y * 13) % 17)) % 256);  // noisy gradient
            b[i] = g; b[i + 1] = g; b[i + 2] = g;
            c[i] = (uint8_t)(x * 10); c[i + 1] = (uint8_t)(y * 10); c[i + 2] = 40;
        }
        CHECK(looksLikePlaceholderPhoto(a.data(), W, H), "flat two-tone silhouette");
        CHECK(!looksLikePlaceholderPhoto(b.data(), W, H), "noisy grayscale gradient");
        CHECK(!looksLikePlaceholderPhoto(c.data(), W, H), "colorful");
    }
    g_context = "imagehash";
    {
        std::vector<uint8_t> a(9 * 8 * 4, 255), b, c, d;
        for (int y = 0; y < 8; y++) for (int x = 0; x < 9; x++) {
            uint8_t v = (uint8_t)((x * 25 + (y % 3) * 5) % 256);
            for (int k = 0; k < 3; k++) a[(y * 9 + x) * 4 + k] = v;
        }
        b = a; c = a; d = a;
        for (int y = 0; y < 8; y++) for (int x = 0; x < 9; x++) {
            const int i = (y * 9 + x) * 4;
            for (int k = 0; k < 3; k++) {
                b[i + k] = (uint8_t)std::min(255, a[i + k] + 3);          // brightness shift: same hash
                c[i + k] = (uint8_t)(((x * 7 + y) % 3 == 0) ? 255 - a[i + k] : a[i + k]);  // some bits differ
                d[i + k] = (uint8_t)(255 - a[i + k]);                       // inverted: all differ
            }
        }
        const uint64_t ha = imagehash::dHash9x8(a.data()), hb = imagehash::dHash9x8(b.data());
        const uint64_t hc = imagehash::dHash9x8(c.data()), hd = imagehash::dHash9x8(d.data());
        CHECK_EQ(imagehash::hammingDistance(ha, ha), 0, "identical");
        CHECK(imagehash::hammingDistance(ha, hb) <= 2, "similar");
        CHECK(imagehash::hammingDistance(ha, hd) > 10, "different");
        CHECK(imagehash::isCoverLike(ha, {hd, hb}), "match among covers");
        CHECK(!imagehash::isCoverLike(ha, {hd}), "no match");
        CHECK(!imagehash::isCoverLike(ha, {}), "no covers");
        (void)hc;
        CHECK_EQ(imagehash::hammingDistance(0, ~0ull), 64, "hamming 64");
        CHECK(imagehash::isCoverLike(0, {0x3FFull}) && !imagehash::isCoverLike(0, {0x7FFull}), "threshold 10");
    }
    g_context = "spotify";
    {
        using spmatch::Image;
        CHECK(spmatch::pickImageUrl({{"a", 640}, {"b", 320}, {"c", 160}}) == "a", "640 chosen");
        CHECK(spmatch::pickImageUrl({{"big", 1000}, {"m", 640}, {"s", 300}}) == "m", "largest <= 640");
        CHECK(spmatch::pickImageUrl({{"big", 1000}, {"bigger", 1400}}) == "big", "all large: smallest");
        CHECK(spmatch::pickImageUrl({{"u", 0}}) == "u", "unknown width");
        CHECK(spmatch::pickImageUrl({}).empty(), "none");
        std::vector<spmatch::Candidate> c = {{"1", "Nailik Hypnotik", "u"}, {"2", "NAILIK HYPNOTIK", ""}, {"3", "Nailik", "u"}};
        CHECK(spmatch::exactCandidates("nailik hypnotik", c) == (std::vector<size_t>{0, 1}), "exact set keeps image-less candidates");
        CHECK(spmatch::parseRetryAfter("120") == 120, "retry 120");
        CHECK(spmatch::parseRetryAfter("") == 3600 && spmatch::parseRetryAfter("abc", 77) == 77, "retry fallback");
        CHECK(spmatch::parseRetryAfter("0") == 1 && spmatch::parseRetryAfter("99999999") == 7 * 24 * 3600, "retry clamp");
        CHECK(spmatch::base64("") == "" && spmatch::base64("f") == "Zg==" && spmatch::base64("fo") == "Zm8=" &&
              spmatch::base64("foo") == "Zm9v" && spmatch::base64("foobar") == "Zm9vYmFy", "base64 vectors");
        CHECK(spmatch::basicAuthValue("Aladdin", "open sesame") == "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==", "basic auth");
        using V = std::vector<std::string>;
        using RT = spmatch::RemoteTitles;
        // Nala: user album "Ubuntu" + track "Interlude" vs another Nala's single "Interlude".
        CHECK(!spmatch::confirmed(V{"ubuntu"}, V{"ubuntu", "nightfall"}, RT{V{"nightfall"}, V{"nightfall"}}), "track vs single: rejected");
        CHECK(!spmatch::confirmed(V{"ubuntu"}, V{"ubuntu", "nightfall"}, RT{V{}, V{"nightfall"}}), "track vs appears_on: rejected");
        CHECK(spmatch::confirmed(V{"ubuntu"}, V{"ubuntu", "nightfall"}, RT{V{"ubuntu"}, V{"ubuntu"}}), "album vs album/single: accepted");
        CHECK(!spmatch::confirmed(V{"ubuntu"}, V{"ubuntu"}, RT{V{}, V{"ubuntu"}}), "album vs appears_on only: single rejected");
        CHECK(!spmatch::confirmed(V{"home"}, V{"home"}, RT{V{"home"}, V{"home"}}), "short single title: rejected");
        CHECK(spmatch::confirmed(V{"ubuntu"}, V{"ubuntu", "nightfall"}, RT{V{"nightfall"}, V{"nightfall", "ubuntu"}}), "album vs any group + track vs primary: accepted");
        CHECK(spmatch::confirmed(V{}, V{"night drive", "blue hour"}, RT{V{"night drive", "blue hour"}, V{"night drive", "blue hour"}}), "two track matches vs primary: accepted");
        CHECK(!spmatch::confirmed(V{}, V{"replication"}, RT{V{"replication"}, V{"replication"}}), "one track only: rejected");
        CHECK(!spmatch::confirmed(V{}, V{"paradise", "sunrise"}, RT{V{}, V{"paradise beach chillout", "sunrise yoga vol 2"}}), "tracks vs appears_on containment: rejected");
        CHECK(!spmatch::confirmed(V{}, V{"paradise", "sunrise"}, RT{V{}, V{"paradise", "sunrise"}}), "tracks vs appears_on exact: rejected");
        CHECK(spmatch::confirmed(V{}, V{"paradise", "sunrise"}, RT{V{"paradise", "sunrise"}, V{"paradise", "sunrise"}}), "tracks vs exact album/single: accepted");
        CHECK(spmatch::confirmed(V{"paradise", "sunrise"}, V{"paradise", "sunrise"}, RT{V{}, V{"paradise", "sunrise"}}), "albums vs appears_on exact: accepted");
        CHECK_EQ(spmatch::chooseConfirmed(V{"ubuntu"}, V{"ubuntu"}, {RT{V{"x"}, V{"x"}}, RT{V{"ubuntu"}, V{"ubuntu"}}}), 1, "choose confirmed");
        CHECK_EQ(spmatch::chooseConfirmed(V{"ubuntu"}, V{"ubuntu"}, {RT{V{"ubuntu"}, V{"ubuntu"}}, RT{V{"ubuntu"}, V{"ubuntu"}}}), -1, "ambiguous");
        CHECK_EQ(spmatch::chooseConfirmed(V{"ubuntu"}, V{"ubuntu"}, {RT{V{"x"}, V{"x"}}}), -1, "none");
        CHECK(!deezermatch::acceptLoneWithoutOverlap("Nailik Hypnotik", -1), "unknown total (-1) rejected");
        CHECK_EQ((long long)spmatch::clampBlockUntil(1000, 1000), 1000, "block kept");
        CHECK_EQ((long long)spmatch::clampBlockUntil(1e12, 1000), 1000 + 7 * 24 * 3600, "block clamped to +7d");
        CHECK_EQ((long long)spmatch::clampBlockUntil(-5, 1000), 0, "negative block dropped");
        spmatch::FailureTracker ft;
        for (int i = 0; i < 4; i++) ft.record(true);
        CHECK(!ft.tripped(), "4 failures ok");
        ft.record(false);
        for (int i = 0; i < 4; i++) ft.record(true);
        CHECK(!ft.tripped(), "reset by success");
        ft.record(true);
        CHECK(ft.tripped(), "5 consecutive trips");
        CHECK(spmatch::needsSpotify(false, false, true), "no deezer photo -> spotify");
        CHECK(spmatch::needsSpotify(true, true, true), "cover-like -> spotify");
        CHECK(!spmatch::needsSpotify(true, false, true), "real photo -> deezer");
        CHECK(!spmatch::needsSpotify(false, false, false) && !spmatch::needsSpotify(true, true, false), "unavailable -> no spotify");
    }
    g_context = "cleanTitle";
    {
        using V = std::vector<std::string>;
        const std::string A = "Kaikkialla";
        const V collabs = {"Kaikkialla VS Maramba"};
        auto cn = [&](const char* t) { return cleanNormalizedTitle(t, A, collabs); };
        CHECK(cn("Kaikkialla - Lentas (191bpm) Released on Zeakon Records") == "lentas", "Lentas");
        CHECK(cn("Kaikkialla - The Sumerian [190] Soon On STZ - Records") == "the sumerian", "The Sumerian");
        CHECK(cn("Kaikkialla - Illusion Of Diversity [174] SOOn on Kamayura Rec") == "illusion of diversity", "Illusion Of Diversity");
        CHECK(cn("Kaikkialla - Overt\xC3\xBCre [175] SOON OUT") == cn("Overt\xC3\xBCre"), "Overture");
        CHECK(cn("Kaikkialla Meets Yaminahua - Digital Jungle Master16") == "digital jungle", "Digital Jungle");
        CHECK(cn("Kaikkialla VS Maramba - Hybrid") == "hybrid", "collab prefix");
        CHECK(cn("V/A Pushing The Boundary Compiled By  JokerFox") == "pushing the boundary", "Pushing The Boundary");
        CHECK(cn("VA - Pushing The Boundary") == "pushing the boundary", "VA prefix");
        CHECK(cn("Strange Day [Am] Free Download") == "strange day", "key bracket + free download");
        CHECK(cn("Strange Day (200 Bpm) Original Mix") == "strange day", "bpm + original mix");
        CHECK(cn("Strange Day [8A]") == "strange day", "camelot");
        CHECK(cn("Out Now") == "out now", "never emptied");
        CHECK(cn("Puppet Master") == "puppet master", "Master kept without digits");
        CHECK(cn("Someone Else - Track") == "someone else track", "unrelated prefix kept");
        CHECK(cleanTitle("Va Bene", A) == "Va Bene", "lowercase Va kept");
        CHECK(cn("Lentas") == cn("Kaikkialla - Lentas (191bpm) Released on Zeakon Records"), "both sides match");
        CHECK(cn("Overt\xC3\xBCre") == "overture", "diaeresis folded");
    }
    g_context = "coArtists";
    {
        using V = std::vector<std::string>;
        using RT = spmatch::RemoteTitles;
        // exact (cleaned) rule still wins alone
        CHECK(spmatch::confirmed(V{}, V{"lentas", "the sumerian"}, RT{V{"lentas", "the sumerian"}, V{"lentas", "the sumerian"}}), "branch 1: two exact");
        // branch 2: shared co-artist + one exact match of any kind (track vs appears_on-only title)
        CHECK(spmatch::confirmed(V{}, V{"lentas"}, RT{V{}, V{"lentas"}, V{"maramba"}}, V{"maramba", "yaminahua"}), "branch 2: 1 shared + 1 exact");
        CHECK(!spmatch::confirmed(V{}, V{"lentas"}, RT{V{}, V{"lentas"}, V{"other"}}, V{"maramba", "yaminahua"}), "1 exact, no shared: rejected");
        CHECK(!spmatch::confirmed(V{}, V{"lentas"}, RT{V{}, V{"x"}, V{"maramba"}}, V{"maramba"}), "1 shared, no exact: rejected");
        CHECK(!spmatch::confirmed(V{}, V{"night drive"}, RT{V{}, V{"night drive extended"}, V{"maramba"}}, V{"maramba"}), "1 shared + containment only: rejected");
        // branch 3: two distinct shared keys, no title evidence
        CHECK(spmatch::confirmed(V{}, V{"abc"}, RT{V{}, V{"zzz"}, V{"maramba", "yaminahua", "x"}}, V{"maramba", "yaminahua", "popolvuhrecords"}), "branch 3: 2 shared");
        CHECK(!spmatch::confirmed(V{}, V{"abc"}, RT{V{}, V{"zzz"}, V{"maramba", "maramba"}}, V{"maramba", "maramba"}), "duplicate key counts once");
        // stranger "Nala": no shared co-artists, containment-only title matches
        CHECK(!spmatch::confirmed(V{"night drive"}, V{"night drive", "blue hour"},
                                  RT{V{"night drive extended"}, V{"night drive extended", "blue hour mix"}, V{"someoneelse"}}, V{"maramba", "yaminahua"}),
              "Nala stranger rejected");
        CHECK(!spmatch::confirmed(V{}, V{"abc"}, RT{V{}, V{"abc"}, V{"maramba"}}, V{}), "no user co-artists: no evidence");
        // branch 2 title strength: short non-album title does not count; a short user ALBUM title does
        CHECK(!spmatch::confirmed(V{}, V{"lent"}, RT{V{}, V{"lent"}, V{"maramba"}}, V{"maramba"}), "branch 2: short track title rejected");
        CHECK(spmatch::confirmed(V{"lent"}, V{"lent"}, RT{V{}, V{"lent"}, V{"maramba"}}, V{"maramba"}), "branch 2: short album title ok");
        CHECK(spmatch::confirmed(V{}, V{"lentas"}, RT{V{}, V{"lentas"}, V{"maramba"}}, V{"maramba"}), "branch 2: 6-char track title ok");
        // generic titles never match, in any branch
        CHECK(!spmatch::confirmed(V{}, V{"intro", "outro"}, RT{V{"intro", "outro"}, V{"intro", "outro"}}), "branch 1: generic ignored");
        CHECK(!spmatch::confirmed(V{"interlude"}, V{"interlude"}, RT{V{"interlude"}, V{"interlude"}}), "single-strong: generic ignored");
        CHECK(!spmatch::confirmed(V{"original mix", "track 05"}, V{"original mix", "track 05", "bonus track", "abc"}, RT{V{"original mix", "track 05", "bonus track", "abc"}, V{"original mix", "track 05", "bonus track", "abc"}}), "stoplist + <4 chars");
        CHECK(!spmatch::confirmed(V{}, V{"intro"}, RT{V{}, V{"intro"}, V{"maramba"}}, V{"maramba"}), "branch 2: generic ignored");
        // ambiguity still applies
        CHECK_EQ(spmatch::chooseConfirmed(V{}, V{"lentas"}, {RT{V{}, V{"lentas"}, V{"maramba"}}, RT{V{}, V{"lentas"}, V{"maramba"}}}, V{"maramba"}), -1, "two confirmed: ambiguous");
        CHECK_EQ(spmatch::chooseConfirmed(V{}, V{"lentas"}, {RT{V{}, V{"lentas"}, V{"maramba"}}, RT{V{}, V{"q"}, V{}}}, V{"maramba"}), 0, "one confirmed via co-artist");
    }
    TEST_MAIN_END();
}
