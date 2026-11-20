//
//  IntakeMountAliasesTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeMountAliases (share-relative keys for SMB mounts,
//  PLAN.md B3) and for IntakeView's per-row lookup through them: two aliases
//  of one share, different shares, nested mount points, the mount point
//  itself, no mounts, NFD names, mount points in another case, the changed
//  bases of two tables, and losing one mount point. B11 share links: a link
//  to either mount point of a share, to a mirror and to the unmounted
//  placeholder, path boundaries, NFD link text, exact case (a row in
//  another letter case counted as under an unusable link), a link-form
//  root, nested links, a link to "/", the Delete census over a view (a
//  link on the share, a row spelling it in another letter case, a mirror,
//  the unmounted placeholder, no link),
//  changed bases on a re-point and on
//  removal, order independence, the rejected cases, and the per-link
//  reasons and flag text for the preferences page. Synthetic mount
//  lists and link reads only: nothing here reads the real mount table or
//  a real link.
//
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeView.mm src/Core/IntakeSnapshot.mm
// TEST_DEPS: src/Core/IntakeLog.mm src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm
// TEST_DEPS: src/Core/IntakeLoadPolicy.mm src/Core/IntakeErrorMap.mm src/Core/IntakeEnvelope.mm
// TEST_DEPS: src/Core/IntakeWatchFilter.mm
// TEST_DEPS: src/Core/IntakeGroupBadge.mm
// TEST_DEPS: src/Core/IntakeLibraryIndex.mm src/Core/IntakeSwapPlanner.mm src/Core/IntakeSidecarMembers.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm src/Core/IntakeWatchSet.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeLoadPolicy.h"
#include "../src/Core/IntakeMountAliases.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeSwapPlanner.h"
#include "../src/Core/IntakeView.h"
#include "../src/Core/IntakeWatchSet.h"
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

// --- B11 share links ---

// What readShareLink would report for `link` (synthetic: nothing is read).
static ShareLinkRead linkRead(const std::string &link, const std::string &target,
                              ShareLinkStatus status = ShareLinkStatus::Link) {
    ShareLinkRead r;
    r.status = status;
    r.linkPath = link;
    if (status == ShareLinkStatus::Link) r.rawTarget = target;
    r.resolvedParent = parentDirectory(link);
    return r;
}

static const std::string kLink = "/Users/x/Music/NAS/music";

static std::vector<MountEntry> bothMounts() {
    return withSystem({smb("/Volumes/music", "//user@nas-lan.local/music"), smb("/Volumes/music-1", "//user@10.8.0.1/music")});
}

static bool hasNote(const MountAliases &a, const std::string &part) {
    for (const std::string &n : a.notes()) {
        if (n.find(part) != std::string::npos) return true;
    }
    return false;
}

static void testShareLinkOnShare() {
    g_context = "link-on-share";
    const std::vector<MountEntry> mounts = bothMounts();
    auto lan = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/music")});
    auto vpn = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/music-1")});
    const std::string rootKey = rw(*lan, "/Volumes/music/income/dump/Fixture Artist - Album");
    CHECK(rootKey == "/smbfs:music/income/dump/Fixture Artist - Album", "the /Volumes-form root key names the share");
    CHECK(rw(*lan, kLink + "/income/dump/Fixture Artist - Album") == rootKey,
          "link -> /Volumes/music: the link-form path gives the root's key");
    CHECK(rw(*vpn, kLink + "/income/dump/Fixture Artist - Album") == rootKey,
          "link -> /Volumes/music-1 (the same share): the same key");
    CHECK(rw(*lan, "file://" + kLink + "/income/dump/Fixture Artist - Album/01.wav") == rootKey + "/01.wav",
          "a file:// row under the link");
    CHECK(rw(*lan, kLink) == "/smbfs:music", "the link itself is the share");
    CHECK(rw(*lan, "/Volumes/music-1/income/a.wav") == "/smbfs:music/income/a.wav", "the smbfs entries still work");
    CHECK(lan->links().size() == 1, "one link entry");
    if (lan->links().size() == 1) {
        const MountAliases::LinkEntry &e = lan->links()[0];
        CHECK(e.linkKey == kLink && e.rawLink == kLink && e.rawTarget == "/Volumes/music" &&
                  e.targetKey == "/smbfs:music" && e.onShare,
              "the entry's fields: the target rewritten through the smbfs entries, on a share");
    }
    CHECK(vpn->links().size() == 1 && vpn->links()[0].rawTarget == "/Volumes/music-1" &&
              vpn->links()[0].targetKey == "/smbfs:music",
          "the raw target is kept for Swap");
    CHECK(!lan->underOffShareLink(key(kLink + "/income/a.wav")), "rows under a link on the share are not off it");
    CHECK(lan->notes().empty(), "no note for a link on the share");
    CHECK(lan->aliasCount() == 2, "links are not counted as smbfs aliases");
    CHECK(lan->describe().find("link " + kLink + " -> /smbfs:music (exact case, on a share)") != std::string::npos,
          "describe names the link, its case rule and that it is on a share");
    CHECK(!lan->sameAs(*vpn), "another raw target is another table (Swap reads it)");
    CHECK(MountAliases::changedBases(*lan, *vpn).empty(), "but no key rewrites differently: no bases");
}

