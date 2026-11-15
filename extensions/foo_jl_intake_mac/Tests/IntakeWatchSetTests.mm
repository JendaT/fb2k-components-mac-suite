//
//  IntakeWatchSetTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeWatchSet: the watch_folders setting, lexical
//  cleaning, the candidates (settings, income folders, parents of roots),
//  the local/network decision from a synthetic mount table (NFD mount
//  points, stacked mounts, the Data volume's firmlinked autofs maps), the
//  component-wise resolution (a recording link reader over a fake
//  filesystem proves nothing under a network mount is ever examined, also
//  through a local symlink into a share; relative links, "..", loops), the
//  reduction to top-level ancestors, and mapping event directories back to
//  match keys (resolved spellings, a second mount point of a share, NFD,
//  case of the mount point). One test resolves a real temp directory
//  (/var -> /private/var) and compares with realpath(3). Synthetic names
//  only.
//
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeMountAliases.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeMountAliases.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeWatchSet.h"
#include "TestHarness.h"

#include <climits>
#include <cstdlib>
#include <map>
#include <set>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

using namespace intake;

namespace {

const MountEntry kRoot{"/", "/dev/disk3s1s1", "apfs", true};
const MountEntry kData{"/System/Volumes/Data", "/dev/disk3s5", "apfs", true};
const MountEntry kLan{"/Volumes/fixture-share", "//user@host-lan/fixture-share", "smbfs", false};
const MountEntry kVpn{"/Volumes/fixture-share-1", "//user@host-vpn/fixture-share", "smbfs", false};
const MountEntry kNfs{"/Volumes/fixture-nfs", "host-a:/export", "nfs", false};
// A network type reported with MNT_LOCAL set must still count as network.
const MountEntry kOddSmb{"/Volumes/odd", "//host-b/odd", "smbfs", true};
// A local type without MNT_LOCAL (e.g. a FUSE mount) counts as network.
const MountEntry kNotLocal{"/Volumes/fuse", "fuse-a", "apfs", false};

// A fake filesystem: `links` are symlinks (path -> link text), `missing`
// paths do not exist (nor anything under them); every other path exists
// and is no link. Every lstat is recorded.
struct RecordingResolver {
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
    bool called(const std::string &path) const {
        for (const std::string &c : calls) {
            if (c == path) return true;
        }
        return false;
    }
    bool calledUnder(const std::string &prefix) const {
        for (const std::string &c : calls) {
            if (c.rfind(prefix, 0) == 0) return true;
        }
        return false;
    }
};

std::string key(const std::string &path) {
    std::string out;
    normalizePath(path, out);
    return out;
}

} // anonymous namespace

static void testParseWatchFolders() {
    g_context = "parse-watch-folders";
    WatchFolderList l = parseWatchFolders("/fixture/a\n  /fixture/b  \r\n\n\trelative/c\r/fixture/a\n~/d\n/fixture/e");
    CHECK(l.folders.size() == 3 && l.folders[0] == "/fixture/a" && l.folders[1] == "/fixture/b" &&
              l.folders[2] == "/fixture/e",
          "absolute lines, trimmed, in order, duplicates once; \\n, \\r\\n and \\r all split");
    CHECK(l.ignored.size() == 2 && l.ignored[0] == "relative/c" && l.ignored[1] == "~/d",
          "relative lines and ~ are reported as ignored");
    WatchFolderList empty = parseWatchFolders("");
    CHECK(empty.folders.empty() && empty.ignored.empty(), "the default (empty) watches nothing extra");
    CHECK(parseWatchFolders(" \n\t\n").folders.empty(), "blank lines only");
}

static void testLexical() {
    g_context = "lexical";
    CHECK(lexicalAbsolutePath("/a//b/./c/") == "/a/b/c", "// . and a trailing slash");
    CHECK(lexicalAbsolutePath("/a/b/../c") == "/a/c" && lexicalAbsolutePath("/../a") == "/a", "..");
    CHECK(lexicalAbsolutePath("/") == "/" && lexicalAbsolutePath("//") == "/", "the root");
    CHECK(lexicalAbsolutePath("a/b").empty() && lexicalAbsolutePath("").empty(), "relative and empty");
    CHECK(lexicalAbsolutePath("/Fixtu\xCC\x81re") == "/Fixtu\xCC\x81re", "bytes kept (no NFC)");
    CHECK(parentDirectory("/a/b") == "/a" && parentDirectory("/a") == "/" && parentDirectory("/").empty() &&
              parentDirectory("a/b").empty(),
          "parentDirectory");
}

