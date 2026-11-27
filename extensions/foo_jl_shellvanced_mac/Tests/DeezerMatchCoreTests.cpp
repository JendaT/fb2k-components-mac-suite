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
    TEST_MAIN_END();
}