static void testShareLinkOffShare() {
    g_context = "link-mirror";
    const std::vector<MountEntry> mounts = bothMounts();
    auto mirror = MountAliases::build(mounts, {linkRead(kLink, "/Users/x/mirror/music")});
    const std::string row = kLink + "/income/dump/Fixture Artist - Album/01.wav";
    CHECK(rw(*mirror, row) == "/Users/x/mirror/music/income/dump/Fixture Artist - Album/01.wav",
          "link -> mirror: the mirror's key, no share key");
    CHECK(rw(*mirror, row).rfind("/smbfs:", 0) != 0, "nothing under /smbfs:");
    CHECK(mirror->links().size() == 1 && !mirror->links()[0].onShare, "off the share");
    CHECK(mirror->underOffShareLink(key(row)), "its rows lie under an off-share link");
    CHECK(mirror->underOffShareLink(key(kLink)), "the link itself too");
    CHECK(!mirror->underOffShareLink(key("/Volumes/music/income/a.wav")), "a /Volumes row is not under a link");
    CHECK(!mirror->underOffShareLink(key("/Users/x/Music/other/a.wav")), "nor a local row elsewhere");
    CHECK(!mirror->underOffShareLink(key(kLink + "2/a.wav")), "nor one that only starts like the link");
    CHECK(mirror->notes().size() == 1 && hasNote(*mirror, "not at a mounted share"),
          "one note says why its rows match no share root");
    CHECK(mirror->describe().find("(exact case, not on a share)") != std::string::npos, "describe says off the share");

    g_context = "link-placeholder";
    // Unmounted: no smbfs entry; the agent points the link at /Volumes/music.
    auto placeholder = MountAliases::build(withSystem({}), {linkRead(kLink, "/Volumes/music")});
    CHECK(rw(*placeholder, kLink + "/income/a") == rw(*placeholder, "/Volumes/music/income/a") &&
              rw(*placeholder, "/Volumes/music/income/a") == "/Volumes/music/income/a",
          "link -> placeholder: the unaliased /Volumes/music root key, as /Volumes rows have while unmounted");
    CHECK(placeholder->underOffShareLink(key(kLink + "/income/a")), "and its rows count as off the share");
    CHECK(placeholder->links().size() == 1 && placeholder->links()[0].targetKey == "/Volumes/music",
          "target key unaliased");
    CHECK(placeholder->describe().rfind("no smbfs mounts; link " + kLink, 0) == 0,
          "describe with links and no smbfs mount");

    g_context = "link-nested-mount";
    // A local disk mounted inside the share passes through: not on the share.
    auto nested = MountAliases::build(withSystem({smb("/Volumes/music", "//user@host/music"),
                                                  local("/Volumes/music/disk", "hfs")}),
                                      {linkRead(kLink, "/Volumes/music/disk/sub")});
    CHECK(nested->links().size() == 1 && !nested->links()[0].onShare &&
              nested->links()[0].targetKey == "/Volumes/music/disk/sub",
          "a target on a local mount inside the share is off the share");
}

