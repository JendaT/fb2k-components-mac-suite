//
//  IntakeMountAliasesTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeMountAliases (share-relative keys for SMB mounts,
//  PLAN.md B3) and for IntakeView's per-row lookup through them: two aliases
//  of one share, different shares, nested mount points, the mount point
//  itself, no mounts, NFD names, mount points in another case, the changed
//  bases of two tables, and losing one mount point. Synthetic mount lists
//  only: nothing here reads the real mount table.
//
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeView.mm src/Core/IntakeSnapshot.mm
// TEST_DEPS: src/Core/IntakeLog.mm src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm
// TEST_DEPS: src/Core/IntakeLoadPolicy.mm src/Core/IntakeErrorMap.mm src/Core/IntakeEnvelope.mm
// TEST_DEPS: src/Core/IntakeWatchFilter.mm
// TEST_DEPS: src/Core/IntakeGroupBadge.mm
// TEST_DEPS: src/Core/IntakeLibraryIndex.mm src/Core/IntakeSwapPlanner.mm src/Core/IntakeSidecarMembers.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm
// TEST_DEPS: src/Core/IntakeTargetPath.mm
// TEST_DEPS: src/Core/IntakeFields.mm src/Core/IntakeStatusModel.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeLoadPolicy.h"
#include "../src/Core/IntakeMountAliases.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeView.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using namespace intake;

static MountEntry smb(const std::string &mountPoint, const std::string &source) {
    return MountEntry{mountPoint, source, "smbfs"};
}

static MountEntry local(const std::string &mountPoint, const std::string &fsType = "apfs") {
    return MountEntry{mountPoint, "/dev/disk3s1", fsType};
}

// A table as the system shows it: the root volume, the data volume, plus
// the given network mounts.
static std::vector<MountEntry> withSystem(std::vector<MountEntry> extra) {
    std::vector<MountEntry> all = {local("/"), local("/System/Volumes/Data"), local("/dev", "devfs")};
    all.insert(all.end(), extra.begin(), extra.end());
    return all;
}

static std::string key(const std::string &path) {
    std::string out;
    normalizePath(path, out);
    return out;
}

static std::string rw(const MountAliases &aliases, const std::string &path) {
    return aliases.rewritten(key(path));
}

static void testShareKey() {
    g_context = "share-key";
    CHECK(smbShareKey("//user@host/share") == "share", "user@host/share");
    CHECK(smbShareKey("//host/share") == "share", "no user");
    CHECK(smbShareKey("//DOMAIN;user:secret@host.local/Share") == "share", "domain, password, case");
    CHECK(smbShareKey("//user@10.0.0.9/share/") == "share", "trailing slash");
    CHECK(smbShareKey("//user@host/share/sub/dir") == "share/sub/dir", "a folder inside the share");
    CHECK(smbShareKey("//user@host/Share/Sub") == "share/Sub", "only the share name is lowercased");
    CHECK(smbShareKey("//user@host/My%20Share") == "my share", "percent escapes decoded");
    CHECK(smbShareKey("//user@host/a%2Fb") == "a%2fb", "an escaped slash stays escaped (lowercased with the name)");
    CHECK(smbShareKey("//user@host/share/a%2Fb") == "share/a%2Fb", "and keeps its case past the share name");
    CHECK(smbShareKey("//user@host/a%zz") == "a%zz", "a malformed escape stays");
    CHECK(smbShareKey("//user%40corp@host/share") == "share", "an escaped @ in the user name");
    CHECK(smbShareKey("share").empty(), "not a // source");
    CHECK(smbShareKey("//host").empty(), "no share");
    CHECK(smbShareKey("//host/").empty(), "an empty share");
    CHECK(smbShareKey("///share").empty(), "no host");
    CHECK(smbShareKey("//host/share/../other").empty(), "a .. part");
    CHECK(smbShareKey("//host/share//sub").empty(), "an empty part");
    CHECK(smbShareKey("//host/./share").empty(), "a . part");
    CHECK(smbShareKey("").empty(), "empty");
}

