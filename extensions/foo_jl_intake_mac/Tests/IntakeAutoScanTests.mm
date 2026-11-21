//
//  IntakeAutoScanTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeAutoScan (B12). The filter: what counts (created,
//  renamed, modified; not removal-only or metadata-only), every ignored
//  name and folder (also ".intake-hint.json" and ".INTAKE.JSON"), only the
//  components below the income folder checked, the income match (longest
//  fsPath, ASCII case, NFC, the physical spelling, the folder itself, a
//  top-level file, outside every income, no match without a '/'
//  boundary), rescan and dropped events under an income, on an ancestor
//  and with no path, Mount/Unmount and HistoryDone never counting, mutes
//  by event id (below, at and after the start and end ids, an end not yet
//  known, passed mutes), open and closed files, and one report per income
//  per callback. The income entries from a WatchSet. Presence: local (also
//  through a local symlink), on a mounted share, missing (unmounted mount
//  point, absent folder, no mount table), a loop, with a recording link
//  reader proving nothing at or under the share is ever examined, and one
//  real temp directory through posixLinkReader. The scheduler on a fake
//  clock: the quiet period and its postponement, due exactly at 60 s, the
//  open-file hold and its 30-minute cap, one at a time, a busy lane, oldest
//  first, coalescing, events during a run (exactly one more run), startup,
//  every exit, turning auto-scan off while Checking and Running, a removed
//  or moved income, stale snapshots, and nextWakeup. Synthetic names only.
//
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeWatchSet.mm src/Core/IntakeMountAliases.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm
// TEST_FRAMEWORKS: CoreServices
//

#import <Foundation/Foundation.h>

#include <CoreServices/CoreServices.h>

#include "../src/Core/IntakeAutoScan.h"
#include "../src/Core/IntakePath.h"
#include "TestHarness.h"

#include <climits>
#include <cstdlib>
#include <map>
#include <set>
#include <string>
#include <unistd.h>
#include <vector>

using namespace intake;
using Sched = AutoScanScheduler;
using std::chrono::minutes;
using std::chrono::seconds;

