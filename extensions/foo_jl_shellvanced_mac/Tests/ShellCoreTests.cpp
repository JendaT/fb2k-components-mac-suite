//
//  ShellCoreTests.cpp
//  foo_jl_shellvanced_mac
//
//  Unit tests for ShellCore (navigation history, sidebar playlist filter,
//  library filter chips). Pure C++, compiled standalone;
//  run as a gating phase by Scripts/build.sh.
//

#include "../src/Core/ShellCore.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using namespace shellcore;

static Destination albums() { return {DestKind::Albums, ""}; }
static Destination pl(const char* n) { return {DestKind::Playlist, n}; }
static Destination artist(const char* n) { return {DestKind::Artist, n}; }

static bool is(const std::optional<Destination>& got, const Destination& want) {
    return got.has_value() && *got == want;
}

static void testBackForward() {
    g_context = "back/forward";
    NavHistory h;
    CHECK(!h.current().has_value(), "empty history has no current");
    CHECK(!h.canGoBack(), "empty: no back");
    CHECK(!h.canGoForward(), "empty: no forward");
    CHECK(!h.back().has_value(), "empty: back() is nullopt");
    CHECK(!h.forward().has_value(), "empty: forward() is nullopt");

    h.push(pl("A"));
    h.push(pl("B"));
    h.push(pl("C"));
    CHECK(is(h.current(), pl("C")), "current is C");
    CHECK(h.canGoBack(), "can go back from C");
    CHECK(is(h.back(), pl("B")), "back() == B");
    CHECK(is(h.back(), pl("A")), "back() == A");
    CHECK(!h.canGoBack(), "no back from A");
    CHECK(!h.back().has_value(), "back() at start is nullopt");
    CHECK(is(h.current(), pl("A")), "still at A");
    CHECK(h.canGoForward(), "can go forward from A");
    CHECK(is(h.forward(), pl("B")), "forward() == B");
    CHECK(is(h.current(), pl("B")), "current is B");
}

static void testPushTruncatesForward() {
    g_context = "push truncates";
    NavHistory h;
    h.push(pl("A"));
    h.push(pl("B"));
    h.push(pl("C"));
    h.back();
    h.back();
    h.push(pl("D"));
    CHECK(!h.canGoForward(), "push after back clears forward stack");
    CHECK(is(h.current(), pl("D")), "current is D");
    CHECK(is(h.back(), pl("A")), "back from D lands on A");
    CHECK(!h.canGoBack(), "B and C are gone");
}

static void testPushSameIsNoop() {
    g_context = "push same";
    NavHistory h;
    h.push(albums());
    h.push(albums());
    CHECK(!h.canGoBack(), "pushing the current destination does not grow history");
    h.push(pl("A"));
    h.push(pl("A"));
    CHECK(is(h.back(), albums()), "one back from A reaches Albums");
    CHECK(!h.canGoBack(), "only two entries");
    // Pushing the current destination must not truncate the forward stack.
    h.push(albums());
    CHECK(h.canGoForward(), "push(current) keeps forward stack");
}

static void testEquality() {
    g_context = "equality";
    CHECK(pl("A") == pl("A"), "same playlist equal");
    CHECK(!(pl("A") == pl("B")), "different names differ");
    CHECK(!(pl("A") == artist("A")), "different kinds differ");
    CHECK(albums() == albums(), "albums equal");
}

static void testRename() {
    g_context = "rename";
    NavHistory h;
    h.push(pl("A"));
    h.push(artist("A"));
    h.push(pl("B"));
    h.push(pl("A"));
    h.renamePlaylist("A", "Z");
    CHECK(is(h.current(), pl("Z")), "current renamed");
    CHECK(is(h.back(), pl("B")), "B untouched");
    CHECK(is(h.back(), artist("A")), "artist with same name untouched");
    CHECK(is(h.back(), pl("Z")), "older entry renamed");
}