static void testShareLinkMatching() {
    g_context = "link-boundary";
    const std::vector<MountEntry> mounts = bothMounts();
    auto a = MountAliases::build(mounts, {linkRead("/Users/x/music", "/Volumes/music")});
    CHECK(rw(*a, "/Users/x/music2/a.wav") == "/Users/x/music2/a.wav", "/Users/x/music2 is not under /Users/x/music");
    CHECK(rw(*a, "/Users/x/music/a.wav") == "/smbfs:music/a.wav", "/Users/x/music/a.wav is");
    CHECK(rw(*a, "/Users/x/mus") == "/Users/x/mus", "a shorter name is not");

    g_context = "link-case";
    CHECK(rw(*a, "/Users/x/Music/a.wav") == "/Users/x/Music/a.wav", "a link matches byte-exact, never ignoring case");
    CHECK(rw(*a, "/users/x/music/a.wav") == "/users/x/music/a.wav", "anywhere in the link path");
    CHECK(a->underOffShareLink(key("/Users/x/Music/a.wav")) && a->underOffShareLink(key("/USERS/X/MUSIC")),
          "but such a row counts as under an unusable link (the census: unchecked), though the link is on the share");
    CHECK(!a->underOffShareLink(key("/Users/x/music/a.wav")) && !a->underOffShareLink(key("/Users/x/Music2/a.wav")),
          "the link's own spelling does not, nor another name at the component boundary");

    g_context = "link-nfd";
    const std::string nfc = "/Users/x/M\xC3\xBAsica/NAS";   // "Música", precomposed
    const std::string nfd = "/Users/x/Mu\xCC\x81sica/NAS";  // decomposed
    auto n = MountAliases::build(mounts, {linkRead(nfd, "/Volumes/music")});
    CHECK(rw(*n, nfc + "/Fixture Artist/01.wav") == "/smbfs:music/Fixture Artist/01.wav",
          "NFD link text meets an NFC row");
    CHECK(rw(*n, nfd + "/Fixture Artist/01.wav") == "/smbfs:music/Fixture Artist/01.wav", "and an NFD row");
    CHECK(n->links().size() == 1 && n->links()[0].rawLink == nfd && n->links()[0].linkKey == key(nfc),
          "the raw link keeps its bytes, the key is NFC");

    g_context = "link-nested";
    // A link inside another link's folder (as the kernel would resolve it):
    // the longer one wins for its own rows.
    auto nestedLinks = MountAliases::build(mounts, {linkRead("/Users/x/a", "/Users/x/mirror"),
                                                    linkRead("/Users/x/a/b", "/Volumes/music-1/sub")});
    CHECK(rw(*nestedLinks, "/Users/x/a/b/c.wav") == "/smbfs:music/sub/c.wav", "the longer link wins");
    CHECK(rw(*nestedLinks, "/Users/x/a/c.wav") == "/Users/x/mirror/c.wav", "the shorter one elsewhere");
    CHECK(!nestedLinks->underOffShareLink(key("/Users/x/a/b/c.wav")) &&
              nestedLinks->underOffShareLink(key("/Users/x/a/c.wav")),
          "underOffShareLink follows the entry rewrite() uses");
    CHECK(nestedLinks->links().size() == 2 && nestedLinks->links()[0].linkKey == "/Users/x/a",
          "links() by link key");

    g_context = "link-to-root";
    auto toRoot = MountAliases::build(mounts, {linkRead("/Users/x/rootlink", "/")});
    CHECK(rw(*toRoot, "/Users/x/rootlink/etc/a") == "/etc/a" && rw(*toRoot, "/Users/x/rootlink") == "/",
          "a link to / maps onto the rest of the path (no //)");
}