static void testTwoAliasesOfOneShare() {
    g_context = "two-aliases";
    auto a = MountAliases::build(withSystem({smb("/Volumes/share", "//user@nas-lan.local/share"),
                                             smb("/Volumes/share-1", "//user@10.8.0.1/share")}));
    CHECK_EQ(a->aliasCount(), 2, "two smbfs aliases");
    const std::string lan = rw(*a, "/Volumes/share/income/dump/Fixture Artist - Album/01.wav");
    const std::string vpn = rw(*a, "/Volumes/share-1/income/dump/Fixture Artist - Album/01.wav");
    CHECK(lan == "/smbfs:share/income/dump/Fixture Artist - Album/01.wav", "the LAN mount becomes the share key");
    CHECK(lan == vpn, "both mount points give the same key");
    CHECK(rw(*a, "/Volumes/share-10/x.wav") == "/Volumes/share-10/x.wav", "a prefix that is not a path boundary");
    CHECK(rw(*a, "/Volumes/sharex/x.wav") == "/Volumes/sharex/x.wav", "another prefix");
    CHECK(rw(*a, "/Users/someone/Music/x.wav") == "/Users/someone/Music/x.wav", "a local path is unchanged");
    CHECK(rw(*a, "/System/Volumes/Data/x") == "/System/Volumes/Data/x", "a local mount is unchanged");
    std::string buffer;
    const std::string local = key("/Users/someone/x.wav");
    std::string_view out = a->rewrite(local, buffer);
    CHECK(out.data() == local.data(), "an unchanged key is returned without a copy");
    CHECK(a->describe().find("/Volumes/share -> /smbfs:share") != std::string::npos, "describe names the alias");
}

static void testDifferentShares() {
    g_context = "different-shares";
    auto a = MountAliases::build(withSystem({smb("/Volumes/music", "//user@host/music"),
                                             smb("/Volumes/downloads", "//user@host/downloads")}));
    CHECK(rw(*a, "/Volumes/music/a.wav") == "/smbfs:music/a.wav", "music share");
    CHECK(rw(*a, "/Volumes/downloads/a.wav") == "/smbfs:downloads/a.wav", "downloads share");
    CHECK(rw(*a, "/Volumes/music/a.wav") != rw(*a, "/Volumes/downloads/a.wav"), "different shares stay apart");
    auto cased = MountAliases::build({smb("/Volumes/Music", "//user@nas/Music"), smb("/Volumes/music-1", "//u@10.0.0.2/music")});
    CHECK(rw(*cased, "/Volumes/Music/a.wav") == rw(*cased, "/Volumes/music-1/a.wav"),
          "share names compare case-insensitively");
    auto sub = MountAliases::build({smb("/Volumes/share", "//user@host/share"),
                                    smb("/Volumes/sub", "//user@host/share/income")});
    CHECK(rw(*sub, "/Volumes/sub/dump/a.wav") == rw(*sub, "/Volumes/share/income/dump/a.wav"),
          "a mount of a folder inside the share matches the share mount");
}

static void testNested() {
    g_context = "nested";
    auto a = MountAliases::build(withSystem({smb("/Volumes/outer", "//user@host/outer"),
                                             smb("/Volumes/outer/inner", "//user@host/inner"),
                                             local("/Volumes/outer/disk", "hfs")}));
    CHECK(rw(*a, "/Volumes/outer/inner/a.wav") == "/smbfs:inner/a.wav", "the longest mount point wins");
    CHECK(rw(*a, "/Volumes/outer/a.wav") == "/smbfs:outer/a.wav", "outside the nested mount");
    CHECK(rw(*a, "/Volumes/outer/innerx/a.wav") == "/smbfs:outer/innerx/a.wav", "a sibling with a longer name");
    CHECK(rw(*a, "/Volumes/outer/disk/a.wav") == "/Volumes/outer/disk/a.wav",
          "a local mount inside a share passes through");
    auto reordered = MountAliases::build(withSystem({local("/Volumes/outer/disk", "hfs"),
                                                     smb("/Volumes/outer/inner", "//user@host/inner"),
                                                     smb("/Volumes/outer", "//user@host/outer")}));
    CHECK(reordered->sameAs(*a), "the table does not depend on the input order");
    CHECK(rw(*reordered, "/Volumes/outer/inner/a.wav") == "/smbfs:inner/a.wav", "same answer reordered");
}