static void testRemove() {
    g_context = "remove";
    {
        // [Albums, P1, Albums] remove P1 -> [Albums] (duplicates collapse)
        NavHistory h;
        h.push(albums());
        h.push(pl("P1"));
        h.push(albums());
        h.remove(pl("P1"));
        CHECK(is(h.current(), albums()), "current stays Albums");
        CHECK(!h.canGoBack(), "collapsed to a single entry");
        CHECK(!h.canGoForward(), "nothing forward");
    }
    {
        // Removing the current entry moves current to the previous survivor.
        NavHistory h;
        h.push(albums());
        h.push(pl("P1"));
        h.push(pl("P2"));
        h.back();               // current = P1, forward = P2
        h.remove(pl("P1"));
        CHECK(is(h.current(), albums()), "current falls back to Albums");
        CHECK(h.canGoForward(), "P2 still forward");
        CHECK(is(h.forward(), pl("P2")), "forward reaches P2");
    }
    {
        // Removing an entry ahead of current keeps current.
        NavHistory h;
        h.push(pl("A"));
        h.push(pl("B"));
        h.push(pl("C"));
        h.back();
        h.back();               // current = A
        h.remove(pl("B"));
        CHECK(is(h.current(), pl("A")), "current A kept");
        CHECK(is(h.forward(), pl("C")), "forward is C");
        CHECK(!h.canGoForward(), "C is last");
    }
    {
        // Removing everything empties the history.
        NavHistory h;
        h.push(pl("A"));
        h.push(pl("A2"));
        h.removeIf([](const Destination& d) { return d.kind == DestKind::Playlist; });
        CHECK(!h.current().has_value(), "history empty");
        CHECK(!h.canGoBack() && !h.canGoForward(), "no navigation");
        h.push(albums());
        CHECK(is(h.current(), albums()), "usable after emptying");
    }
}

static bool vecEq(const std::vector<size_t>& a, const std::vector<size_t>& b) { return a == b; }

static void testSidebarPlaylists() {
    g_context = "sidebarPlaylists";
    CHECK(vecEq(sidebarPlaylists({"Now Playing", "Hitech", "Tek"}), {1, 2}), "Now Playing excluded");
    CHECK(vecEq(sidebarPlaylists({"now playing"}), {0}), "exact match only");
    CHECK(vecEq(sidebarPlaylists({"Now Playing "}), {0}), "trailing space is a different name");
    CHECK(sidebarPlaylists({}).empty(), "empty -> empty");
    CHECK(vecEq(sidebarPlaylists({"A", "Now Playing", "B", "Now Playing"}), {0, 2}), "every Now Playing excluded");
}

static void testLibraryFilter() {
    g_context = "library filter";
    CHECK(toggleFilter(LibraryFilter::All, LibraryFilter::Playlists) == LibraryFilter::Playlists, "select Playlists");
    CHECK(toggleFilter(LibraryFilter::Playlists, LibraryFilter::Playlists) == LibraryFilter::All, "deselect Playlists");
    CHECK(toggleFilter(LibraryFilter::Playlists, LibraryFilter::Artists) == LibraryFilter::Artists, "chips are exclusive");
    CHECK(showsPlaylists(LibraryFilter::All) && showsArtists(LibraryFilter::All), "none selected = both");
    CHECK(showsPlaylists(LibraryFilter::Playlists) && !showsArtists(LibraryFilter::Playlists), "playlists only");
    CHECK(!showsPlaylists(LibraryFilter::Artists) && showsArtists(LibraryFilter::Artists), "artists only");
    CHECK(filterFromInt(0) == LibraryFilter::All, "0 -> All");
    CHECK(filterFromInt(1) == LibraryFilter::Playlists, "1 -> Playlists");
    CHECK(filterFromInt(2) == LibraryFilter::Artists, "2 -> Artists");
    CHECK(filterFromInt(99) == LibraryFilter::All, "garbage -> All");
    CHECK(filterFromInt(-1) == LibraryFilter::All, "negative -> All");
}