namespace {

constexpr uint32_t F = fsevent::kItemIsFile;
constexpr uint32_t D = fsevent::kItemIsDir;
constexpr uint32_t C = fsevent::kItemCreated;
constexpr uint32_t M = fsevent::kItemModified;
constexpr uint32_t R = fsevent::kItemRenamed;
constexpr uint32_t X = fsevent::kItemRemoved;

AutoScanIncome inc(const std::string &name, const std::string &path, const std::string &fsPath = std::string()) {
    AutoScanIncome i;
    i.name = name;
    i.path = path;
    i.fsPath = fsPath.empty() ? path : fsPath;
    normalizePath(i.fsPath, i.fsKey);
    return i;
}

// 0 local, 1 share, 2 p2p (inside local), 3 tmp (configured under /var,
// reported under /private/var), 4 nfd (an NFC name on a share).
std::vector<AutoScanIncome> incomes() {
    return {
        inc("local", "/Users/x/Music/fixture-income"),
        inc("share", "/Volumes/music/fixture-income"),
        inc("p2p", "/Users/x/Music/fixture-income/p2p"),
        inc("tmp", "/var/folders/x/intake", "/private/var/folders/x/intake"),
        inc("nfd", "/Volumes/music/P\xC5\x99\xC3\xADjem"),  // "Příjem", NFC
    };
}

AutoScanEvent ev(const char *path, uint32_t flags, WatchEventId id = 1000) {
    AutoScanEvent e;
    e.path = path;
    e.flags = flags;
    e.id = id;
    return e;
}

AutoScanHits hitsOf(std::vector<AutoScanEvent> events, const std::vector<AutoScanMute> &mutes = {}) {
    return autoScanHits(events, incomes(), mutes);
}

std::vector<size_t> idx(std::initializer_list<size_t> items) {
    return std::vector<size_t>(items);
}

bool nothing(const AutoScanHits &h) {
    return h.incomes.empty() && h.paths.empty();
}

// --- filter ---

void testCounts() {
    g_context = "counts";
    AutoScanHits h = hitsOf({ev("/Users/x/Music/fixture-income/Album/01.flac", C | M | F)});
    CHECK(h.incomes == idx({0}), "a file created and written counts for its income");
    CHECK(h.paths.size() == 1 && !h.paths[0].open && h.paths[0].income == 0 &&
              h.paths[0].path == "/Users/x/Music/fixture-income/Album/01.flac",
          "closed at once (written in the same event)");

    h = hitsOf({ev("/Users/x/Music/fixture-income/Album/02.flac", C | F)});
    CHECK(h.incomes == idx({0}) && h.paths.size() == 1 && h.paths[0].open, "created only: counts, and open");

    h = hitsOf({ev("/Users/x/Music/fixture-income/Album/02.flac", M | F)});
    CHECK(h.incomes == idx({0}) && h.paths.size() == 1 && !h.paths[0].open, "modified (the writer closed it): counts, closed");

    h = hitsOf({ev("/Users/x/Music/fixture-income/Album/03.flac", R | F)});
    CHECK(h.incomes == idx({0}) && h.paths.size() == 1 && !h.paths[0].open, "renamed in: counts, closes, never opens");

    h = hitsOf({ev("/Users/x/Music/fixture-income/Album", C | D)});
    CHECK(h.incomes == idx({0}) && h.paths.empty(), "a folder created counts, and never opens");
    h = hitsOf({ev("/Users/x/Music/fixture-income/Album", R | D)});
    CHECK(h.incomes == idx({0}) && h.paths.empty(), "a folder moved in counts");

    h = hitsOf({ev("/Users/x/Music/fixture-income/Album/04.flac", X | F)});
    CHECK(h.incomes.empty(), "removal only: does not count");
    CHECK(h.paths.size() == 1 && !h.paths[0].open, "but closes the path");
    h = hitsOf({ev("/Users/x/Music/fixture-income/Album", X | D)});
    CHECK(nothing(h), "a folder removed: nothing");

    // A file created and removed again within the latency (sticky flags):
    // Created counts, Removed closes.
    h = hitsOf({ev("/Users/x/Music/fixture-income/Album/05.flac", C | X | F)});
    CHECK(h.incomes == idx({0}) && h.paths.size() == 1 && !h.paths[0].open, "created and removed: counts, closed");

    h = hitsOf({ev("/Users/x/Music/fixture-income/Album/01.flac", kFSEventStreamEventFlagItemXattrMod | F),
                ev("/Users/x/Music/fixture-income/Album/01.flac", kFSEventStreamEventFlagItemInodeMetaMod | F),
                ev("/Users/x/Music/fixture-income/Album/01.flac", kFSEventStreamEventFlagItemFinderInfoMod | F),
                ev("/Users/x/Music/fixture-income/Album/01.flac", kFSEventStreamEventFlagItemChangeOwner | F)});
    CHECK(nothing(h), "metadata-only events (xattr, inode, Finder info, owner): nothing");

    h = hitsOf({ev("/Users/x/Music/fixture-income/01.flac", C | M | F)});
    CHECK(h.incomes == idx({0}), "a top-level file counts");
    h = hitsOf({ev("/Users/x/Music/fixture-income", C | D)});
    CHECK(h.incomes == idx({0}), "the income folder itself counts");
}

void testIgnored() {
    g_context = "ignored";
    const char *names[] = {
        ".intake.json", ".intake.itk_0000000b.json", ".intake-hint.json", ".INTAKE.JSON", ".Intake.ITK_0000000B.Json",
        ".intake-tmp-x.json", ".DS_Store", ".ds_store", "._01.flac", ".dat.nosync1a2b.XyZ", "Thumbs.db",
        "desktop.ini", "DESKTOP.INI", "@eaDir", ".AppleDouble", "__MACOSX", "01.flac.part", "01.flac.PART",
        "x.tmp", "x.zip.download", "x.crdownload", "x.incomplete", "a.zip.unpacked", "a.zip.unpacked.partial",
        "A.RAR.UNPACKED", ".intake-gc-itk_0000000b",
    };
    int ignored = 0, allNothing = 0, under = 0;
    for (const char *name : names) {
        if (autoScanIgnoredName(name)) ignored++;
        const std::string file = std::string("/Users/x/Music/fixture-income/Album/") + name;
        if (nothing(hitsOf({ev(file.c_str(), C | F), ev(file.c_str(), M | F), ev(file.c_str(), R | D)}))) allNothing++;
        // Everything under an ignored name is ignored too.
        const std::string inside = file + "/Disc 1/01.flac";
        if (nothing(hitsOf({ev(inside.c_str(), C | M | F), ev(inside.c_str(), C | F)}))) under++;
    }
    const int n = (int)(sizeof names / sizeof names[0]);
    CHECK_EQ(ignored, n, "every ignored name is recognised");
    CHECK_EQ(allNothing, n, "an ignored name never counts, opens or closes");
    CHECK_EQ(under, n, "nor does anything under it");

    const char *kept[] = {"01 - Track.flac", "cover.jpg", "intake.json", ".intake", ".intakejson", "unpacked",
                          "x.unpacked.zip", "x.partial", "@eaDir2", "_MACOSX", "Album.download.flac",
                          ".intake-gc", "tmp", "part"};
    int notIgnored = 0;
    for (const char *name : kept) {
        if (!autoScanIgnoredName(name)) notIgnored++;
    }
    CHECK_EQ(notIgnored, (int)(sizeof kept / sizeof kept[0]), "similar names are not ignored");
    CHECK(!autoScanIgnoredName(""), "an empty component is not ignored");

    // Only components below the income folder are looked at: an income
    // whose own path has an ignored-looking name still scans.
    std::vector<AutoScanIncome> odd = {inc("odd", "/Users/x/Downloads/intake.tmp")};
    std::vector<AutoScanEvent> events = {ev("/Users/x/Downloads/intake.tmp/Album/01.flac", C | M | F)};
    CHECK(autoScanHits(events, odd, {}).incomes == idx({0}), "the income folder's own name is not filtered");

    // A sidecar write by the CLI next to new audio: only the audio counts.
    AutoScanHits h = hitsOf({ev("/Users/x/Music/fixture-income/Album/.intake.json", C | M | F),
                             ev("/Users/x/Music/fixture-income/Album/.intake.json", C | F)});
    CHECK(nothing(h), "a sidecar write alone schedules nothing");
}

void testMatch() {
    g_context = "match";
    AutoScanHits h = hitsOf({ev("/Users/x/Music/fixture-income/p2p/Album/01.flac", C | M | F)});
    CHECK(h.incomes == idx({2}) && h.paths.size() == 1 && h.paths[0].income == 2,
          "the longest income holding the path wins (p2p inside local)");
    h = hitsOf({ev("/Users/x/Music/fixture-income/p2pX/01.flac", C | M | F)});
    CHECK(h.incomes == idx({0}), "no match without a '/' boundary: the outer income");
    h = hitsOf({ev("/users/X/music/FIXTURE-INCOME/Album/01.flac", C | M | F)});
    CHECK(h.incomes == idx({0}), "ASCII case ignored (FSEvents reports the case on disk)");
    h = hitsOf({ev("/private/var/folders/x/intake/Album/01.flac", C | M | F)});
    CHECK(h.incomes == idx({3}), "the physical spelling (/private/var) matches an income configured under /var");
    // "Příjem" decomposed (NFD), as SMB reports it.
    h = hitsOf({ev("/Volumes/music/Pr\xCC\x8Ci\xCC\x81jem/Album/01.flac", C | M | F)});
    CHECK(h.incomes == idx({4}), "an NFD event path matches an NFC income (IntakePath keys)");
    h = hitsOf({ev("/Volumes/music/fixture-income/01.flac", C | M | F)});
    CHECK(h.incomes == idx({1}), "a share income");
    h = hitsOf({ev("/Users/x/Music/other/01.flac", C | M | F), ev("/Users/x/Music/fixture-incomeX/01.flac", C | M | F),
                ev("/Users/x/Music", C | D), ev("relative/01.flac", C | M | F), ev("", C | M | F)});
    CHECK(nothing(h), "outside every income, a sibling with the same prefix, a parent, a relative or empty path: nothing");
    CHECK(nothing(autoScanHits({ev("/Users/x/Music/fixture-income/01.flac", C | M | F)}, {}, {})), "no incomes: nothing");
}

void testRescan() {
    g_context = "rescan";
    AutoScanHits h = hitsOf({ev("/Users/x/Music/fixture-income/Album", fsevent::kMustScanSubDirs)});
    CHECK(h.incomes == idx({0}) && h.paths.empty(), "MustScanSubDirs under an income counts for it");
    h = hitsOf({ev("/Users/x/Music/fixture-income", fsevent::kMustScanSubDirs)});
    CHECK(h.incomes == idx({0, 2}), "on the income folder: it and the income inside it");
    h = hitsOf({ev("/Users/x/Music", fsevent::kMustScanSubDirs)});
    CHECK(h.incomes == idx({0, 2}), "MustScanSubDirs on an ancestor counts for every income under it");
    h = hitsOf({ev("/Users/x", fsevent::kKernelDropped)});
    CHECK(h.incomes == idx({0, 2}), "KernelDropped on an ancestor");
    h = hitsOf({ev("/Volumes/music", fsevent::kUserDropped)});
    CHECK(h.incomes == idx({1, 4}), "UserDropped on the share's root: both share incomes");
    h = hitsOf({ev("/", fsevent::kKernelDropped)});
    CHECK(h.incomes == idx({0, 1, 2, 3, 4}), "dropped at /: every income");
    h = hitsOf({ev("", fsevent::kUserDropped | fsevent::kKernelDropped)});
    CHECK(h.incomes == idx({0, 1, 2, 3, 4}), "dropped with no path: every income");
    h = hitsOf({ev("/Users/x/Music/fixture-income/p2p/Album", fsevent::kKernelDropped)});
    CHECK(h.incomes == idx({2}), "dropped under an income counts for that income");
    h = hitsOf({ev("/Users/x/Music/fixture-income/Album/a.zip.unpacked.partial", fsevent::kMustScanSubDirs)});
    CHECK(nothing(h), "a rescan inside an ignored folder: nothing");
    h = hitsOf({ev("/Users/y", fsevent::kMustScanSubDirs)});
    CHECK(nothing(h), "a rescan elsewhere: nothing");

    h = hitsOf({ev("/Volumes/music", fsevent::kMount), ev("/Volumes/music", fsevent::kUnmount),
                ev("/Volumes/music", fsevent::kMount | fsevent::kMustScanSubDirs),
                ev("/Volumes/music/fixture-income", fsevent::kUnmount | fsevent::kMustScanSubDirs),
                ev("/Users/x/Music/fixture-income/01.flac", fsevent::kMount | C | M | F)});
    CHECK(nothing(h), "Mount and Unmount never count, whatever else the event carries");
    h = hitsOf({ev("/Users/x/Music/fixture-income", fsevent::kHistoryDone, 0),
                ev("/Users/x/Music/fixture-income", fsevent::kEventIdsWrapped)});
    CHECK(nothing(h), "HistoryDone and EventIdsWrapped are markers");
}

void testMutes() {
    g_context = "mutes";
    AutoScanMute gc;
    gc.id = 7;
    gc.paths = {"/Users/x/Music/fixture-income/Placed Album"};
    gc.startId = 100;
    gc.endId = 200;
    const std::vector<AutoScanMute> mutes = {gc};
    auto counted = [&](const char *path, WatchEventId id) {
        return !hitsOf({ev(path, R | F, id)}, mutes).incomes.empty();
    };
    const char *inside = "/Users/x/Music/fixture-income/Placed Album/01.flac";
    CHECK(!counted(inside, 150), "inside the mute, between its ids: muted");
    CHECK(!counted(inside, 200), "at the end id: muted");
    CHECK(counted(inside, 201), "after the end id: counts");
    CHECK(counted(inside, 100), "at the start id (before gc ran): counts");
    CHECK(counted(inside, 99), "before the start id: counts");
    CHECK(!counted("/Users/x/Music/fixture-income/Placed Album", 150), "the muted folder itself: muted");
    CHECK(!counted("/users/x/music/fixture-income/placed album/Disc 1/01.flac", 150), "ASCII case ignored, deep inside");
    CHECK(counted("/Users/x/Music/fixture-income/Placed Album 2/01.flac", 150), "a sibling with the same prefix: counts");
    CHECK(counted("/Users/x/Music/fixture-income/Other/01.flac", 150), "elsewhere in the income: counts");
    CHECK(hitsOf({ev(inside, R | F, 150)}, mutes).paths.empty(), "a muted event neither opens nor closes");
    CHECK(hitsOf({ev("/Users/x/Music/fixture-income/Placed Album", fsevent::kMustScanSubDirs, 150)}, mutes).incomes.empty(),
          "a rescan inside the mute, between its ids: muted");

    AutoScanMute running = gc;
    running.endId = kWatchSinceNow;
    CHECK(hitsOf({ev(inside, R | F, 900000)}, {running}).incomes.empty(), "end not known yet: every later id muted");
    CHECK(hitsOf({ev(inside, R | F, 900000)}, {running}).passedMutes.empty(), "and the mute never passes");

    CHECK(hitsOf({ev(inside, R | F, 200)}, mutes).passedMutes.empty(), "an event at the end id: not passed yet");
    AutoScanHits h = hitsOf({ev(inside, R | F, 150), ev("/Users/y/elsewhere", C | F, 201)}, mutes);
    CHECK(h.incomes.empty() && h.passedMutes == std::vector<uint64_t>({7}),
          "any later id in the callback passes the mute, even outside every income");
    CHECK(!h.empty(), "a passed mute alone is worth a post");
    std::vector<AutoScanEvent> late = {ev("/Users/y/elsewhere", C | F, 300)};
    CHECK(autoScanHits(late, {}, mutes).passedMutes == std::vector<uint64_t>({7}), "also with no incomes");
    CHECK(hitsOf({ev("/Users/x/Music/fixture-income", fsevent::kHistoryDone, 500)}, mutes).passedMutes.empty(),
          "a marker's id passes nothing");
}

void testOpenClose() {
    g_context = "open-close";
    const char *a = "/Users/x/Music/fixture-income/Album/01.flac";
    const char *b = "/Users/x/Music/fixture-income/Album/02.flac";
    AutoScanHits h = hitsOf({ev(a, C | F), ev(b, C | F), ev(a, C | M | F)});
    CHECK(h.paths.size() == 2 && h.paths[0].path == a && !h.paths[0].open && h.paths[1].path == b && h.paths[1].open,
          "one entry per path, first-seen order, the last event decides (a opened then closed, b open)");
    h = hitsOf({ev(a, X | F), ev(a, C | F)});
    CHECK(h.paths.size() == 1 && h.paths[0].open, "removed and created again: open");
    h = hitsOf({ev("/Users/x/Music/fixture-income/Album/01.flac.part", C | F)});
    CHECK(h.paths.empty(), "an ignored partial download is not tracked");
    h = hitsOf({ev("/Users/x/Music/other/01.flac", C | F)});
    CHECK(h.paths.empty(), "a file outside every income is not tracked");
    h = hitsOf({ev("/Users/x/Music/fixture-income/Album", C | F | D)});
    CHECK(h.paths.empty(), "a path reported as both file and folder never opens");
}

void testDedupe() {
    g_context = "dedupe";
    std::vector<std::string> paths;
    for (int i = 0; i < 1000; i++) paths.push_back("/Users/x/Music/fixture-income/Album/" + std::to_string(i) + ".flac");
    std::vector<AutoScanEvent> events;
    for (const std::string &p : paths) events.push_back(ev(p.c_str(), C | M | F));
    events.push_back(ev("/Volumes/music/fixture-income/x.flac", C | M | F));
    events.push_back(ev("/Users/x/Music/fixture-income/p2p/x.flac", C | M | F));
    AutoScanHits h = autoScanHits(events, incomes(), {});
    CHECK(h.incomes == idx({0, 1, 2}), "a bulk copy reports each income once, ascending");
    CHECK_EQ(h.paths.size(), 1002, "one path entry per file");
}

void testIncomeEntries() {
    g_context = "income-entries";
    const MountEntry root{"/", "/dev/disk3s1s1", "apfs", true};
    LinkReader reader = [](const std::string &path, std::string &target) {
        if (path == "/var") {
            target = "private/var";
            return LinkCheck::Link;
        }
        return LinkCheck::NotLink;
    };
    WatchSet set = WatchSet::build({"/Users/x/Music/fixture-income", "/var/folders/x/intake"}, {root}, reader);
    std::vector<IncomeFolder> folders = {
        {"local", "/Users/x/Music/fixture-income/", true},
        {"tmp", "/var/folders/x/intake", true},
        {"", "/Users/x/Music/unnamed", true},
        {"rel", "relative/intake", true},
        {"local", "/Users/x/Music/other", true},
        {"unwatched", "/Users/x/Music/unwatched", false},
    };
    std::vector<AutoScanIncome> got = autoScanIncomes(folders, set);
    CHECK_EQ(got.size(), 3, "unnamed, relative and repeated names are left out");
    if (got.size() == 3) {
        CHECK(got[0].name == "local" && got[0].path == "/Users/x/Music/fixture-income/" &&
                  got[0].fsPath == "/Users/x/Music/fixture-income" && got[0].fsKey == "/Users/x/Music/fixture-income",
              "the path as the CLI spelled it, the watch set's spelling for events");
        CHECK(got[1].name == "tmp" && got[1].path == "/var/folders/x/intake" &&
                  got[1].fsPath == "/private/var/folders/x/intake" && got[1].fsKey == "/private/var/folders/x/intake",
              "a resolved folder: the physical spelling");
        CHECK(got[2].name == "unwatched" && got[2].fsPath == "/Users/x/Music/unwatched" &&
                  got[2].fsKey == "/Users/x/Music/unwatched",
              "a folder the set does not hold keeps its clean spelling");
    }
}

// --- presence ---

const MountEntry kRoot{"/", "/dev/disk3s1s1", "apfs", true};
const MountEntry kData{"/System/Volumes/Data", "/dev/disk3s5", "apfs", true};
const MountEntry kShare{"/Volumes/music", "//user@host-lan/music", "smbfs", false};

// A fake filesystem (as IntakeWatchSetTests): `links` are symlinks,
// `missing` paths do not exist (nor anything under them); every lstat is
// recorded.
struct RecordingReader {
    std::map<std::string, std::string> links;
    std::set<std::string> missing;
    std::vector<std::string> calls;
    LinkReader fn() {
        return [this](const std::string &path, std::string &target) {
            calls.push_back(path);
            for (const std::string &m : missing) {
                if (path == m || path.rfind(m + "/", 0) == 0) return LinkCheck::Missing;
            }
            auto it = links.find(path);
            if (it == links.end()) return LinkCheck::NotLink;
            target = it->second;
            return LinkCheck::Link;
        };
    }
    bool touchedUnder(const std::string &base) const {
        for (const std::string &c : calls) {
            if (c == base || c.rfind(base + "/", 0) == 0) return true;
        }
        return false;
    }
};

void testPresence() {
    g_context = "presence";
    const std::vector<MountEntry> mounted = {kRoot, kData, kShare};
    const std::vector<MountEntry> unmounted = {kRoot, kData};

    RecordingReader fs;
    fs.links["/tmp"] = "private/tmp";
    fs.links["/Users/x/NAS"] = "/Volumes/music";
    fs.links["/Users/x/loop"] = "/Users/x/loop";
    fs.missing = {"/Users/x/Music/gone"};

    IncomeCheck c = classifyIncome("/Users/x/Music/fixture-income", mounted, fs.fn());
    CHECK(c.presence == IncomePresence::Local && c.resolved == "/Users/x/Music/fixture-income", "a local folder");
    c = classifyIncome("/tmp/intake/", mounted, fs.fn());
    CHECK(c.presence == IncomePresence::Local && c.resolved == "/private/tmp/intake", "through a local symlink, cleaned");

    fs.calls.clear();
    c = classifyIncome("/Volumes/music/fixture-income", mounted, fs.fn());
    CHECK(c.presence == IncomePresence::Network && c.resolved == "/Volumes/music/fixture-income", "on a mounted share");
    CHECK(!fs.touchedUnder("/Volumes/music"), "nothing at or under the share was examined");
    CHECK(fs.touchedUnder("/Volumes"), "the local parent was");

    fs.calls.clear();
    c = classifyIncome("/Users/x/NAS/fixture-income", mounted, fs.fn());
    CHECK(c.presence == IncomePresence::Network && c.resolved == "/Volumes/music/fixture-income",
          "a local symlink into the share: on the share");
    CHECK(!fs.touchedUnder("/Volumes/music"), "the link was read, the share never examined");

    // Unmounted: /Volumes/music is an absent folder on the local disk.
    fs.missing.insert("/Volumes/music");
    c = classifyIncome("/Volumes/music/fixture-income", unmounted, fs.fn());
    CHECK(c.presence == IncomePresence::Missing, "an unmounted share's mount point: missing");
    c = classifyIncome("/Users/x/NAS/fixture-income", unmounted, fs.fn());
    CHECK(c.presence == IncomePresence::Missing, "the link to an unmounted share: missing");
    fs.missing.erase("/Volumes/music");

    c = classifyIncome("/Users/x/Music/gone", mounted, fs.fn());
    CHECK(c.presence == IncomePresence::Missing, "an absent folder: missing");
    c = classifyIncome("/Users/x/loop/intake", mounted, fs.fn());
    CHECK(c.presence == IncomePresence::Missing, "a symlink loop: missing");

    fs.calls.clear();
    c = classifyIncome("/Users/x/Music/fixture-income", {}, fs.fn());
    CHECK(c.presence == IncomePresence::Missing && fs.calls.empty(), "no mount table: missing, nothing examined");
    c = classifyIncome("music/fixture-income", mounted, fs.fn());
    CHECK(c.presence == IncomePresence::Missing && fs.calls.empty(), "not absolute: missing, nothing examined");
    c = classifyIncome("/Users/x/Music/fixture-income", mounted, LinkReader());
    CHECK(c.presence == IncomePresence::Missing, "no reader: missing");

    CHECK(std::string(incomePresenceText(IncomePresence::Local)) == "local" &&
              std::string(incomePresenceText(IncomePresence::Network)) == "on a network volume" &&
              std::string(incomePresenceText(IncomePresence::Missing)) == "missing",
          "texts for log lines");

    // A real folder (NSTemporaryDirectory is under /var -> /private/var)
    // through posixLinkReader, against realpath(3).
    std::string base = NSTemporaryDirectory().UTF8String;
    if (!base.empty() && base.back() == '/') base.pop_back();
    char real[PATH_MAX];
    if (realpath(base.c_str(), real) != nullptr) {
        c = classifyIncome(base, {kRoot}, posixLinkReader);
        CHECK(c.presence == IncomePresence::Local && c.resolved == real, "a real temp folder: local, resolved like realpath");
    } else {
        CHECK(false, "realpath of the temp folder");
    }
}

// --- scheduler ---

const Sched::TimePoint T0 = Sched::TimePoint() + std::chrono::hours(1);

Sched::TimePoint at(double secondsFromT0) {
    return T0 + std::chrono::duration_cast<Sched::Clock::duration>(std::chrono::duration<double>(secondsFromT0));
}

AutoScanHits hit(std::initializer_list<size_t> which) {
    AutoScanHits h;
    h.incomes = which;
    return h;
}

AutoScanHits openHit(size_t which, const std::string &path, bool open) {
    AutoScanHits h;
    h.incomes = {which};
    h.paths.push_back(AutoScanPathChange{which, path, open});
    return h;
}

Sched fresh() {
    Sched s;
    s.setIncomes(incomes());
    return s;
}

void testQuietPeriod() {
    g_context = "quiet";
    const auto L = incomes();
    Sched s = fresh();
    CHECK(s.state("local") == Sched::State::Idle && !s.next(at(0), true), "starts idle, nothing to do");
    s.noteHits(hit({0}), L, at(0));
    CHECK(s.state("local") == Sched::State::Pending, "an event: pending");
    CHECK(!s.next(at(59.999), true), "not before 60 s of quiet");
    std::optional<AutoScanJob> job = s.next(at(60), true);
    CHECK(job && job->income.name == "local" && job->income.path == "/Users/x/Music/fixture-income" && !job->startup &&
              job->token != 0,
          "due exactly at 60 s");
    CHECK(s.state("local") == Sched::State::Checking && s.busy(), "checking");

    Sched p = fresh();
    p.noteHits(hit({0}), L, at(0));
    p.noteHits(hit({0}), L, at(30));
    CHECK(!p.next(at(60), true) && !p.next(at(89.9), true), "a later event postpones it");
    p.noteHits(hit({0}), L, at(80));
    CHECK(!p.next(at(139), true), "and again");
    CHECK(p.next(at(140), true).has_value(), "60 s after the last event");
}

void testOpenFiles() {
    g_context = "open-files";
    const auto L = incomes();
    const std::string a = "/Users/x/Music/fixture-income/Album/big.zip";
    Sched s = fresh();
    s.noteHits(openHit(0, a, true), L, at(0));
    CHECK(s.openPathCount("local") == 1, "the open file is tracked");
    CHECK(!s.next(at(60), true), "an open file holds the income past the quiet period");
    CHECK(s.nextWakeup(at(60), true) == at(1800), "the wakeup is the 30-minute cap");
    s.noteHits(openHit(0, a, true), L, at(600));  // created again: keeps its first time
    CHECK(!s.next(at(1799), true), "still held before the cap (counted from the first open)");
    CHECK(s.next(at(1800), true).has_value(), "the cap releases it at 30 min");

    Sched c = fresh();
    c.noteHits(openHit(0, a, true), L, at(0));
    c.noteHits(openHit(0, a, false), L, at(100));  // the writer closed it
    CHECK(c.openPathCount("local") == 0, "closed");
    CHECK(!c.next(at(159), true) && c.next(at(160), true).has_value(), "then the normal quiet period");

    // An open file in another income does not hold this one.
    Sched o = fresh();
    o.noteHits(openHit(1, "/Volumes/music/fixture-income/x.flac", true), L, at(0));
    o.noteHits(hit({0}), L, at(0));
    std::optional<AutoScanJob> job = o.next(at(60), true);
    CHECK(job && job->income.name == "local", "open files are per income");
}

void testOneAtATime() {
    g_context = "one-at-a-time";
    const auto L = incomes();
    Sched s = fresh();
    s.noteHits(hit({1}), L, at(0));
    s.noteHits(hit({0}), L, at(10));
    std::optional<AutoScanJob> a = s.next(at(100), true);
    CHECK(a && a->income.name == "share", "oldest first: the income pending longest");
    CHECK(!s.next(at(100), true), "nothing else while one is checking");
    CHECK(s.started(a->token) && s.state("share") == Sched::State::Running, "started: running");
    CHECK(!s.next(at(200), true), "nothing else while one is running");
    CHECK(!s.nextWakeup(at(200), true), "no wakeup while a job is in flight: its exit reschedules");
    CHECK(s.exit(a->token, AutoScanExit::Finished, at(300)) == AutoScanResult::Idle, "finished: idle");
    std::optional<AutoScanJob> b = s.next(at(300), true);
    CHECK(b && b->income.name == "local" && b->token != a->token, "then the next one, new token");
}

void testLaneBusy() {
    g_context = "lane-busy";
    const auto L = incomes();
    Sched s = fresh();
    s.noteHits(hit({0}), L, at(0));
    CHECK(!s.next(at(60), false), "lane busy (or the leftover-run scan not done): nothing starts");
    CHECK(s.state("local") == Sched::State::Pending, "still pending");
    CHECK(s.nextWakeup(at(60), false) == at(65), "retried every 5 s");
    CHECK(s.nextWakeup(at(30), false) == at(60), "not due yet: woken when due");
    CHECK(s.next(at(65), true).has_value(), "starts once the lane is free");
}

void testCoalescing() {
    g_context = "coalescing";
    const auto L = incomes();
    Sched s = fresh();
    for (int i = 0; i < 100; i++) s.noteHits(hit({0}), L, at(i * 0.5));
    std::optional<AutoScanJob> job = s.next(at(49.5 + 60), true);
    CHECK(job.has_value(), "a hundred events: one scan");
    s.started(job->token);
    CHECK(s.exit(job->token, AutoScanExit::Finished, at(200)) == AutoScanResult::Idle, "and nothing after it");
    CHECK(!s.next(at(10000), true) && !s.nextWakeup(at(10000), true), "nothing pending");
}

void testEventsDuringRun() {
    g_context = "events-during-run";
    const auto L = incomes();
    Sched s = fresh();
    s.noteHits(hit({0}), L, at(0));
    std::optional<AutoScanJob> job = s.next(at(60), true);
    s.started(job->token);
    s.noteHits(hit({0}), L, at(70));
    s.noteHits(hit({0}), L, at(80));
    s.noteHits(hit({0}), L, at(90));
    CHECK(s.state("local") == Sched::State::Running, "events during the run keep it running");
    CHECK(s.exit(job->token, AutoScanExit::Finished, at(100)) == AutoScanResult::Pending, "finished: pending again");
    CHECK(!s.next(at(149), true), "60 s after the latest event during the run");
    std::optional<AutoScanJob> again = s.next(at(150), true);
    CHECK(again && !again->startup, "exactly one more run");
    s.started(again->token);
    CHECK(s.exit(again->token, AutoScanExit::Finished, at(200)) == AutoScanResult::Idle, "then idle");
    CHECK(!s.nextWakeup(at(200), true), "nothing left");

    // Events while Checking count the same way.
    Sched c = fresh();
    c.noteHits(hit({0}), L, at(0));
    job = c.next(at(60), true);
    c.noteHits(hit({0}), L, at(61));
    CHECK(c.exit(job->token, AutoScanExit::Missing, at(62)) == AutoScanResult::Pending,
          "events during the check: pending again even when the folder looked missing");
}

void testStartup() {
    g_context = "startup";
    const auto L = incomes();
    Sched s = fresh();
    s.noteStartup({"local", "unknown"}, at(0));
    CHECK(s.state("local") == Sched::State::Pending && s.state("share") == Sched::State::Idle,
          "the listed local income is pending; unknown names are ignored");
    CHECK(s.nextWakeup(at(0), true) == at(0), "due at once");
    std::optional<AutoScanJob> job = s.next(at(0), true);
    CHECK(job && job->income.name == "local" && job->startup, "a startup scan, at once");

    Sched e = fresh();
    e.noteStartup({"local"}, at(0));
    e.noteHits(hit({0}), L, at(1));
    CHECK(!e.next(at(2), true), "an event after startup: it waits for its quiet period");
    job = e.next(at(61), true);
    CHECK(job && !job->startup, "then a new-files scan");

    Sched p = fresh();
    p.noteHits(hit({0}), L, at(0));
    p.noteStartup({"local"}, at(10));
    CHECK(!p.next(at(10), true) && p.next(at(60), true).has_value(), "pending already: its own quiet period runs");

    // The open-file hold applies to a startup entry too (an open path
    // recorded without a count, which the filter never sends, keeps the
    // entry a startup one here).
    Sched h = fresh();
    h.noteStartup({"local"}, at(0));
    AutoScanHits openOnly;
    openOnly.paths.push_back(AutoScanPathChange{0, "/Users/x/Music/fixture-income/b.flac", true});
    h.noteHits(openOnly, L, at(0));
    CHECK(!h.next(at(1), true), "a startup entry with an open file waits");
    job = h.next(at(1800), true);
    CHECK(job && job->startup, "until the cap, still a startup scan");
}

void testExits() {
    g_context = "exits";
    const auto L = incomes();
    auto checking = [&](Sched &s) {
        s.noteHits(hit({0}), L, at(0));
        return s.next(at(60), true);
    };

    Sched m = fresh();
    std::optional<AutoScanJob> job = checking(m);
    CHECK(m.exit(job->token, AutoScanExit::Missing, at(61)) == AutoScanResult::Idle && m.state("local") == Sched::State::Idle,
          "presence missing: idle");
    CHECK(!m.busy() && !m.next(at(1000), true), "and not retried");

    Sched l = fresh();
    job = checking(l);
    CHECK(l.exit(job->token, AutoScanExit::LaneTaken, at(61)) == AutoScanResult::Pending &&
              l.state("local") == Sched::State::Pending,
          "lane taken after the check: pending");
    CHECK(l.nextWakeup(at(61), false) == at(66), "retried 5 s later while the lane is busy");
    std::optional<AutoScanJob> retry = l.next(at(61), true);
    CHECK(retry && retry->token != job->token, "and again at once when it is free");

    Sched ls = fresh();
    ls.noteStartup({"local"}, at(0));
    job = ls.next(at(0), true);
    ls.exit(job->token, AutoScanExit::LaneTaken, at(1));
    retry = ls.next(at(1), true);
    CHECK(retry && retry->startup, "a startup scan stays a startup scan when retried");

    Sched r = fresh();
    job = checking(r);
    CHECK(r.exit(job->token, AutoScanExit::Refused, at(61)) == AutoScanResult::Idle, "refused (or E_NO_CLI): idle");
    CHECK(!r.next(at(1000), true), "not retried");
    Sched rr = fresh();
    job = checking(rr);
    rr.started(job->token);
    CHECK(rr.exit(job->token, AutoScanExit::Refused, at(61)) == AutoScanResult::Idle, "E_NO_CLI after the start: idle");

    Sched f = fresh();
    job = checking(f);
    CHECK(f.started(job->token), "started");
    CHECK(!f.started(job->token), "a second start is refused");
    CHECK(f.exit(job->token, AutoScanExit::Finished, at(70)) == AutoScanResult::Idle, "finished: idle");
    CHECK(f.exit(job->token, AutoScanExit::Finished, at(71)) == AutoScanResult::Stale, "a second exit is stale");
    CHECK(f.exit(0, AutoScanExit::Finished, at(71)) == AutoScanResult::Stale, "token 0 is stale");
    CHECK(!f.started(job->token) && !f.wanted(job->token), "an ended job is neither wanted nor startable");

    Sched k = fresh();
    job = checking(k);
    k.started(job->token);
    k.noteHits(hit({0}), L, at(100));
    CHECK(k.exit(job->token, AutoScanExit::CapKilled, at(960)) == AutoScanResult::Disabled, "killed at the cap: disabled");
    CHECK(k.disabled("local") && k.state("local") == Sched::State::Idle, "idle and disabled, events during it dropped");
    k.noteHits(hit({0}), L, at(1000));
    k.noteStartup({"local"}, at(1000));
    CHECK(k.state("local") == Sched::State::Idle && !k.next(at(5000), true) && !k.nextWakeup(at(5000), true),
          "no more scans of it this session");
    k.noteHits(hit({1}), L, at(1000));
    CHECK(k.next(at(1060), true).has_value(), "other incomes still scan");
    k.setIncomes(incomes());
    CHECK(k.disabled("local"), "a reload keeps it disabled");

    Sched w = fresh();
    job = checking(w);
    CHECK(w.wanted(job->token) && !w.wanted(job->token + 1), "wanted: the job in flight only");
    CHECK(w.exit(job->token + 1, AutoScanExit::Finished, at(61)) == AutoScanResult::Stale &&
              w.state("local") == Sched::State::Checking,
          "a wrong token changes nothing");
}

void testTurnedOff() {
    g_context = "turned-off";
    const auto L = incomes();
    Sched s = fresh();
    s.noteHits(hit({0}), L, at(0));
    s.noteHits(openHit(1, "/Volumes/music/fixture-income/x.flac", true), L, at(0));
    s.setEnabled(false);
    CHECK(!s.enabled() && s.state("local") == Sched::State::Idle && s.state("share") == Sched::State::Idle,
          "off: pending incomes are dropped");
    CHECK(s.openPathCount("share") == 0, "and open files forgotten");
    s.noteHits(hit({0}), L, at(10));
    s.noteStartup({"local"}, at(10));
    CHECK(s.state("local") == Sched::State::Idle && !s.next(at(100), true) && !s.nextWakeup(at(100), true),
          "hits and startup are ignored while off");
    s.setEnabled(true);
    CHECK(s.state("local") == Sched::State::Idle && !s.next(at(200), true), "on again: no immediate scan");
    s.noteHits(hit({0}), L, at(200));
    CHECK(s.next(at(260), true).has_value(), "the next event scans");

    // Off while Checking: the checked job is not started.
    Sched c = fresh();
    c.noteHits(hit({0}), L, at(0));
    std::optional<AutoScanJob> job = c.next(at(60), true);
    c.setEnabled(false);
    CHECK(!c.wanted(job->token) && !c.started(job->token), "off while checking: not wanted, not started");
    CHECK(c.exit(job->token, AutoScanExit::Refused, at(61)) == AutoScanResult::Dropped && c.state("local") == Sched::State::Idle,
          "its exit drops it");

    // Off while Running: it finishes and is dropped; events before the
    // switch do not count, events after it was turned on again do.
    Sched r = fresh();
    r.noteHits(hit({0}), L, at(0));
    job = r.next(at(60), true);
    r.started(job->token);
    r.noteHits(hit({0}), L, at(70));
    r.setEnabled(false);
    CHECK(r.state("local") == Sched::State::Running && r.busy(), "off while running: it runs on");
    CHECK(!r.next(at(80), true), "nothing else starts meanwhile");
    CHECK(r.exit(job->token, AutoScanExit::Finished, at(90)) == AutoScanResult::Dropped &&
              r.state("local") == Sched::State::Idle,
          "dropped at its exit, the events before the switch with it");

    Sched r2 = fresh();
    r2.noteHits(hit({0}), L, at(0));
    job = r2.next(at(60), true);
    r2.started(job->token);
    r2.setEnabled(false);
    r2.setEnabled(true);
    CHECK(!r2.wanted(job->token), "off and on again: the job stays dropped");
    r2.noteHits(hit({0}), L, at(70));
    CHECK(r2.exit(job->token, AutoScanExit::Finished, at(90)) == AutoScanResult::Dropped &&
              r2.state("local") == Sched::State::Pending,
          "events after it was turned on again still get their scan");
    CHECK(r2.next(at(130), true).has_value(), "60 s after them");
}

void testIncomesChange() {
    g_context = "incomes-change";
    const auto L = incomes();
    Sched s = fresh();
    s.noteHits(hit({0}), L, at(0));
    s.setIncomes({inc("share", "/Volumes/music/fixture-income")});
    CHECK(s.state("local") == Sched::State::Idle && !s.next(at(100), true), "a removed income drops its pending scan");
    s.noteHits(hit({0}), L, at(100));
    CHECK(!s.nextWakeup(at(100), true), "and hits for it are ignored");

    // Removed while running: it finishes and is forgotten; one at a time
    // holds until then.
    Sched r = fresh();
    r.noteHits(hit({0}), L, at(0));
    std::optional<AutoScanJob> job = r.next(at(60), true);
    r.started(job->token);
    r.setIncomes({inc("share", "/Volumes/music/fixture-income")});
    CHECK(!r.wanted(job->token) && r.busy(), "removed while running: not wanted, still in flight");
    std::vector<AutoScanIncome> shareOnly = {inc("share", "/Volumes/music/fixture-income")};
    r.noteHits(hit({0}), shareOnly, at(61));
    CHECK(!r.next(at(200), true), "no other scan while it runs");
    // Re-added under the same name meanwhile: a new entry.
    r.setIncomes(incomes());
    r.noteHits(hit({0}), L, at(210));
    CHECK(r.state("local") == Sched::State::Pending, "re-added: a new entry, pending on its own event");
    CHECK(r.exit(job->token, AutoScanExit::Finished, at(220)) == AutoScanResult::Dropped, "the old job is dropped");
    CHECK(r.state("local") == Sched::State::Pending && r.next(at(270), true).has_value(),
          "and leaves the new entry alone");

    // A new path under the same name is another folder.
    Sched m = fresh();
    m.noteHits(hit({0}), L, at(0));
    job = m.next(at(60), true);
    std::vector<AutoScanIncome> moved = incomes();
    moved[0] = inc("local", "/Users/x/Music/fixture-income2");
    m.setIncomes(moved);
    CHECK(!m.wanted(job->token) && m.state("local") == Sched::State::Idle, "moved: the checking job is dropped");
    m.noteHits(hit({0}), L, at(70));
    CHECK(m.state("local") == Sched::State::Idle, "hits from a snapshot with the old path are ignored");
    m.exit(job->token, AutoScanExit::Missing, at(80));
    m.noteHits(hit({0}), moved, at(90));
    CHECK(m.state("local") == Sched::State::Pending, "hits with the new path count");

    // Same path, another spelling on disk: the state stays, open files go.
    Sched k = fresh();
    k.noteHits(openHit(0, "/Users/x/Music/fixture-income/a.flac", true), L, at(0));
    std::vector<AutoScanIncome> respelled = incomes();
    respelled[0].fsPath = "/System/Volumes/Data/Users/x/Music/fixture-income";
    normalizePath(respelled[0].fsPath, respelled[0].fsKey);
    k.setIncomes(respelled);
    CHECK(k.state("local") == Sched::State::Pending && k.openPathCount("local") == 0,
          "respelled: still pending, open files forgotten");
    std::optional<AutoScanJob> j = k.next(at(60), true);
    CHECK(j && j->income.fsPath == "/System/Volumes/Data/Users/x/Music/fixture-income", "the job carries the new spelling");

    // Duplicate names: the first one counts.
    Sched d;
    d.setIncomes({inc("dup", "/Users/x/a"), inc("dup", "/Users/x/b"), inc("", "/Users/x/c")});
    std::vector<AutoScanIncome> dl = {inc("dup", "/Users/x/b")};
    d.noteHits(hit({0}), dl, at(0));
    CHECK(d.state("dup") == Sched::State::Idle, "the second of two names is not an income");

    // Hits naming an index the snapshot does not have.
    Sched o = fresh();
    o.noteHits(hit({42}), L, at(0));
    AutoScanHits bad;
    bad.paths.push_back(AutoScanPathChange{42, "/x", true});
    o.noteHits(bad, L, at(0));
    CHECK(!o.nextWakeup(at(0), true), "an index out of range is ignored");
}

void testWakeup() {
    g_context = "wakeup";
    const auto L = incomes();
    Sched s = fresh();
    CHECK(!s.nextWakeup(at(0), true), "nothing pending: no wakeup");
    s.noteHits(hit({1}), L, at(0));
    s.noteHits(hit({0}), L, at(20));
    CHECK(s.nextWakeup(at(30), true) == at(60), "the earliest quiet-period end");
    s.noteHits(openHit(1, "/Volumes/music/fixture-income/x.flac", true), L, at(25));
    CHECK(s.nextWakeup(at(30), true) == at(80), "an open file moves its income to the cap; the other is next");
    std::optional<AutoScanJob> job = s.next(at(80), true);
    CHECK(job && job->income.name == "local", "the unheld one runs first");
    CHECK(!s.nextWakeup(at(80), true), "none while it is in flight");
    s.started(job->token);
    s.exit(job->token, AutoScanExit::Finished, at(90));
    CHECK(s.nextWakeup(at(90), true) == at(25) + minutes(30), "then the held one at its cap");
    CHECK(s.nextWakeup(at(25) + minutes(30) + seconds(1), false) == at(25) + minutes(30) + seconds(6),
          "due with the lane busy: 5 s later");
    s.setEnabled(false);
    CHECK(!s.nextWakeup(at(100), true), "off: none");
}

} // anonymous namespace

int main(void) {
    @autoreleasepool {
        testCounts();
        testIgnored();
        testMatch();
        testRescan();
        testMutes();
        testOpenClose();
        testDedupe();
        testIncomeEntries();
        testPresence();
        testQuietPeriod();
        testOpenFiles();
        testOneAtATime();
        testLaneBusy();
        testCoalescing();
        testEventsDuringRun();
        testStartup();
        testExits();
        testTurnedOff();
        testIncomesChange();
        testWakeup();
    }
    TEST_MAIN_END();
}
