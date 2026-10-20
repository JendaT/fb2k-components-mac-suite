//
//  RemoteApiTests.cpp
//  foo_jl_remote_mac
//
// TEST_DEPS: src/Core/HttpRequest.cpp src/Core/NetworkPolicy.cpp

#include "TestHarness.h"
#include "../src/Core/RemoteApi.h"

using namespace remote_api;
using remote_http::Request;

static Request makeRequest(const std::string& method, const std::string& path, bool clientHeader) {
    Request r;
    r.method = method;
    r.path = path;
    r.headers["host"] = "192.168.1.5:8890";
    if (clientHeader) r.headers[kClientHeader] = "1";
    return r;
}

static void testRouting() {
    g_context = "routing";
    const std::string phone = "192.168.1.20";

    Decision d = decide(makeRequest("GET", "/", false), phone);
    CHECK(d.errorStatus == 0 && d.route == Route::Index, "index");
    d = decide(makeRequest("GET", "/index.html", false), phone);
    CHECK(d.errorStatus == 0 && d.route == Route::Index, "index.html");
    d = decide(makeRequest("GET", "/api/state", false), phone);
    CHECK(d.errorStatus == 0 && d.route == Route::State, "state needs no client header");

    struct { const char* path; Route route; } posts[] = {
        { "/api/play_pause", Route::PlayPause }, { "/api/play", Route::Play },
        { "/api/pause", Route::Pause }, { "/api/stop", Route::Stop },
        { "/api/next", Route::Next }, { "/api/previous", Route::Previous },
        { "/api/volume", Route::Volume }, { "/api/mute", Route::Mute },
        { "/api/seek", Route::Seek },
        { "/api/play_item", Route::PlayItem },
    };
    for (const auto& p : posts) {
        g_context = std::string("routing ") + p.path;
        d = decide(makeRequest("POST", p.path, true), phone);
        CHECK(d.errorStatus == 0 && d.route == p.route, "POST routes");
        CHECK_EQ(decide(makeRequest("GET", p.path, true), phone).errorStatus, 405, "GET not allowed");
    }

    g_context = "routing playlists";
    d = decide(makeRequest("GET", "/api/playlists", false), phone);
    CHECK(d.errorStatus == 0 && d.route == Route::Playlists, "playlists is a GET");
    d = decide(makeRequest("GET", "/api/playlist_items", false), phone);
    CHECK(d.errorStatus == 0 && d.route == Route::PlaylistItems, "playlist_items is a GET");
    CHECK_EQ(decide(makeRequest("POST", "/api/playlists", true), phone).errorStatus, 405, "POST to playlists");

    g_context = "routing errors";
    CHECK_EQ(decide(makeRequest("GET", "/nope", false), phone).errorStatus, 404, "unknown path");
    CHECK_EQ(decide(makeRequest("POST", "/api/state", true), phone).errorStatus, 405, "POST to GET route");
    CHECK_EQ(decide(makeRequest("GET", "/../etc/passwd", false), phone).errorStatus, 404, "no file serving");
}

static void testAccess() {
    g_context = "access";
    CHECK_EQ(decide(makeRequest("GET", "/", false), "8.8.8.8").errorStatus, 403, "public client");
    CHECK_EQ(decide(makeRequest("POST", "/api/next", false), "192.168.1.20").errorStatus, 403, "POST without client header");

    Request rebinding = makeRequest("POST", "/api/next", true);
    rebinding.headers["host"] = "evil.example.com";
    CHECK_EQ(decide(rebinding, "192.168.1.20").errorStatus, 403, "foreign Host");

    Request noHost = makeRequest("GET", "/api/state", false);
    noHost.headers.erase("host");
    CHECK_EQ(decide(noHost, "192.168.1.20").errorStatus, 403, "missing Host");

    // Access is checked before routing, so outsiders cannot probe paths.
    CHECK_EQ(decide(makeRequest("GET", "/nope", false), "8.8.8.8").errorStatus, 403, "403 before 404");
}

static void testParseNumber() {
    g_context = "parseNumber";
    double v = 0;
    CHECK(parseNumber("-42.5", v) && v == -42.5, "negative decimal");
    CHECK(parseNumber("0", v) && v == 0.0, "zero");
    CHECK(parseNumber("+1", v) && v == 1.0, "explicit plus");
    CHECK(parseNumber(".5", v) && v == 0.5, "leading dot");
    CHECK(!parseNumber("", v), "empty");
    CHECK(!parseNumber("nan", v), "nan");
    CHECK(!parseNumber("inf", v), "inf");
    CHECK(!parseNumber("0x10", v), "hex");
    CHECK(!parseNumber(" 1", v), "leading space");
    CHECK(!parseNumber("1e3", v), "exponent");
    CHECK(!parseNumber("1-", v), "trailing junk");
    CHECK(!parseNumber("-", v), "sign only");
}