static void testMountPointItself() {
    g_context = "mount-point";
    auto a = MountAliases::build({smb("/Volumes/share-1", "//user@host/share")});
    CHECK(rw(*a, "/Volumes/share-1") == "/smbfs:share", "the mount point itself");
    CHECK(rw(*a, "/Volumes/share-1/") == "/smbfs:share", "with a trailing slash (normalized away)");
    CHECK(rw(*a, "/Volumes") == "/Volumes", "its parent is unchanged");
    auto trailing = MountAliases::build({smb("/Volumes/share-1/", "//user@host/share")});
    CHECK(rw(*trailing, "/Volumes/share-1/a") == "/smbfs:share/a", "a mount point listed with a trailing slash");
}

static void testNoMounts() {
    g_context = "no-mounts";
    auto none = MountAliases::none();
    CHECK(!none->hasAliases() && none->aliasCount() == 0, "none has no aliases");
    CHECK(rw(*none, "/Volumes/share/a.wav") == "/Volumes/share/a.wav", "none changes nothing");
    auto empty = MountAliases::build({});
    CHECK(empty->sameAs(*none), "an empty list is none");
    auto localOnly = MountAliases::build(withSystem({}));
    CHECK(localOnly->sameAs(*none), "local mounts alone are none");
    CHECK(none->describe() == "no smbfs mounts", "describe without aliases");
    auto otherNetwork = MountAliases::build({MountEntry{"/Volumes/nfs", "host:/export", "nfs"},
                                             MountEntry{"/Volumes/afp", "//user@host/share", "afpfs"}});
    CHECK(!otherNetwork->hasAliases() && rw(*otherNetwork, "/Volumes/afp/a") == "/Volumes/afp/a",
          "only smbfs is rewritten");
    auto badSource = MountAliases::build({smb("/Volumes/odd", "not-a-source")});
    CHECK(!badSource->hasAliases() && rw(*badSource, "/Volumes/odd/a") == "/Volumes/odd/a",
          "an smbfs mount with an unusable source passes through");
    auto relative = MountAliases::build({smb("relative/mount", "//h/share")});
    CHECK(!relative->hasAliases(), "a relative mount point is skipped");
}

static void testNfd() {
    g_context = "nfd";
    const std::string nfc = "M\xC3\xBAsica";   // "Música", U+00FA precomposed
    const std::string nfd = "Mu\xCC\x81sica";  // u + U+0301 combining acute
    auto a = MountAliases::build({smb("/Volumes/" + nfd, "//user@host/" + nfd),
                                  smb("/Volumes/" + nfc + "-1", "//user@10.0.0.3/" + nfc)});
    const std::string viaNfd = rw(*a, "/Volumes/" + nfc + "/Fixture Artist/" + nfd + ".wav");
    const std::string viaNfc = rw(*a, "/Volumes/" + nfc + "-1/Fixture Artist/" + nfc + ".wav");
    CHECK(viaNfd == "/smbfs:m\xC3\xBAsica/Fixture Artist/" + nfc + ".wav",
          "an NFD mount point matches an NFC query; the key is NFC");
    CHECK(viaNfd == viaNfc, "NFD and NFC sources of one share give one key");
    auto encoded = MountAliases::build({smb("/Volumes/x", "//user@host/Mu%CC%81sica"),
                                        smb("/Volumes/y", "//user@host/M%C3%BAsica")});
    CHECK(rw(*encoded, "/Volumes/x/a") == rw(*encoded, "/Volumes/y/a"), "percent-encoded NFD and NFC agree");
}

static void testStackedAndSame() {
    g_context = "stacked";
    auto a = MountAliases::build({smb("/Volumes/share", "//user@host/first"),
                                  smb("/Volumes/share", "//user@host/second")});
    CHECK_EQ(a->aliasCount(), 1, "one mount point, one entry");
    CHECK(rw(*a, "/Volumes/share/a") == "/smbfs:second/a", "the later (top) mount wins");
    auto b = MountAliases::build({smb("/Volumes/share", "//user@host/second")});
    CHECK(a->sameAs(*b), "same entries compare equal");
    auto c = MountAliases::build({smb("/Volumes/share", "//user@host/other")});
    CHECK(!c->sameAs(*b), "a different alias differs");
    auto d = MountAliases::build({smb("/Volumes/share", "//other-user@other-host/second")});
    CHECK(d->sameAs(*b), "user and host do not matter");
}