static void testCandidates() {
    g_context = "candidates";
    std::vector<std::string> c = watchCandidates(
        {"/fixture/extra/", "relative", "/"},
        {"/fixture/income/dump", "/fixture/income/shop", "/fixture/income/offline"},
        {"/fixture/income/dump/Fixture Artist - New Album", "/fixture/income/shop/Loose Tracks",
         "/fixture/income/dump/Fixture Artist - Close Call", "/Album At Root"});
    CHECK(c.size() == 4, "settings, then income, then root parents, each once");
    CHECK(c.size() == 4 && c[0] == "/fixture/extra" && c[1] == "/fixture/income/dump" &&
              c[2] == "/fixture/income/shop" && c[3] == "/fixture/income/offline",
          "a root's parent already listed adds nothing; '/' (setting or a root's parent) never");
}

static void testMounts() {
    g_context = "mounts";
    const std::vector<MountEntry> mounts = {kRoot, kData, kLan, kVpn, kNfs, kOddSmb, kNotLocal};
    CHECK(!isNetworkMount(kRoot) && isNetworkMount(kLan) && isNetworkMount(kNfs), "apfs local, smbfs and nfs not");
    CHECK(isNetworkMount(kOddSmb) && isNetworkMount(kNotLocal), "type or missing MNT_LOCAL is enough");
    const MountEntry *m = mountHolding("/Volumes/fixture-share-1/income", mounts);
    CHECK(m && m->mountPoint == "/Volumes/fixture-share-1", "the longest mount point wins (-1 over the plain name)");
    m = mountHolding("/Volumes/FIXTURE-SHARE/income", mounts);
    CHECK(m && m->mountPoint == "/Volumes/fixture-share", "mount points match ignoring ASCII case");
    m = mountHolding("/Volumes/fixture-shared/income", mounts);
    CHECK(m && m->mountPoint == "/", "a name that only starts like a mount point is not under it");
    CHECK(mayResolvePath("/Users/fixture/Music/income", mounts), "a local path may be resolved");
    CHECK(!mayResolvePath("/Volumes/fixture-share/income", mounts) &&
              !mayResolvePath("/Volumes/Fixture-Share-1/income/dump", mounts) &&
              !mayResolvePath("/Volumes/fixture-nfs/x", mounts),
          "paths on network mounts are never resolved");
    CHECK(!mayResolvePath("/Users/fixture", {}), "an empty mount table resolves nothing");
    CHECK(mayResolvePath("/Volumes/fixture-share/income", {kRoot}),
          "an unmounted share's path lies on the local disk: resolving it cannot reach a server");

    g_context = "mounts-nfc";
    // The share mounted under an NFD name; the CLI spells the path NFC.
    const MountEntry nfd{"/Volumes/Mu\xCC\x81sica", "//user@host-lan/musica", "smbfs", false};
    const std::vector<MountEntry> nfdMounts = {kRoot, nfd};  // mountHolding points into it
    m = mountHolding("/Volumes/M\xC3\xBAsica/income/dump", nfdMounts);
    CHECK(m && m->mountPoint == nfd.mountPoint, "an NFD mount point holds the NFC spelling of a path under it");
    CHECK(!mayResolvePath("/Volumes/M\xC3\xBAsica/income/dump", {kRoot, nfd}), "so that path is never resolved");
    const MountEntry nfc{"/Volumes/M\xC3\xBAsica", "//user@host-lan/musica", "smbfs", false};
    CHECK(!mayResolvePath("/Volumes/Mu\xCC\x81sica/income", {kRoot, nfc}), "and the other way round");

    g_context = "mounts-stacked";
    // Two mounts on one point: the later one is on top (MountAliases agrees).
    const MountEntry under{"/Volumes/fixture-stack", "/dev/disk9s1", "apfs", true};
    const MountEntry over{"/Volumes/fixture-stack", "//user@host-lan/fixture-stack", "smbfs", false};
    CHECK(!mayResolvePath("/Volumes/fixture-stack/income", {kRoot, under, over}), "a share mounted over a disk");
    CHECK(mayResolvePath("/Volumes/fixture-stack/income", {kRoot, over, under}), "a disk mounted over a share");

    g_context = "mounts-firmlink";
    const MountEntry home{"/System/Volumes/Data/home", "map auto_home", "autofs", true};
    const std::vector<MountEntry> homeMounts = {kRoot, kData, home};
    m = mountHolding("/home/fixture/income", homeMounts);
    CHECK(m && m->fsType == "autofs", "the autofs map on the Data volume holds the firmlinked /home");
    CHECK(!mayResolvePath("/home/fixture/income", {kRoot, kData, home}), "so /home paths are never resolved");
    CHECK(!mayResolvePath("/System/Volumes/Data/home/fixture", {kRoot, kData, home}), "nor the full spelling");
    CHECK(mayResolvePath("/homework/fixture", {kRoot, kData, home}), "a name that only starts like it is local");
    CHECK(mayResolvePath("/Users/fixture", {kRoot, kData, home}), "the Data volume itself maps nothing");
}