static void testShareLinkRootAndView() {
    g_context = "link-view";
    const std::vector<MountEntry> mounts = bothMounts();
    auto aliases = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/music-1")});
    std::vector<IntakeRecord> records = {
        record("itk_00000001", "/Volumes/music/income/dump/Fixture Artist - New Album", IntakeStatus::New),
        // A root the CLI spelled through the link (pure test: the CLI keeps /Volumes roots).
        record("itk_00000002", kLink + "/income/dump/Fixture Artist - Linked Album", IntakeStatus::Rejected),
    };
    auto snapshot = aliasedSnapshot(records, *aliases);
    auto view = IntakeView::make(snapshot, aliases);
    ViewScratch scratch;
    const IntakeRowVisual *linked =
        view->visualFor("file://" + kLink + "/income/dump/Fixture Artist - New Album/01 - Test Track One.wav", scratch);
    CHECK(linked && linked->icon == IntakeIcon::CircleOpen, "a link-form row matches the /Volumes-form root");
    const IntakeRowVisual *rejected =
        view->visualFor("/Volumes/music/income/dump/Fixture Artist - Linked Album/01.wav", scratch);
    CHECK(rejected && rejected->strikethrough, "a link-form root matches a /Volumes row");
    CHECK(snapshot->recordForId("itk_00000002") &&
              snapshot->recordForId("itk_00000002")->rootKey == "/smbfs:music/income/dump/Fixture Artist - Linked Album",
          "its root key is the share key");
    auto unlinked = IntakeView::make(aliasedSnapshot(records, *MountAliases::build(mounts)), MountAliases::build(mounts));
    CHECK(unlinked->visualFor("file://" + kLink + "/income/dump/Fixture Artist - New Album/01.wav", scratch) == nullptr,
          "without the link entry the same row matches nothing (negative control)");
}

// The Delete census decision for one row of `view` (IntakeSwap matchRow's
// census rule): the root ids are those of `view`'s snapshot.
static CensusEntry census(const IntakeView &view, const std::string &path) {
    ViewScratch scratch;
    const IntakeRecord *record = view.recordFor(path, scratch);
    return censusEntry(false, view.underOffShareLink(path, scratch), record != nullptr);
}

static void testShareLinkCensus() {
    g_context = "link-census";
    const std::vector<MountEntry> mounts = bothMounts();
    const std::string rootPath = "/Volumes/music/income/dump/Fixture Artist - Placed Album";
    const std::vector<IntakeRecord> records = {record("itk_00000001", rootPath, IntakeStatus::Placed)};
    auto viewWith = [&](const std::vector<MountEntry> &m, const std::vector<ShareLinkRead> &links) {
        auto aliases = MountAliases::build(m, links);
        return IntakeView::make(aliasedSnapshot(records, *aliases), aliases);
    };
    const std::string linkRow = "file://" + kLink + "/income/dump/Fixture Artist - Placed Album/01.wav";
    const std::string volumeRow = "/Volumes/music-1/income/dump/Fixture Artist - Placed Album/01.wav";
    const std::string libraryRow = "file://" + kLink + "/library/Fixture Artist/Placed Album/01.wav";

    auto onShare = viewWith(mounts, {linkRead(kLink, "/Volumes/music-1")});
    CHECK(census(*onShare, linkRow) == CensusEntry::Income, "link on the share: a link-form income row counts as income");
    CHECK(census(*onShare, libraryRow) == CensusEntry::Clear, "and a link-form library row is clear");
    // share_links spelled /Users/x/Music/NAS/music, the items .../music/NAS/...:
    // the same link on a case-insensitive volume, yet rewrite() maps no item.
    const std::string otherCaseRow = "file:///Users/x/music/NAS/music/income/dump/Fixture Artist - Placed Album/01.wav";
    ViewScratch caseScratch;
    CHECK(onShare->recordFor(otherCaseRow, caseScratch) == nullptr &&
              census(*onShare, otherCaseRow) == CensusEntry::Unchecked,
          "a row spelling the link in another letter case matches nothing, and counts as unchecked, never clear");

    auto mirror = viewWith(mounts, {linkRead(kLink, "/Users/x/mirror/music")});
    CHECK(census(*mirror, linkRow) == CensusEntry::Unchecked,
          "link -> mirror: the row matches nothing now, but counts as unchecked, never clear");
    CHECK(census(*mirror, libraryRow) == CensusEntry::Unchecked, "every row under that link, a library row too");
    CHECK(census(*mirror, volumeRow) == CensusEntry::Income, "a /Volumes-form income row is still an income row");
    CHECK(census(*mirror, "file:///Users/x/Music/other/01.wav") == CensusEntry::Clear, "a local row elsewhere: clear");
    CHECK(census(*mirror, "file://" + kLink + "2/01.wav") == CensusEntry::Clear,
          "a name that only starts like the link: clear");

    // Unmounted: the agent points the link at /Volumes/music; the last
    // snapshot's roots stay unaliased, so the row still matches its root.
    auto placeholder = viewWith(withSystem({}), {linkRead(kLink, "/Volumes/music")});
    ViewScratch scratch;
    CHECK(placeholder->recordFor(linkRow, scratch) != nullptr, "the placeholder: the row keeps matching (last tint)");
    CHECK(census(*placeholder, linkRow) == CensusEntry::Unchecked, "but the census counts it unchecked");

    auto noLinks = viewWith(mounts, {});
    CHECK(!noLinks->underOffShareLink(linkRow, scratch) && census(*noLinks, linkRow) == CensusEntry::Clear,
          "no link configured: the row matches nothing and is clear, as before B11");
    CHECK(!mirror->underOffShareLink("mac-volume://U1/income/01.wav", scratch) &&
              !mirror->underOffShareLink("", scratch) && !mirror->underOffShareLink("relative/01.wav", scratch),
          "another scheme, an empty or relative path: not under a link");
}