static void testChangedBases() {
    g_context = "changed-bases";
    using Bases = std::vector<std::string>;
    auto a = MountAliases::build(withSystem({smb("/Volumes/share", "//user@host/share")}));
    CHECK(MountAliases::changedBases(*a, *a).empty(), "the same table: none");
    auto b = MountAliases::build(withSystem({smb("/Volumes/share", "//user@host/share"),
                                             smb("/Volumes/backup", "//user@host/backup")}));
    CHECK(MountAliases::changedBases(*a, *b) == Bases({"/Volumes/backup", "/smbfs:backup"}),
          "an added mount: its mount point as each table rewrites it");
    CHECK(MountAliases::changedBases(*b, *a) == Bases({"/smbfs:backup", "/Volumes/backup"}), "a removed one");
    auto c = MountAliases::build({smb("/Volumes/share", "//user@host/other")});
    CHECK(MountAliases::changedBases(*a, *c) == Bases({"/smbfs:share", "/smbfs:other"}),
          "another share at the same mount point");
    auto nested = MountAliases::build({smb("/Volumes/share", "//user@host/share"), local("/Volumes/share/disk", "hfs")});
    CHECK(MountAliases::changedBases(*nested, *a) == Bases({"/Volumes/share/disk", "/smbfs:share/disk"}),
          "a nested pass-through mount going away: its keys now go through the share's alias");
    auto withUsb = MountAliases::build(withSystem({smb("/Volumes/share", "//user@host/share"), local("/Volumes/usb")}));
    CHECK(MountAliases::changedBases(*a, *withUsb).empty(), "a local mount outside every share changes nothing");
}

static void testMountPointCase() {
    g_context = "mount-case";
    auto a = MountAliases::build({smb("/Volumes/Music", "//user@host/Music")});
    CHECK(rw(*a, "/Volumes/music/income/Fixture Album") == "/smbfs:music/income/Fixture Album",
          "a CLI root spelled in another case is aliased");
    CHECK(rw(*a, "/Volumes/Music/income/Fixture Album/01.wav") == "/smbfs:music/income/Fixture Album/01.wav",
          "a row on the mount point as mounted");
    CHECK(rw(*a, "/VOLUMES/MUSIC") == "/smbfs:music", "the mount point itself, in any case");
    CHECK(rw(*a, "/Volumes/music/Income/x") == "/smbfs:music/Income/x", "the rest of the path keeps its case");
    CHECK(rw(*a, "/Volumes/musicx/a") == "/Volumes/musicx/a", "still only at a path boundary");
    auto accented = MountAliases::build({smb("/Volumes/\xC3\x89T\xC3\x89", "//user@host/ete")});  // "ÉTÉ"
    CHECK(rw(*accented, "/Volumes/\xC3\xA9t\xC3\xA9/a") == "/Volumes/\xC3\xA9t\xC3\xA9/a",
          "non-ASCII letters are compared as bytes");
    CHECK(rw(*accented, "/volumes/\xC3\x89t\xC3\x89/a") == "/smbfs:ete/a", "ASCII around them is folded");
    auto nested = MountAliases::build({smb("/Volumes/Share", "//user@host/share"), local("/Volumes/Share/Disk", "hfs")});
    CHECK(rw(*nested, "/volumes/share/disk/a") == "/volumes/share/disk/a",
          "a nested pass-through mount is matched ignoring case too");
}

// --- IntakeView over aliased snapshots ---

static IntakeRecord record(const std::string &id, const std::string &rootPath, IntakeStatus status) {
    IntakeRecord r;
    r.id = id;
    r.rootPath = rootPath;
    normalizePath(rootPath, r.rootKey);
    r.status = status;
    return r;
}

static std::shared_ptr<const IntakeSnapshot> aliasedSnapshot(std::vector<IntakeRecord> records,
                                                             const MountAliases &aliases) {
    applyMountAliases(records, aliases);
    return IntakeSnapshot::build(std::move(records), {});
}