static void testResolveLocal() {
    g_context = "resolve-local";
    const std::vector<MountEntry> mounts = {kRoot, kLan};
    RecordingResolver r;
    r.links["/tmp"] = "private/tmp";                          // relative, as on macOS
    r.links["/Users/fixture/NAS"] = "/Volumes/fixture-share/income";  // a local link into the share
    r.links["/Users/fixture/up"] = "../fixture/real";         // ".." from the link's folder
    r.links["/Users/fixture/loop"] = "/Users/fixture/loop";
    r.missing.insert("/Users/fixture/later");
    bool touched = false;

    CHECK(resolveLocalPath("/tmp/fixture-watch", mounts, r.fn(), &touched) == "/private/tmp/fixture-watch" && touched,
          "a relative link is read from its folder");
    CHECK(resolveLocalPath("/Users/fixture/NAS/dump", mounts, r.fn()) == "/Volumes/fixture-share/income/dump",
          "a local link into the share is followed as text");
    CHECK(!r.calledUnder("/Volumes/fixture-share"), "and nothing on the share is examined");
    CHECK(r.called("/Volumes"), "only the local components of the link text are");
    CHECK(resolveLocalPath("/Users/fixture/up/x", mounts, r.fn()) == "/Users/fixture/real/x", "'..' in a link");
    CHECK(resolveLocalPath("/Users/fixture/later/a/b", mounts, r.fn()) == "/Users/fixture/later/a/b" &&
              !r.called("/Users/fixture/later/a"),
          "a missing component ends the walk; the rest kept as written");
    CHECK(resolveLocalPath("/Users/fixture/loop/x", mounts, r.fn()) == "/Users/fixture/loop/x",
          "a link loop keeps the path as written");
    r.calls.clear();
    CHECK(resolveLocalPath("/Volumes/fixture-share/income", mounts, r.fn(), &touched) ==
                  "/Volumes/fixture-share/income" &&
              r.calls.size() == 1 && r.calls[0] == "/Volumes",
          "the walk stops at the share's mount point (never lstat'd)");
    CHECK(resolveLocalPath("/x", mounts, LinkReader(), &touched) == "/x" && !touched, "no reader: as written");

    g_context = "resolve-nested";
    // A local disk image mounted inside the share: the path's own mount is
    // local, but its parents are on the share.
    const MountEntry dmg{"/Volumes/fixture-share/images/disk", "/dev/disk8s1", "apfs", true};
    RecordingResolver n;
    WatchSet ws = WatchSet::build({"/Volumes/fixture-share/images/disk/income"}, {kRoot, kLan, dmg}, n.fn());
    CHECK(!n.calledUnder("/Volumes/fixture-share"), "no lstat on the share's components above the image");
    CHECK(ws.streamPaths().size() == 1 && ws.streamPaths()[0] == "/Volumes/fixture-share/images/disk/income",
          "kept as written");
}