static void testShareLinkChanges() {
    g_context = "link-changed-bases";
    using Bases = std::vector<std::string>;
    const std::vector<MountEntry> mounts = withSystem({smb("/Volumes/music", "//user@host/music")});
    auto onShare = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/music")});
    auto repointed = MountAliases::build(mounts, {linkRead(kLink, "/Users/x/mirror/music")});
    auto removed = MountAliases::build(mounts);
    CHECK(MountAliases::changedBases(*onShare, *onShare).empty(), "the same table: none");
    CHECK(MountAliases::changedBases(*onShare, *repointed) == Bases({"/smbfs:music", "/Users/x/mirror/music"}),
          "a re-point: the link as each table rewrites it");
    CHECK(MountAliases::changedBases(*onShare, *removed) == Bases({"/smbfs:music", kLink}),
          "a removed link: the old target is still reported");
    CHECK(MountAliases::changedBases(*removed, *onShare) == Bases({kLink, "/smbfs:music"}), "an added link");
    // The share unmounts; the agent points the link at the placeholder.
    auto unmounted = MountAliases::build(withSystem({}), {linkRead(kLink, "/Volumes/music")});
    const Bases unmount = MountAliases::changedBases(*onShare, *unmounted);
    CHECK(unmount == Bases({"/smbfs:music", "/Volumes/music", "/smbfs:music", "/Volumes/music"}),
          "the mount and the link entry both change (the link's target key moved)");
    // A link and a mount point spelled alike in two tables stay apart.
    auto mountX = MountAliases::build({smb("/Volumes/x", "//user@host/x")});
    auto linkX = MountAliases::build(withSystem({}), {linkRead("/Volumes/x", "/Users/x/mirror")});
    CHECK(MountAliases::changedBases(*mountX, *linkX).size() == 4, "a link never merges with a mount key");

    g_context = "link-remount-rows";
    std::vector<IntakeRecord> records = {
        record("itk_00000001", "/Volumes/music/income/dump/Fixture Artist - New Album", IntakeStatus::New)};
    auto before = aliasedSnapshot(records, *onShare);
    CHECK(remountChangesRows(*before, *onShare, *aliasedSnapshot(records, *repointed), *repointed),
          "a re-point off the share changes rows under a share root");
    CHECK(remountChangesRows(*before, *onShare, *aliasedSnapshot(records, *removed), *removed),
          "removing the link does too");
    auto other = MountAliases::build(bothMounts(), {linkRead(kLink, "/Volumes/music")});
    auto otherVpn = MountAliases::build(bothMounts(), {linkRead(kLink, "/Volumes/music-1")});
    CHECK(!remountChangesRows(*aliasedSnapshot(records, *other), *other, *aliasedSnapshot(records, *otherVpn), *otherVpn),
          "a move between two mounts of one share changes no row");

    g_context = "link-same";
    const std::vector<ShareLinkRead> reads = {linkRead(kLink, "/Volumes/music"),
                                              linkRead("/Users/x/other", "/Users/x/mirror"),
                                              linkRead("/Users/x/plain", "", ShareLinkStatus::NotLink)};
    const std::vector<ShareLinkRead> reordered = {reads[2], reads[1], reads[0]};
    auto first = MountAliases::build(mounts, reads);
    auto second = MountAliases::build(mounts, reordered);
    CHECK(first->sameAs(*second) && second->sameAs(*first), "links (and notes) in another order: the same table");
    CHECK(rw(*first, kLink + "/a") == rw(*second, kLink + "/a"), "same answers");
    CHECK(!first->sameAs(*onShare), "more links: another table");
    CHECK(!repointed->sameAs(*onShare), "a re-point: another table");
    CHECK(MountAliases::build(mounts, {})->sameAs(*removed), "no links is the one-argument table");
    CHECK(!MountAliases::build(mounts, {linkRead("/Users/x/plain", "", ShareLinkStatus::NotLink)})->sameAs(*removed),
          "a new note alone is another table (logged once)");
}