static void testViewThroughAliases() {
    g_context = "view-aliases";
    std::vector<MountEntry> both = withSystem({smb("/Volumes/share", "//user@nas-lan.local/share"),
                                               smb("/Volumes/share-1", "//user@10.8.0.1/share")});
    auto aliases = MountAliases::build(both);
    // The CLI reports roots under the LAN mount; foobar2000 resolved its
    // items to the VPN mount (S0).
    std::vector<IntakeRecord> records = {
        record("itk_00000001", "/Volumes/share/income/dump/Fixture Artist - New Album", IntakeStatus::New),
        record("itk_00000002", "/Volumes/share/income/dump/Fixture Artist - Rejected Album", IntakeStatus::Rejected),
        record("itk_00000003", "/Users/someone/Music/income/Fixture Artist - Local Album", IntakeStatus::Resolved),
    };
    auto snapshot = aliasedSnapshot(records, *aliases);
    auto view = IntakeView::make(snapshot, aliases);
    ViewScratch scratch;
    const IntakeRowVisual *vpn =
        view->visualFor("/Volumes/share-1/income/dump/Fixture Artist - New Album/01 - Test Track One.wav", scratch);
    CHECK(vpn && vpn->icon == IntakeIcon::CircleOpen, "a row on the other mount point of the share matches");
    const IntakeRowVisual *lan =
        view->visualFor("file:///Volumes/share/income/dump/Fixture Artist - New Album/02.wav", scratch);
    CHECK(lan && lan->icon == IntakeIcon::CircleOpen, "a file:// row on the CLI's mount point matches");
    const IntakeRowVisual *rejected =
        view->visualFor("/Volumes/share-1/income/dump/Fixture Artist - Rejected Album/01.wav", scratch);
    CHECK(rejected && rejected->strikethrough, "another root through the alias");
    const IntakeRowVisual *localRow =
        view->visualFor("/Users/someone/Music/income/Fixture Artist - Local Album/01.wav", scratch);
    CHECK(localRow && localRow->icon == IntakeIcon::CircleOpen, "a local root needs no alias");
    CHECK(view->visualFor("/Volumes/share-1/income/dump/Other/01.wav", scratch) == nullptr, "no root: nothing");
    CHECK(view->visualFor("mac-volume://0000/income/x.wav", scratch) == nullptr, "an unconverted scheme: nothing");
    CHECK(view->visualFor("relative/x.wav", scratch) == nullptr, "a relative path: nothing");

    // NFD row path under the alias (SMB names are often stored decomposed).
    std::vector<IntakeRecord> unicode = {record("itk_00000004", "/Volumes/share/income/M\xC3\xBAsica Album",
                                                IntakeStatus::Approved)};
    auto uview = IntakeView::make(aliasedSnapshot(unicode, *aliases), aliases);
    const IntakeRowVisual *nfdRow = uview->visualFor("/Volumes/share-1/income/Mu\xCC\x81sica Album/01.wav", scratch);
    CHECK(nfdRow && nfdRow->icon == IntakeIcon::CircleRightHalf, "an NFD row path through the alias");

    g_context = "lose-one-mount";
    // Off the LAN only the VPN mount stays. The CLI (configured on the VPN
    // mount here) reports roots there; rows under the lost mount point stop
    // matching, rows under the remaining one keep matching.
    std::vector<IntakeRecord> vpnRoots = {
        record("itk_00000005", "/Volumes/share-1/income/dump/Fixture Artist - Proposed Album", IntakeStatus::Proposed)};
    auto bothView = IntakeView::make(aliasedSnapshot(vpnRoots, *aliases), aliases);
    const std::string lanRow = "/Volumes/share/income/dump/Fixture Artist - Proposed Album/01.wav";
    const std::string vpnRow = "/Volumes/share-1/income/dump/Fixture Artist - Proposed Album/01.wav";
    CHECK(bothView->visualFor(lanRow, scratch) && bothView->visualFor(vpnRow, scratch),
          "with both mounts, rows under either mount point match");
    auto vpnOnly = MountAliases::build(withSystem({smb("/Volumes/share-1", "//user@10.8.0.1/share")}));
    CHECK(!vpnOnly->sameAs(*aliases), "losing a mount changes the table");
    auto lostView = IntakeView::make(aliasedSnapshot(vpnRoots, *vpnOnly), vpnOnly);
    CHECK(lostView->visualFor(lanRow, scratch) == nullptr, "rows under the lost mount point stop matching");
    const IntakeRowVisual *kept = lostView->visualFor(vpnRow, scratch);
    CHECK(kept && kept->icon == IntakeIcon::CircleLeftHalf, "rows under the remaining mount point keep matching");
    auto noneView = IntakeView::make(aliasedSnapshot(vpnRoots, *MountAliases::none()), MountAliases::none());
    CHECK(noneView->visualFor(vpnRow, scratch) != nullptr && noneView->visualFor(lanRow, scratch) == nullptr,
          "with no mount table the plain path still matches itself");
}