static void testBuild() {
    g_context = "build";
    const std::vector<MountEntry> mounts = {kRoot, kLan, kVpn};
    RecordingResolver r;
    r.links["/tmp"] = "private/tmp";
    r.links["/link"] = "/";
    r.missing.insert("/private/tmp/fixture-watch/new");
    std::vector<std::string> candidates = {
        "/tmp/fixture-watch/extra",              // local, a symlinked prefix
        "/tmp/fixture-watch/new/later",          // local, does not exist yet
        "/Volumes/fixture-share/income/dump",    // network
        "/Volumes/fixture-share/income/dump/Fixture Artist - New Album",  // under the line above
        "/Volumes/fixture-share-1/income/shop",  // network, the other mount point
        "/Users/fixture/income/dump",            // local
        "/Users/fixture/income/dump/sub",        // local, nested
        "/link",                                 // resolves to "/": dropped
    };
    WatchSet ws = WatchSet::build(candidates, mounts, r.fn());
    CHECK(!r.calledUnder("/Volumes/"), "nothing under a network mount is ever examined");
    CHECK(r.called("/private/tmp/fixture-watch/extra") && r.called("/Users/fixture/income/dump"),
          "local paths are resolved");
    CHECK(r.called("/private/tmp/fixture-watch/new") && !r.called("/private/tmp/fixture-watch/new/later"),
          "a missing local folder resolves its deepest existing ancestor");
    const std::vector<std::string> &paths = ws.streamPaths();
    CHECK(paths.size() == 5, "five top-level folders");
    CHECK(paths.size() == 5 && paths[0] == "/Users/fixture/income/dump" &&
              paths[1] == "/Volumes/fixture-share-1/income/shop" && paths[2] == "/Volumes/fixture-share/income/dump" &&
              paths[3] == "/private/tmp/fixture-watch/extra" && paths[4] == "/private/tmp/fixture-watch/new/later",
          "sorted; resolved spellings; nested folders and '/' dropped");
    CHECK(ws.entries().size() == 7, "every candidate but '/' kept for mapping");

    g_context = "build-same";
    RecordingResolver r2 = r;
    WatchSet again = WatchSet::build(candidates, mounts, r2.fn());
    CHECK(again.streamPaths() == ws.streamPaths(), "the same inputs give an equal set (no stream restart)");
    WatchSet none = WatchSet::build(candidates, mounts, LinkReader());
    CHECK(none.streamPaths().size() == 6 && none.streamPaths().back() == "/tmp/fixture-watch/new/later",
          "with no resolver, paths stay as written");
    CHECK(WatchSet::build({}, mounts, r.fn()).empty(), "no candidates: no stream");
}