static void testShareLinkRejected() {
    g_context = "link-rejected";
    const std::vector<MountEntry> mounts = bothMounts();
    auto t = MountAliases::build(mounts, {
        linkRead("/Volumes/music", "/Users/x/mirror"),        // a mounted share's mount point
        linkRead("/volumes/MUSIC-1", "/Users/x/mirror"),      // another one, in another case
        linkRead("/System/Volumes/Data", "/Users/x/mirror"),  // a local mount point
        linkRead("/Volumes/music/link", "/Volumes/music-1"),  // under an smbfs mount
        linkRead("/", "/Volumes/music"),                      // the root
        linkRead("/Users/x/plain", "", ShareLinkStatus::NotLink),
        linkRead("/Users/x/none", "", ShareLinkStatus::Missing),
        linkRead("/Users/x/NAS/music", "", ShareLinkStatus::OnNetwork),
        linkRead("/Users/x/loop", "", ShareLinkStatus::Loop),
        linkRead("/Users/x/no-target", ""),                   // a Link without a usable target
    });
    CHECK(t->links().empty(), "no link entry for any of them");
    CHECK_EQ(t->notes().size(), 10, "one note each");
    CHECK(hasNote(*t, "\"/Volumes/music\": a mount point") && hasNote(*t, "\"/volumes/MUSIC-1\": a mount point") &&
              hasNote(*t, "\"/System/Volumes/Data\": a mount point"),
          "mount points");
    CHECK(hasNote(*t, "\"/Volumes/music/link\": on a network volume"), "under an smbfs mount");
    CHECK(hasNote(*t, "\"/\": the root folder"), "the root");
    CHECK(hasNote(*t, "\"/Users/x/plain\": not a symlink") && hasNote(*t, "\"/Users/x/none\": missing") &&
              hasNote(*t, "\"/Users/x/NAS/music\": on a network volume") &&
              hasNote(*t, "\"/Users/x/loop\": a symlink loop"),
          "the read statuses");
    CHECK(hasNote(*t, "\"/Users/x/no-target\": its target is not an absolute path"), "a target that is no path");
    CHECK(rw(*t, "/Volumes/music/a.wav") == "/smbfs:music/a.wav" && rw(*t, "/Volumes/music/link/a") == "/smbfs:music/link/a" &&
              rw(*t, "/Volumes/music-1/a.wav") == "/smbfs:music/a.wav",
          "no rejected path shadows a share's own entry");
    CHECK(rw(*t, "/Users/x/plain/a") == "/Users/x/plain/a" && rw(*t, "/x/a") == "/x/a",
          "rejected paths keep today's behaviour");
    CHECK(!t->underOffShareLink(key("/Users/x/plain/a")) && !t->underOffShareLink(key("/Volumes/music/a")),
          "nothing counts as off the share");
    CHECK(t->sameAs(*MountAliases::build(mounts, {
              linkRead("/Users/x/loop", "", ShareLinkStatus::Loop), linkRead("/", "/Volumes/music"),
              linkRead("/Volumes/music", "/Users/x/mirror"), linkRead("/volumes/MUSIC-1", "/Users/x/mirror"),
              linkRead("/System/Volumes/Data", "/Users/x/mirror"), linkRead("/Volumes/music/link", "/Volumes/music-1"),
              linkRead("/Users/x/plain", "", ShareLinkStatus::NotLink),
              linkRead("/Users/x/none", "", ShareLinkStatus::Missing),
              linkRead("/Users/x/NAS/music", "", ShareLinkStatus::OnNetwork), linkRead("/Users/x/no-target", "")})),
          "notes are sorted: the input order does not matter");
    auto noMounts = MountAliases::build({}, {linkRead(kLink, "/Volumes/music")});
    CHECK(noMounts->links().empty() && hasNote(*noMounts, "on a network volume"),
          "with no mount table nothing is known to be local: no entry");
}