static void testAlbumDestination() {
    g_context = "album destination";
    const std::string k = albumKey("Daft Punk", "Discovery");
    CHECK(albumKeyArtist(k) == "Daft Punk", "key artist");
    CHECK(albumKeyTitle(k) == "Discovery", "key title");
    CHECK(albumKeyArtist(albumKey("", "Untitled")) == "", "empty artist allowed");
    CHECK(albumKeyTitle(albumKey("", "Untitled")) == "Untitled", "title with empty artist");
    CHECK(albumKeyTitle("no separator") == "no separator", "malformed key -> whole string as title");
    const std::string ky = albumKey("Daft Punk", "Discovery", "2001");
    CHECK(albumKeyArtist(ky) == "Daft Punk" && albumKeyTitle(ky) == "Discovery" && albumKeyYear(ky) == "2001", "key with year");
    CHECK(ky != albumKey("Daft Punk", "Discovery", "2021"), "editions differ by year");
    CHECK(albumKeyYear(albumKey("A", "B")) == "", "empty year");
    CHECK(albumKeyHasYear(albumKey("A", "B")) && !albumKeyHasYear("A\x1f" "B") && albumKeyHasYear(ky), "year part present vs old two-part key");
    const std::string old = std::string("Daft Punk") + kAlbumKeySeparator + "Discovery";
    CHECK(albumKeyTitle(old) == "Discovery" && albumKeyYear(old) == "", "old-format key: title ok, year unknown");
    Destination a{DestKind::Album, k};
    CHECK(a != artist("Daft Punk"), "album differs from artist");
    CHECK(a == Destination({DestKind::Album, k}), "same album equal");
    CHECK(static_cast<int>(DestKind::Album) == 3, "persisted value stable");
    NavHistory h;
    h.push(artist("Daft Punk"));
    h.push(a);
    CHECK(is(h.back(), artist("Daft Punk")), "back from album to artist");
    CHECK(is(h.forward(), a), "forward to album");
    h.remove(a);
    CHECK(is(h.current(), artist("Daft Punk")), "removing the album falls back");
}

static void testAlbumFormatting() {
    g_context = "album formatting";
    CHECK(albumYear("2024-02-26") == "2024", "year from full date");
    CHECK(albumYear("2020") == "2020", "plain year");
    CHECK(albumYear("") == "", "empty date");
    CHECK(albumYear("c. 1999") == "c. 1999", "non-numeric kept");
    CHECK(formatTrackLength(187) == "3:07", "m:ss");
    CHECK(formatTrackLength(59.6) == "1:00", "rounds");
    CHECK(formatTrackLength(3723) == "1:02:03", "h:mm:ss");
    CHECK(formatTrackLength(-1) == "", "negative blank");
    CHECK(albumStats(12, 45 * 60) == "12 songs, 45 min", "minutes only");
    CHECK(albumStats(1, 20) == "1 song, 1 min", "singular, at least a minute");
    CHECK(albumStats(20, 65 * 60) == "20 songs, 1 hr 5 min", "hours and minutes");
    CHECK(albumStats(30, 120 * 60) == "30 songs, 2 hr", "whole hours");
    CHECK(albumStats(0, 0) == "0 songs, 1 min", "empty");
}

static void testSearchMatches() {
    g_context = "search matches";
    CHECK(searchMatches("hitech", ""), "empty query matches all");
    CHECK(searchMatches("hitech", "tec"), "substring");
    CHECK(searchMatches("hitech", "hi"), "prefix");
    CHECK(!searchMatches("hitech", "tek"), "non-substring");
    CHECK(!searchMatches("", "a"), "empty haystack");
}

int main() {
    testBackForward();
    testPushTruncatesForward();
    testPushSameIsNoop();
    testEquality();
    testRename();
    testRemove();
    testSidebarPlaylists();
    testLibraryFilter();
    testAlbumDestination();
    testAlbumFormatting();
    testSearchMatches();
    TEST_MAIN_END();
}