static void testMapping() {
    g_context = "mapping";
    const std::vector<MountEntry> mounts = {kRoot, kLan, kVpn};
    std::shared_ptr<const MountAliases> aliases = MountAliases::build(mounts);
    RecordingResolver r;
    r.links["/tmp"] = "private/tmp";
    WatchSet ws = WatchSet::build({"/tmp/fixture-watch/income", "/Volumes/fixture-share/income/dump"}, mounts, r.fn());

    std::vector<std::string> keys;
    CHECK(ws.mapEventDirectory("/private/tmp/fixture-watch/income/Fixture Artist - New Album", *aliases, keys),
          "an event under a resolved folder maps");
    CHECK(keys.size() == 1 && keys[0] == "/tmp/fixture-watch/income/Fixture Artist - New Album",
          "onto the spelling the CLI reported (the root's key)");

    keys.clear();
    const std::string rootKey = aliases->rewritten(key("/Volumes/fixture-share/income/dump/Fixture Artist - Close Call"));
    CHECK(ws.mapEventDirectory("/Volumes/fixture-share/income/dump/Fixture Artist - Close Call", *aliases, keys) &&
              keys.size() == 1 && keys[0] == rootKey,
          "an event on the share maps to the alias key the root has");
    CHECK(rootKey == "/smbfs:fixture-share/income/dump/Fixture Artist - Close Call", "which names the share");

    keys.clear();
    CHECK(ws.mapEventDirectory("/Volumes/FIXTURE-SHARE/income/dump/Fixture Artist - Close Call", *aliases, keys) &&
              keys.size() == 1 && keys[0] == rootKey,
          "the mount point's case does not matter");

    keys.clear();
    const std::string nfd = "/private/tmp/fixture-watch/income/Fixtu\xCC\x81re Artist - Album";
    CHECK(ws.mapEventDirectory(nfd, *aliases, keys) && keys.size() == 1 &&
              keys[0] == key("/tmp/fixture-watch/income/Fixt\xC3\xBAre Artist - Album"),
          "an NFD event spelling gives the NFC key");

    keys.clear();
    CHECK(!ws.mapEventDirectory("/private/tmp/elsewhere/Album", *aliases, keys) && keys.empty(),
          "a directory under no watched folder maps to nothing (the caller then lists everything)");
    CHECK(!ws.mapEventDirectory("relative/dir", *aliases, keys), "a relative path maps to nothing");

    g_context = "mapping-second-mount";
    // The stream watches the CLI's mount point; a root reported under the
    // other mount point of the share still gets the event's key.
    WatchSet vpn = WatchSet::build({"/Volumes/fixture-share-1/income/shop"}, mounts, r.fn());
    keys.clear();
    CHECK(vpn.mapEventDirectory("/Volumes/fixture-share-1/income/shop/Loose Tracks", *aliases, keys) &&
              keys.size() == 1 &&
              keys[0] == aliases->rewritten(key("/Volumes/fixture-share/income/shop/Loose Tracks")),
          "both mount points of one share give one key");

    g_context = "mapping-overlap";
    WatchSet nested = WatchSet::build({"/Volumes/fixture-share/income", "/Volumes/fixture-share/income/dump"},
                                      mounts, r.fn());
    keys.clear();
    CHECK(nested.streamPaths().size() == 1, "nested candidates: one stream path");
    CHECK(nested.mapEventDirectory("/Volumes/fixture-share/income/dump/A", *aliases, keys) && keys.size() == 1,
          "an event under both entries gives its key once");
}

static void testRealTempDirectory() {
    g_context = "real-temp";
    std::string base = NSTemporaryDirectory().UTF8String;
    if (!base.empty() && base.back() == '/') base.pop_back();
    std::string tmpl = base + "/intake-watchset-XXXXXX";
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    if (!mkdtemp(buf.data())) {
        CHECK(false, "mkdtemp");
        return;
    }
    const std::string dir = buf.data();
    const std::string income = dir + "/income";
    mkdir(income.c_str(), 0755);

    WatchSet ws = WatchSet::build({income, dir + "/not-yet"}, {kRoot}, &posixLinkReader);
    char buffer[PATH_MAX];
    const bool ok = ::realpath(income.c_str(), buffer) != nullptr;
    const std::string real = ok ? buffer : income;
    CHECK(ok, "the temp folder resolves");
    CHECK(ws.streamPaths().size() == 2, "two stream paths");
    CHECK(ws.entries().size() == 2 && ws.entries()[0].fsPath == real && ws.entries()[0].resolved,
          "the stream gets realpath's spelling (lstat/readlink one component at a time)");
    CHECK(ws.entries().size() == 2 && ws.entries()[1].fsPath == parentDirectory(real) + "/not-yet",
          "a missing folder: its parent resolved, the rest kept");
    std::vector<std::string> keys;
    CHECK(ws.mapEventDirectory(real + "/Fixture Artist - New Album", *MountAliases::none(), keys) &&
              keys.size() == 1 && keys[0] == key(income + "/Fixture Artist - New Album"),
          "an event in realpath's spelling maps back to the original spelling");

    rmdir(income.c_str());
    rmdir(dir.c_str());
}

int main(void) {
    @autoreleasepool {
        testParseWatchFolders();
        testLexical();
        testCandidates();
        testMounts();
        testResolveLocal();
        testBuild();
        testMapping();
        testRealTempDirectory();
    }
    TEST_MAIN_END();
}