// B11, the preferences page: build()'s per-link reasons and the flag text
// summarizeShareLink makes of them.
static void testShareLinkSummary() {
    g_context = "link-reasons";
    const std::vector<MountEntry> mounts = bothMounts();
    std::vector<std::string> reasons;
    auto t = MountAliases::build(mounts,
                                 {linkRead(kLink, "/Volumes/music-1"), linkRead("/Users/x/plain", "", ShareLinkStatus::NotLink),
                                  linkRead("/Volumes/music", "/Users/x/mirror")},
                                 &reasons);
    CHECK(reasons == std::vector<std::string>({"", "not a symlink", "a mount point"}),
          "one reason per link, in input order; empty for the mapped one");
    CHECK(t->links().size() == 1, "the reasons change nothing in the table");
    std::vector<std::string> none = {"stale"};
    MountAliases::build(mounts, {}, &none);
    CHECK(none.empty(), "no links: no reasons (the vector is reset)");

    g_context = "link-summary";
    const std::string arrow = "\xE2\x86\x92 ";
    ShareLinkSummary s = summarizeShareLink(linkRead(kLink, "/Volumes/music-1"), mounts);
    CHECK(s.used && s.onShare && s.text == arrow + "/Volumes/music-1 (share music)",
          "on the share: the raw target and the share name");
    s = summarizeShareLink(linkRead(kLink, "/Volumes/music-1/sub/dir"), mounts);
    CHECK(s.used && s.onShare && s.text == arrow + "/Volumes/music-1/sub/dir (share music)",
          "a folder inside the share: the share name alone");
    s = summarizeShareLink(linkRead(kLink, "/Users/x/mirror/music"), mounts);
    CHECK(s.used && !s.onShare && s.text == arrow + "/Users/x/mirror/music (not on a share)", "a mirror");
    s = summarizeShareLink(linkRead(kLink, "/Volumes/music"), withSystem({}));
    CHECK(s.used && !s.onShare && s.text == arrow + "/Volumes/music (not on a share)",
          "the unmounted placeholder: used, not on a share");
    s = summarizeShareLink(linkRead("/Users/x/plain", "", ShareLinkStatus::NotLink), mounts);
    CHECK(!s.used && s.text == "not a symlink", "not a symlink");
    s = summarizeShareLink(linkRead("/Users/x/none", "", ShareLinkStatus::Missing), mounts);
    CHECK(!s.used && s.text == "missing", "missing");
    s = summarizeShareLink(linkRead("/Users/x/loop", "", ShareLinkStatus::Loop), mounts);
    CHECK(!s.used && s.text == "a symlink loop", "a loop");
    s = summarizeShareLink(linkRead("/Users/x/NAS/music", "", ShareLinkStatus::OnNetwork), mounts);
    CHECK(!s.used && s.text == "on a network volume: ignored", "on a network volume");
    s = summarizeShareLink(linkRead("/Volumes/music", "/Users/x/mirror"), mounts);
    CHECK(!s.used && s.text == "a mount point: ignored", "read as a link, rejected by the table");
    s = summarizeShareLink(linkRead(kLink, "/Volumes/music"), {});
    CHECK(!s.used && s.text == "on a network volume: ignored", "no mount table: nothing is known to be local");
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
        testShareLinkOnShare();
        testShareLinkOffShare();
        testShareLinkMatching();
        testShareLinkRootAndView();
        testShareLinkCensus();
        testShareLinkChanges();
        testShareLinkRejected();
        testShareLinkSummary();
    }
    TEST_MAIN_END();
}