static void testVolume() {
    g_context = "volume";
    CHECK_FLOAT_EQ(clampVolumeDb(-150), kMinVolumeDb, "clamp low");
    CHECK_FLOAT_EQ(clampVolumeDb(6), kMaxVolumeDb, "clamp high");
    CHECK_FLOAT_EQ(clampVolumeDb(-42.5), -42.5, "in range");

    VolumeCommand abs = parseVolumeCommand({{"db", "-42.5"}});
    CHECK(abs.valid && !abs.relative, "absolute command");
    CHECK_FLOAT_EQ(resolveVolume(-10, abs), -42.5, "absolute replaces");

    VolumeCommand down = parseVolumeCommand({{"delta", "-0.5"}});
    CHECK(down.valid && down.relative, "relative command");
    CHECK_FLOAT_EQ(resolveVolume(-40, down), -40.5, "half dB down");
    CHECK_FLOAT_EQ(resolveVolume(-99.8, down), -100, "delta clamps at mute");

    VolumeCommand up = parseVolumeCommand({{"delta", "0.5"}});
    CHECK_FLOAT_EQ(resolveVolume(-0.2, up), 0, "delta clamps at 0 dB");
    CHECK_FLOAT_EQ(resolveVolume(-100, up), -99.5, "up from mute");

    VolumeCommand loud = parseVolumeCommand({{"db", "12"}});
    CHECK_FLOAT_EQ(resolveVolume(-50, loud), 0, "absolute clamps at 0 dB");

    CHECK(!parseVolumeCommand({}).valid, "no argument");
    CHECK(!parseVolumeCommand({{"db", "-1"}, {"delta", "1"}}).valid, "both arguments");
    CHECK(!parseVolumeCommand({{"db", "loud"}}).valid, "not a number");
    CHECK(!parseVolumeCommand({{"db", ""}}).valid, "empty value");
    CHECK_FLOAT_EQ(resolveVolume(-30, VolumeCommand{}), -30, "invalid command keeps volume");
}

static void testSeek() {
    g_context = "seek";
    double s = -1;
    CHECK(parseSeekPosition({{"position", "93.5"}}, s) && s == 93.5, "position");
    CHECK(parseSeekPosition({{"position", "0"}}, s) && s == 0, "start");
    CHECK(!parseSeekPosition({{"position", "-1"}}, s), "negative");
    CHECK(!parseSeekPosition({}, s), "missing");
}

static void testParseIndex() {
    g_context = "parseIndex";
    size_t v = 99;
    CHECK(parseIndex("0", v) && v == 0, "zero");
    CHECK(parseIndex("17", v) && v == 17, "small");
    CHECK(parseIndex("999999999", v) && v == 999999999, "nine digits");
    CHECK(!parseIndex("1000000000", v), "ten digits");
    CHECK(!parseIndex("", v), "empty");
    CHECK(!parseIndex("-1", v), "negative");
    CHECK(!parseIndex("+1", v), "plus sign");
    CHECK(!parseIndex("1.0", v), "decimal");
    CHECK(!parseIndex(" 1", v), "space");
}

static void testItemsQuery() {
    g_context = "parseItemsQuery";
    ItemsQuery q = parseItemsQuery({{"playlist", "2"}});
    CHECK(q.valid && q.playlist == 2, "playlist only");
    CHECK_EQ(q.offset, 0, "default offset");
    CHECK_EQ(q.limit, kDefaultPageSize, "default limit");

    q = parseItemsQuery({{"playlist", "0"}, {"offset", "400"}, {"limit", "50"}});
    CHECK(q.valid && q.offset == 400 && q.limit == 50, "explicit page");

    CHECK_EQ(parseItemsQuery({{"playlist", "0"}, {"limit", "100000"}}).limit, kMaxPageSize, "limit clamps high");
    CHECK_EQ(parseItemsQuery({{"playlist", "0"}, {"limit", "0"}}).limit, 1, "limit clamps low");

    CHECK(!parseItemsQuery({}).valid, "missing playlist");
    CHECK(!parseItemsQuery({{"playlist", "x"}}).valid, "bad playlist");
    CHECK(!parseItemsQuery({{"playlist", "1"}, {"offset", "-5"}}).valid, "bad offset");
    CHECK(!parseItemsQuery({{"playlist", "1"}, {"limit", "lots"}}).valid, "bad limit");
}

static void testItemRef() {
    g_context = "parseItemRef";
    ItemRef ref = parseItemRef({{"playlist", "2"}, {"item", "17"}});
    CHECK(ref.valid && ref.playlist == 2 && ref.item == 17 && !ref.hasCount, "without count");

    ref = parseItemRef({{"playlist", "2"}, {"item", "17"}, {"count", "340"}});
    CHECK(ref.valid && ref.hasCount && ref.count == 340, "with count");

    CHECK(!parseItemRef({{"playlist", "2"}}).valid, "missing item");
    CHECK(!parseItemRef({{"item", "2"}}).valid, "missing playlist");
    CHECK(!parseItemRef({{"playlist", "2"}, {"item", "-1"}}).valid, "negative item");
    CHECK(!parseItemRef({{"playlist", "2"}, {"item", "1"}, {"count", "many"}}).valid, "bad count");
}

static void testPageRange() {
    g_context = "pageRange";
    PageRange r = pageRange(1000, 0, 200);
    CHECK(r.begin == 0 && r.end == 200, "first page");
    r = pageRange(1000, 900, 200);
    CHECK(r.begin == 900 && r.end == 1000, "last partial page");
    r = pageRange(1000, 1000, 200);
    CHECK(r.begin == 1000 && r.end == 1000, "offset at end");
    r = pageRange(1000, 5000, 200);
    CHECK(r.begin == 1000 && r.end == 1000, "offset past end");
    r = pageRange(0, 0, 200);
    CHECK(r.begin == 0 && r.end == 0, "empty playlist");
    r = pageRange((size_t)-1, (size_t)-10, 500);
    CHECK(r.end == (size_t)-1 && r.begin == (size_t)-10, "no overflow near SIZE_MAX");
}

int main() {
    testRouting();
    testAccess();
    testParseNumber();
    testVolume();
    testSeek();
    testParseIndex();
    testItemsQuery();
    testItemRef();
    testPageRange();
    TEST_MAIN_END();
}