static void testViewInert() {
    g_context = "view-inert";
    auto aliases = MountAliases::none();
    std::vector<IntakeRecord> records = {
        record("itk_00000001", "/income/dump/Fixture Artist - New Album", IntakeStatus::New),
        record("itk_00000002", "/income/dump/Fixture Artist - Collected Album", IntakeStatus::GcDone)};
    auto snapshot = aliasedSnapshot(records, *aliases);
    auto inert = IntakeView::make(snapshot, aliases, "version: Intake CLI not available");
    CHECK(inert->isInert() && !inert->rendersNothing(), "an inert view over known roots");
    ViewScratch scratch;
    const IntakeRowVisual *v = inert->visualFor("/income/dump/Fixture Artist - New Album/01.wav", scratch);
    CHECK(v && v->bgTint == 0 && v->icon == IntakeIcon::None && !v->strikethrough &&
              v->tooltip == "intake inactive: version: Intake CLI not available",
          "rows under a known root get a tooltip-only visual naming the reason");
    const IntakeRowVisual *gc = inert->visualFor("/income/dump/Fixture Artist - Collected Album/01.wav", scratch);
    CHECK(gc && gc->tooltip == v->tooltip, "also under a root that renders nothing");
    CHECK(inert->visualFor("/elsewhere/01.wav", scratch) == nullptr, "other rows get nothing");
    auto inertEmpty = IntakeView::make(nullptr, nullptr, "status: Intake rules not configured");
    CHECK(inertEmpty->rendersNothing() && inertEmpty->visualFor("/income/dump/x.wav", scratch) == nullptr,
          "inert with no successful load renders nothing");
    auto normal = IntakeView::make(snapshot, aliases);
    CHECK(!normal->isInert(), "no reason, not inert");
    CHECK(normal->visualFor("/income/dump/Fixture Artist - Collected Album/01.wav", scratch) == nullptr,
          "gc_done renders nothing when not inert");
    const IntakeRecord *r = normal->recordFor("/income/dump/Fixture Artist - Collected Album/01.wav", scratch);
    CHECK(r && r->id == "itk_00000002", "recordFor still finds the root");
    CHECK(inertVisual("x").tooltip == std::string(kInertTooltipPrefix) + "x", "inertVisual");
}

static void testViewMountPointCase() {
    g_context = "view-mount-case";
    // The CLI config names /Volumes/music; the share is mounted at
    // /Volumes/Music, where foobar2000 resolves its rows.
    auto aliases = MountAliases::build(withSystem({smb("/Volumes/Music", "//user@host/Music")}));
    std::vector<IntakeRecord> records = {
        record("itk_00000001", "/Volumes/music/income/dump/Fixture Artist - New Album", IntakeStatus::New)};
    auto view = IntakeView::make(aliasedSnapshot(records, *aliases), aliases);
    ViewScratch scratch;
    const IntakeRowVisual *row =
        view->visualFor("/Volumes/Music/income/dump/Fixture Artist - New Album/01 - Test Track One.wav", scratch);
    CHECK(row && row->icon == IntakeIcon::CircleOpen, "a row under the mount point as mounted matches");
    CHECK(view->visualFor("/Volumes/Music/Income/dump/Fixture Artist - New Album/01.wav", scratch) == nullptr,
          "a case difference past the mount point still matches nothing");
}

int main(void) {
    @autoreleasepool {
        testShareKey();
        testTwoAliasesOfOneShare();
        testDifferentShares();
        testNested();
        testMountPointItself();
        testNoMounts();
        testNfd();
        testStackedAndSame();
        testChangedBases();
        testMountPointCase();
        testViewThroughAliases();
        testViewInert();
        testViewMountPointCase();
    }
    TEST_MAIN_END();
}
