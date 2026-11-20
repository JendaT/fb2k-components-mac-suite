//
//  IntakeSwapPlannerTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeSwapPlanner (B9): the sidecar files[] parse
//  (quality_shadow, unsafe paths), the sidecar read (named first, then
//  .intake.json, the id check, the retry, a share that is gone), the prefix
//  pair (whole components, trailing slash, empty or unusable pairs, a target
//  outside the pair), row planning for whole-folder and virtual roots
//  (NFC/NFD, smbfs alias keys, shadows, files not in files[]), the mount
//  alias paths for I/O, the Unicode form switch, the canonical volume
//  prefix, the choice of the mount foobar2000 gets (the playlist's volume
//  forms first, then the round trip) and the console line. B11 share
//  links: the links a playlist's items use, the link form (a link to
//  either mount of the share, a mirror, a link the playlist does not use,
//  a mixed playlist, NFD bytes, a configured trailing slash, a candidate
//  spelled through the link), a link spelled in another letter case, the
//  reuse of an item's existing spelling, Swap's decision per row (the
//  volume-form rule, a skip, the link form) and the Delete census
//  decision. Synthetic paths only.
//
// TEST_DEPS: src/Core/IntakeSidecarMembers.mm src/Core/IntakeEnvelope.mm src/Core/IntakePath.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm src/Core/IntakeMountAliases.mm src/Core/IntakeLog.mm
// TEST_DEPS: src/Core/IntakeErrorMap.mm
// TEST_DEPS: src/Core/IntakeWatchSet.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeMountAliases.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeSidecarMembers.h"
#include "../src/Core/IntakeStatusModel.h"
#include "../src/Core/IntakeSwapPlanner.h"
#include "../src/Core/IntakeWatchSet.h"
#include "TestHarness.h"

#include <cerrno>
#include <map>
#include <string>
#include <vector>

using namespace intake;

namespace {

// "é" composed (NFC) and decomposed (NFD).
const std::string kNfc = "Caf\xC3\xA9";
const std::string kNfd = "Cafe\xCC\x81";

std::string sidecar(const std::string &id, const std::string &files, bool isVirtual = false) {
    return "{\"schema\":1,\"id\":\"" + id + "\",\"virtual\":" + (isVirtual ? "true" : "false") +
           ",\"files\":[" + files + "],\"status\":\"placed\"}";
}

std::string file(const std::string &path, bool shadow = false) {
    return "{\"path\":\"" + path + "\",\"audio_hash\":\"pcmsha1:00\"" + (shadow ? ",\"quality_shadow\":true" : "") + "}";
}

class FakeAccess : public SidecarFileAccess {
public:
    std::map<std::string, std::string> files;
    std::map<std::string, int> errors;       // path -> errno on read
    std::map<std::string, int> failFirst;    // path -> reads that answer half-written JSON first
    std::vector<std::string> reads;

    bool listDirectory(const std::string &, std::vector<std::string> &names, int &error) override {
        names.clear();
        error = ENOTSUP;
        return false;
    }
    bool readFile(const std::string &path, std::string &contents, int &error) override {
        reads.push_back(path);
        contents.clear();
        error = 0;
        auto e = errors.find(path);
        if (e != errors.end()) {
            error = e->second;
            return false;
        }
        auto garbage = failFirst.find(path);
        if (garbage != failFirst.end() && garbage->second > 0) {
            garbage->second--;
            contents = "{\"files\":[";  // half written
            return true;
        }
        auto f = files.find(path);
        if (f == files.end()) {
            error = ENOENT;
            return false;
        }
        contents = f->second;
        return true;
    }
};

IntakeRecord placedRecord(const std::string &id, const std::string &rootPath, const std::string &target) {
    IntakeRecord r;
    r.id = id;
    r.rootPath = rootPath;
    normalizePath(rootPath, r.rootKey);
    r.status = IntakeStatus::Placed;
    r.hasPlaced = true;
    r.placedVerified = true;
    r.placedTargetPath = target;
    return r;
}

PlacedRootFiles root(const std::string &rootKey, const std::string &target, std::vector<SidecarFile> files) {
    PlacedRootFiles r;
    r.id = "itk_00000012";
    r.rootPath = rootKey;
    r.rootKey = rootKey;
    r.targetPath = target;
    r.files = std::move(files);
    return r;
}

std::string key(const std::string &path) {
    std::string out;
    normalizePath(path, out);
    return out;
}

} // namespace

static void testParse() {
    g_context = "parse";
    std::vector<SidecarFile> files;
    std::string docId;
    bool isVirtual = true;
    CHECK(parseSidecarFiles(sidecar("itk_00000012", file("01 - One.wav") + "," + file("CD2/01 - One.flac", true)),
                            files, &docId, &isVirtual),
          "a whole-folder sidecar parses");
    CHECK(files.size() == 2 && files[0].path == "01 - One.wav" && !files[0].shadow, "the first entry");
    CHECK(files[1].path == "CD2/01 - One.flac" && files[1].shadow, "quality_shadow true marks a shadow");
    CHECK(docId == "itk_00000012" && !isVirtual, "the id; virtual false");

    CHECK(parseSidecarFiles(sidecar("itk_00000016", file("a.wav"), true), files, nullptr, &isVirtual) && isVirtual,
          "virtual true");
    CHECK(parseSidecarFiles("{\"id\":\"x\",\"files\":[{\"path\":\"a.wav\",\"quality_shadow\":1}]}", files) &&
              !files[0].shadow,
          "only the JSON boolean true is a shadow (1 is not)");
    CHECK(parseSidecarFiles("{\"files\":[]}", files) && files.empty(), "an empty files[] is fine (an ISO root)");
    CHECK(!parseSidecarFiles("{\"files\":[{\"path\":\"../x.wav\"}]}", files) && files.empty(),
          "an unsafe path fails the whole sidecar");
    CHECK(!parseSidecarFiles("{\"files\":[{\"path\":\"/abs.wav\"}]}", files), "an absolute path fails");
    CHECK(!parseSidecarFiles("{\"files\":[{\"name\":\"a.wav\"}]}", files), "an entry without a path fails");
    CHECK(!parseSidecarFiles("{\"files\":\"a.wav\"}", files), "files must be an array");
    CHECK(!parseSidecarFiles("[]", files) && !parseSidecarFiles("", files) && !parseSidecarFiles("{\"files\":[", files),
          "not an object, empty, half written");
}

static void testRead() {
    g_context = "read";
    const std::string dir = "/income/dump/Fixture Artist - Placed Album";
    const IntakeRecord rec = placedRecord("itk_00000012", dir, "/library/A/Album");
    FakeAccess fs;
    fs.files[dir + "/.intake.json"] = sidecar("itk_00000012", file("01.wav") + "," + file("02.wav", true));
    PlacedRootFiles out;
    std::string error;
    int err = -1;
    CHECK(readPlacedRootFiles(rec, fs, out, error, &err), "a whole-folder root reads its .intake.json");
    CHECK(fs.reads.size() == 2 && fs.reads[0] == dir + "/.intake.itk_00000012.json" && fs.reads[1] == dir + "/.intake.json",
          "the named sidecar is tried first, then .intake.json");
    CHECK(out.id == "itk_00000012" && out.rootPath == dir && out.targetPath == "/library/A/Album" &&
              out.rootKey == rec.rootKey && out.wholeFolder && out.files.size() == 2 && err == 0,
          "the record's paths and the files");

    FakeAccess named;
    const std::string loose = "/income/shop/Loose Tracks";
    named.files[loose + "/.intake.itk_00000016.json"] = sidecar("itk_00000016", file("B - One.wav"), true);
    named.files[loose + "/.intake.json"] = sidecar("itk_00000099", file("other.wav"));
    PlacedRootFiles v;
    CHECK(readPlacedRootFiles(placedRecord("itk_00000016", loose, "/library/B"), named, v, error) && !v.wholeFolder &&
              v.files.size() == 1 && named.reads.size() == 1,
          "a virtual root: its named sidecar, .intake.json is never read");

    FakeAccess wrongId;
    wrongId.files[dir + "/.intake.json"] = sidecar("itk_00000099", file("01.wav"));
    CHECK(!readPlacedRootFiles(rec, wrongId, out, error) && error.find("belongs to itk_00000099") != std::string::npos,
          "a sidecar of another root is refused");

    FakeAccess retry;
    retry.files[dir + "/.intake.json"] = sidecar("itk_00000012", file("01.wav"));
    retry.failFirst[dir + "/.intake.json"] = 1;
    CHECK(readPlacedRootFiles(rec, retry, out, error) && retry.reads.size() == 3,
          "a half-written sidecar is read once more");
    retry.failFirst[dir + "/.intake.json"] = 2;
    retry.reads.clear();
    CHECK(!readPlacedRootFiles(rec, retry, out, error, &err) && err == 0 && error.find("unusable sidecar") == 0,
          "twice half written: unusable, no errno");

    FakeAccess gone;
    gone.errors[dir + "/.intake.itk_00000012.json"] = ETIMEDOUT;
    CHECK(!readPlacedRootFiles(rec, gone, out, error, &err) && err == ETIMEDOUT && gone.reads.size() == 1 &&
              isShareUnreachableError(err),
          "a share that is gone: one read, the errno handed back, no fallback");

    FakeAccess none;
    CHECK(!readPlacedRootFiles(rec, none, out, error) && error.find("no sidecar for itk_00000012") == 0,
          "no sidecar at all");
}

static void testPrefix() {
    g_context = "prefix";
    std::string out;
    const LibraryPrefix pair = makeLibraryPrefix("/nas/music", "/Volumes/music");
    CHECK(pair.active(), "a usable pair");
    CHECK(rewriteLibraryPrefix(pair, "/nas/music/music.hq/A/x.wav", out) == PrefixRewrite::Rewritten &&
              out == "/Volumes/music/music.hq/A/x.wav",
          "the prefix is replaced");
    CHECK(rewriteLibraryPrefix(pair, "/nas/music", out) == PrefixRewrite::Rewritten && out == "/Volumes/music",
          "the prefix itself");
    CHECK(rewriteLibraryPrefix(pair, "/nas/music2/A/x.wav", out) == PrefixRewrite::OutsidePair &&
              out == "/nas/music2/A/x.wav",
          "whole components only: /nas/music does not match /nas/music2; the path is kept");
    CHECK(rewriteLibraryPrefix(pair, "/Volumes/music/A/x.wav", out) == PrefixRewrite::OutsidePair &&
              out == "/Volumes/music/A/x.wav",
          "a target outside the pair (already a Mac path) is used as is");
    CHECK(rewriteLibraryPrefix(pair, "/NAS/music/A/x.wav", out) == PrefixRewrite::OutsidePair,
          "case-sensitive (NAS paths are)");

    const LibraryPrefix slashes = makeLibraryPrefix("  /nas/music/ ", "/Volumes/music//");
    CHECK(slashes.active() && slashes.from == "/nas/music" && slashes.to == "/Volumes/music",
          "trailing slashes and spaces are cleaned off the pair");
    CHECK(rewriteLibraryPrefix(slashes, "/nas/music/A/x.wav", out) == PrefixRewrite::Rewritten &&
              out == "/Volumes/music/A/x.wav",
          "and it still maps");

    CHECK(!makeLibraryPrefix("", "").active() &&
              rewriteLibraryPrefix(makeLibraryPrefix("", ""), "/nas/music/x.wav", out) == PrefixRewrite::NoMapping &&
              out == "/nas/music/x.wav",
          "an empty pair rewrites nothing");
    CHECK(rewriteLibraryPrefix(makeLibraryPrefix("/nas/music", ""), "/nas/music/x.wav", out) ==
                  PrefixRewrite::NoMapping &&
              out == "/nas/music/x.wav",
          "a half-filled pair is not usable");
    CHECK(rewriteLibraryPrefix(makeLibraryPrefix("nas/music", "/Volumes/music"), "/nas/music/x.wav", out) ==
              PrefixRewrite::NoMapping,
          "a relative prefix is not usable");
    CHECK(rewriteLibraryPrefix(makeLibraryPrefix("/", "/Volumes/music"), "/nas/x.wav", out) == PrefixRewrite::NoMapping,
          "the root folder is not usable");
    CHECK(makeLibraryPrefix("/a", "/b") == makeLibraryPrefix("/a/", "/b") &&
              makeLibraryPrefix("/a", "/b") != makeLibraryPrefix("/a", "/c"),
          "equality compares the cleaned pair");
}

static void testPlanWholeFolder() {
    g_context = "plan-whole-folder";
    const std::string dir = "/Volumes/income/dump/Fixture Artist - Placed Album";
    PlacedRootFiles r = root(dir, "/nas/music/music.hq/Test Collection A/Fixture Artist/Placed Album",
                             {{"01 - One.wav", false}, {"CD2/01 - One.wav", false}, {"02 - Two.wav", true}});
    const LibraryPrefix pair = makeLibraryPrefix("/nas/music", "/Volumes/music");

    SwapPlan p = planSwap(r, key(dir + "/01 - One.wav"), pair);
    CHECK(p.skip == SwapSkip::None && p.relativePath == "01 - One.wav" &&
              p.libraryPath == "/Volumes/music/music.hq/Test Collection A/Fixture Artist/Placed Album/01 - One.wav" &&
              p.rewrite == PrefixRewrite::Rewritten,
          "target_path + / + files[].path, then the prefix pair");
    p = planSwap(r, key(dir + "/CD2/01 - One.wav"), pair);
    CHECK(p.skip == SwapSkip::None &&
              p.libraryPath == "/Volumes/music/music.hq/Test Collection A/Fixture Artist/Placed Album/CD2/01 - One.wav",
          "disc subfolders are kept (doc 03 layout)");
    CHECK(planSwap(r, key(dir + "/02 - Two.wav"), pair).skip == SwapSkip::Shadow, "a shadow is skipped");
    CHECK(planSwap(r, key(dir + "/cover.jpg"), pair).skip == SwapSkip::NotInSidecar,
          "a file of the folder that files[] does not list is skipped");
    CHECK(planSwap(r, key("/Volumes/income/dump/Other/01 - One.wav"), pair).skip == SwapSkip::NotInSidecar,
          "a path outside the root");
    p = planSwap(r, key(dir + "/01 - One.wav"), makeLibraryPrefix("", ""));
    CHECK(p.skip == SwapSkip::None && p.rewrite == PrefixRewrite::NoMapping &&
              p.libraryPath == "/nas/music/music.hq/Test Collection A/Fixture Artist/Placed Album/01 - One.wav",
          "no pair: the target path as the CLI reports it");
    PlacedRootFiles trailing = r;
    trailing.targetPath = "/nas/music/music.hq/A/Album/";
    CHECK(planSwap(trailing, key(dir + "/01 - One.wav"), pair).libraryPath ==
              "/Volumes/music/music.hq/A/Album/01 - One.wav",
          "a trailing slash on the target path");
    PlacedRootFiles noTarget = r;
    noTarget.targetPath.clear();
    CHECK(planSwap(noTarget, key(dir + "/01 - One.wav"), pair).skip == SwapSkip::NoTarget, "no target path");
}

static void testPlanVirtualAndKeys() {
    g_context = "plan-virtual-keys";
    // Two virtual roots in one folder: each matches only its own files[].
    const std::string loose = "/income/shop/Loose Tracks";
    PlacedRootFiles b = root(loose, "/library/B/Loose", {{"Fixture Artist B - Loose One.wav", false}});
    PlacedRootFiles c = root(loose, "/library/C/Other", {{"Fixture Artist C - Other One.wav", false}});
    CHECK(planSwap(b, key(loose + "/Fixture Artist B - Loose One.wav"), LibraryPrefix()).libraryPath ==
              "/library/B/Loose/Fixture Artist B - Loose One.wav",
          "a virtual root's member: its own target");
    CHECK(planSwap(c, key(loose + "/Fixture Artist B - Loose One.wav"), LibraryPrefix()).skip == SwapSkip::NotInSidecar,
          "the other virtual root in the folder does not claim it");

    // NFC/NFD: the row is NFD (SMB), the sidecar NFC; the library path keeps
    // the sidecar's spelling.
    PlacedRootFiles nfc = root("/income/dump/" + kNfc, "/library/" + kNfc, {{kNfc + " 01.wav", false}});
    SwapPlan p = planSwap(nfc, key("/income/dump/" + kNfd + "/" + kNfd + " 01.wav"), LibraryPrefix());
    CHECK(p.skip == SwapSkip::None && p.libraryPath == "/library/" + kNfc + "/" + kNfc + " 01.wav",
          "an NFD row matches an NFC sidecar entry");
    PlacedRootFiles nfd = root("/income/dump/" + kNfd, "/library/x", {{kNfd + " 01.wav", false}});
    CHECK(planSwap(nfd, key("/income/dump/" + kNfc + "/" + kNfc + " 01.wav"), LibraryPrefix()).skip == SwapSkip::None,
          "and an NFC row an NFD sidecar");

    // smbfs alias keys: the root reported under /Volumes/share, the row on
    // /Volumes/share-1 (both rewritten to /smbfs:share/...).
    std::vector<MountEntry> mounts = {{"/", "/dev/disk1", "apfs", true},
                                      {"/Volumes/share", "//user@lan-host/share", "smbfs", false},
                                      {"/Volumes/share-1", "//user@vpn-host/share", "smbfs", false}};
    auto aliases = MountAliases::build(mounts);
    PlacedRootFiles aliased = root(aliases->rewritten(key("/Volumes/share/income/Album")), "/library/A/Album",
                                   {{"01.wav", false}});
    CHECK(planSwap(aliased, aliases->rewritten(key("/Volumes/share-1/income/Album/01.wav")), LibraryPrefix()).skip ==
              SwapSkip::None,
          "a row on the other mount of the share matches through the alias key");
    CHECK(matchSidecarFile(aliased, aliases->rewritten(key("/Volumes/share-1/income/Album/02.wav"))) == -1,
          "but only files[] entries");
    CHECK(matchSidecarFile(aliased, "") == -1, "an empty key matches nothing");
}

static void testAliasPaths() {
    g_context = "alias-paths";
    std::vector<MountEntry> mounts = {{"/", "/dev/disk1", "apfs", true},
                                      {"/Volumes/music", "//user@lan-host/Music", "smbfs", false},
                                      {"/Volumes/music-1", "//other@vpn-host/music", "smbfs", false},
                                      {"/Volumes/hq", "//user@lan-host/music/music.hq", "smbfs", false},
                                      {"/Volumes/other", "//user@lan-host/other", "smbfs", false},
                                      {"/Volumes/disk", "/dev/disk5", "apfs", true}};
    std::vector<std::string> paths = aliasMountPaths(mounts, "/Volumes/music/music.hq/A/x.wav");
    CHECK(paths == std::vector<std::string>({"/Volumes/music/music.hq/A/x.wav", "/Volumes/music-1/music.hq/A/x.wav",
                                             "/Volumes/hq/A/x.wav"}),
          "the given spelling first, then every mount of the share (share name ignoring case, a mounted subfolder)");
    CHECK(aliasMountPaths(mounts, "/Volumes/MUSIC/music.hq/A/x.wav").size() == 3, "mount points ignore ASCII case");
    CHECK(aliasMountPaths(mounts, "/Volumes/music/other/x.wav") ==
              std::vector<std::string>({"/Volumes/music/other/x.wav", "/Volumes/music-1/other/x.wav"}),
          "a path outside the mounted subfolder is not mapped into it");
    CHECK(aliasMountPaths(mounts, "/Volumes/disk/x.wav") == std::vector<std::string>({"/Volumes/disk/x.wav"}),
          "a local volume: only itself");
    CHECK(aliasMountPaths(mounts, "/Users/test/Music/x.wav") == std::vector<std::string>({"/Users/test/Music/x.wav"}),
          "the boot volume: only itself");
    CHECK(aliasMountPaths(mounts, "/Volumes/music2/x.wav") == std::vector<std::string>({"/Volumes/music2/x.wav"}),
          "mount points match at component boundaries");
    CHECK(aliasMountPaths({}, "/Volumes/music/x.wav").size() == 1, "no mount table: only itself");
}

static void testForms() {
    g_context = "forms";
    CHECK(otherNormalizationForm("/library/" + kNfc + "/x.wav") == "/library/" + kNfd + "/x.wav", "NFC -> NFD");
    CHECK(otherNormalizationForm("/library/" + kNfd + "/x.wav") == "/library/" + kNfc + "/x.wav", "NFD -> NFC");
    CHECK(otherNormalizationForm("/library/ascii/x.wav").empty(), "ASCII: no other form");
    CHECK(otherNormalizationForm(std::string("/bad/\xC3")).empty(), "invalid UTF-8: none");

    CHECK(canonicalVolumePrefix("mac-volume://0A1B-UUID/income/x.wav") == "mac-volume://0A1B-UUID/",
          "mac-volume: the scheme and the volume id");
    CHECK(canonicalVolumePrefix("MAC-VOLUME://0A1B-UUID/x") == "MAC-VOLUME://0A1B-UUID/", "scheme case kept");
    CHECK(canonicalVolumePrefix("file:///Users/test/x.wav") == "file://", "file://");
    CHECK(canonicalVolumePrefix("mac-volume:///x").empty() && canonicalVolumePrefix("mac-volume://uuid").empty(),
          "no volume id, no path");
    CHECK(canonicalVolumePrefix("/Users/test/x.wav").empty() && canonicalVolumePrefix("tidal://track/1").empty(),
          "raw paths and other schemes have none");
    CHECK(sameVolumePrefix("mac-volume://0a1b-uuid/", "MAC-VOLUME://0A1B-UUID/"), "compared ignoring ASCII case");
    CHECK(!sameVolumePrefix("mac-volume://A/", "mac-volume://B/"), "another volume id");
    CHECK(!sameVolumePrefix("file://", "mac-volume://A/"), "a local form is not a share's form");
    CHECK(!sameVolumePrefix("", ""), "empty never matches");
}

static CanonicalCandidate candidate(const std::string &path, const std::string &form, bool roundTrips) {
    CanonicalCandidate c;
    c.path = path;
    c.form = form;
    c.roundTrips = roundTrips;
    return c;
}

static void testChooseMount() {
    g_context = "choose-mount";
    std::vector<MountEntry> mounts = {{"/", "/dev/disk1", "apfs", true},
                                      {"/Volumes/music", "//user@lan-host/music", "smbfs", false},
                                      {"/Volumes/music-1", "//user@vpn-host/music", "smbfs", false},
                                      {"/Volumes/Music/Sub", "/dev/disk7", "apfs", true}};
    CHECK(owningMountPoint(mounts, "/Volumes/music/hq/A/x.wav") == "/Volumes/music", "the share's mount");
    CHECK(owningMountPoint(mounts, "/Volumes/music-1/hq/x.wav") == "/Volumes/music-1",
          "the second mount, at a component boundary");
    CHECK(owningMountPoint(mounts, "/Volumes/MUSIC/Sub/x.wav") == "/Volumes/Music/Sub",
          "the longest mount point, ignoring ASCII case");
    CHECK(owningMountPoint(mounts, "/Users/test/x.wav") == "/", "the boot volume");
    CHECK(owningMountPoint({}, "/Volumes/music/x.wav").empty() && owningMountPoint(mounts, "relative").empty(),
          "no table or no absolute path: none");

    CHECK(pathUnderMountPoint("/Volumes/music-1/hq/x.wav", "/Volumes/music-1"), "under its mount");
    CHECK(pathUnderMountPoint("file:///Volumes/music/hq/x.wav", "/volumes/MUSIC"), "file:// stripped, case ignored");
    CHECK(!pathUnderMountPoint("/Volumes/music-1/hq/x.wav", "/Volumes/music"),
          "the other mount of the share is not this one");
    CHECK(pathUnderMountPoint("/Users/test/x.wav", "/") && !pathUnderMountPoint("mac-volume://U/x", "/") &&
              !pathUnderMountPoint("/x", ""),
          "\"/\" holds every absolute path; a scheme or an empty mount never matches");

    std::vector<std::string> forms;
    noteVolumeForm(forms, "mac-volume://U2/income/x.wav");
    noteVolumeForm(forms, "MAC-VOLUME://u2/other.wav");
    noteVolumeForm(forms, "file:///Users/test/a.wav");
    noteVolumeForm(forms, "tidal://track/1");
    CHECK(forms == std::vector<std::string>({"mac-volume://U2/", "file://"}),
          "each volume form once, ASCII case ignored; other schemes have none");
    CHECK(hasVolumeForm(forms, "mac-volume://u2/hq/x.wav") && !hasVolumeForm(forms, "mac-volume://U1/hq/x.wav") &&
              !hasVolumeForm(forms, "/Volumes/music/x.wav"),
          "membership by volume form");

    // The share mounted twice: U1 at /Volumes/music, U2 at /Volumes/music-1.
    const std::vector<CanonicalCandidate> both = {
        candidate("/Volumes/music/hq/A/x.wav", "mac-volume://U1/", false),
        candidate("/Volumes/music-1/hq/A/x.wav", "mac-volume://U2/", true)};
    CHECK(chooseCanonicalCandidate(both, {"mac-volume://U2/"}) == 1,
          "the mount whose volume id the playlist's items already use, even when it is not the first");
    CHECK(chooseCanonicalCandidate(both, {"mac-volume://U1/", "mac-volume://U2/"}) == 0,
          "both in use: the first, in stat order");
    CHECK(chooseCanonicalCandidate(both, {"file://"}) == 1,
          "a local income row and no item on the share: the mount foobar2000 resolves its own form to");
    CHECK(chooseCanonicalCandidate({candidate("/Volumes/music/hq/x.wav", "mac-volume://U1/", false)},
                                   {"file://"}) == -1,
          "no item uses it and it does not round-trip: no matching mount");
    CHECK(chooseCanonicalCandidate({candidate("/Volumes/music/hq/x.wav", "", true)}, {"mac-volume://U1/"}) == -1,
          "a failed conversion (no form) never counts");
    CHECK(chooseCanonicalCandidate({candidate("/Volumes/music/hq/x.wav", "mac-volume://U1/hq/x.wav", false)},
                                   {"mac-volume://u1/"}) == 0,
          "a whole canonical path in `form` is read by its volume part");
    CHECK(chooseCanonicalCandidate({candidate("/Users/test/lib/x.wav", "file://", true)},
                                   {"mac-volume://U2/"}) == 0,
          "a local library file: its own form (it round-trips)");
    CHECK(chooseCanonicalCandidate({}, {"file://"}) == -1, "no candidate: none");
}

static void testLine() {
    g_context = "line";
    SwapTally t;
    CHECK(swapResultLine(t) == "swap: 0 row(s) swapped to library paths, 0 skipped", "nothing at all");
    t.swapped = 2;
    CHECK(swapResultLine(t) == "swap: 2 row(s) swapped to library paths, 0 skipped", "all swapped");
    t.skip(SwapSkip::Shadow);
    t.skip(SwapSkip::LibraryMissing);
    t.skip(SwapSkip::LibraryMissing);
    t.skip(SwapSkip::NoMatchingMount);
    CHECK(t.skippedTotal() == 4 && t.skippedFor(SwapSkip::LibraryMissing) == 2, "counts");
    CHECK(swapResultLine(t) ==
              "swap: 2 row(s) swapped to library paths, 4 skipped (1 shadow, 2 library file missing, 1 no matching mount)",
          "the reasons with counts, in a fixed order");
    CHECK(std::string(swapSkipText(SwapSkip::NotInSidecar)) == "not in the sidecar" &&
              std::string(swapSkipText(SwapSkip::PlaylistLocked)) == "playlist locked" &&
              std::string(swapSkipText(SwapSkip::SlowConversion)) == "path conversion too slow",
          "reason texts");
    SwapTally links;
    links.skip(SwapSkip::LinkOffShare);
    links.skip(SwapSkip::LibraryMissing);
    CHECK(swapResultLine(links) == "swap: 0 row(s) swapped to library paths, 2 skipped (1 library file missing, 1 the "
                                   "share link does not lead to the library copy)",
          "B11: the share-link skip, after the mount reasons");
}

// --- B11 share links ---

static const std::string kLink = "/Users/x/Music/NAS/music";

// What readShareLink would report for `link` (synthetic: nothing is read).
static ShareLinkRead linkRead(const std::string &link, const std::string &target) {
    ShareLinkRead r;
    r.status = ShareLinkStatus::Link;
    r.linkPath = link;
    r.rawTarget = target;
    r.resolvedParent = parentDirectory(link);
    return r;
}

static std::vector<MountEntry> shareMounts() {
    return {{"/", "/dev/disk1", "apfs", true},
            {"/Volumes/music", "//user@lan-host/music", "smbfs", false},
            {"/Volumes/music-1", "//user@vpn-host/music", "smbfs", false}};
}

// The link forms of a playlist holding `items`, as Swap notes them at the click.
static PlaylistLinkForms noted(const std::shared_ptr<const MountAliases> &table, const std::vector<std::string> &items) {
    PlaylistLinkForms forms;
    std::string buffer;
    for (const std::string &item : items) noteLinkForm(forms, table->links(), item, buffer);
    return forms;
}

static void testLinkForms() {
    g_context = "link-forms";
    const std::vector<MountEntry> mounts = shareMounts();
    auto lan = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/music")});
    const std::string item = "file://" + kLink + "/library/Fixture Artist - Other/01.wav";
    PlaylistLinkForms forms = noted(lan, {"mac-volume://U1/library/x.wav", item, item,
                                          "file://" + kLink + "/library/Fixture Artist - Third/02.wav"});
    CHECK(forms.links == std::vector<std::string>({kLink}), "a link-form item notes its link, once");
    CHECK(forms.items.size() == 2 && forms.items.count(key(item)) && forms.items[key(item)] == item,
          "each link-form item by match key, with its spelling");
    CHECK(!forms.empty(), "the playlist uses a link form");

    PlaylistLinkForms none = noted(lan, {"mac-volume://U1/library/x.wav", "file:///Users/x/Music/local/a.wav",
                                         "file://" + kLink + "2/a.wav", "/Users/x/Music/NAS/music/raw.wav",
                                         "tidal://track/1"});
    CHECK(none.empty() && none.items.empty(),
          "no link form: volume forms, other local files, a name that only starts like the link, a raw path, other "
          "schemes");
    CHECK(noted(lan, {"FILE://" + kLink + "/a.wav"}).links.size() == 1, "the scheme ignoring ASCII case");
    const PlaylistLinkForms otherCase = noted(lan, {"file:///Users/x/music/NAS/music/a.wav",
                                                    "file:///Users/x/MUSIC/nas/Music/b.wav"});
    CHECK(otherCase.links.empty() && otherCase.items.empty(), "the link byte-exact, never ignoring case");
    CHECK(otherCase.otherCase == std::vector<std::string>({kLink}) && !otherCase.empty(),
          "a link spelled in another letter case: noted apart, once, and the playlist is in the link form");
    const PlaylistLinkForms both = noted(lan, {"file:///Users/x/music/NAS/music/a.wav", item});
    CHECK(both.links == std::vector<std::string>({kLink}) && both.otherCase == std::vector<std::string>({kLink}),
          "both spellings in one playlist: each noted");
    CHECK(noted(lan, {"file:///Users/x/music/NAS/music2/a.wav"}).empty(),
          "another letter case still at a component boundary");
    CHECK(noted(MountAliases::build(mounts), {item}).empty(), "no link configured: nothing noted");

    auto nested = MountAliases::build(mounts, {linkRead("/Users/x/a", "/Users/x/mirror"),
                                               linkRead("/Users/x/a/b", "/Volumes/music-1/sub")});
    CHECK(noted(nested, {"file:///Users/x/a/b/c.wav"}).links == std::vector<std::string>({"/Users/x/a/b"}),
          "nested links: the longer one, as rewrite() picks");
    CHECK(noted(nested, {"file:///Users/x/a/c.wav"}).links == std::vector<std::string>({"/Users/x/a"}),
          "the shorter one elsewhere");
}

static void testLinkForm() {
    g_context = "link-form";
    const std::vector<MountEntry> mounts = shareMounts();
    const std::string playlistItem = "file://" + kLink + "/library/Fixture Artist - Other/01.wav";
    const std::vector<std::string> both = {"/Volumes/music/library/Fixture Artist - Album/01.wav",
                                           "/Volumes/music-1/library/Fixture Artist - Album/01.wav"};
    const std::string linkForm = "file://" + kLink + "/library/Fixture Artist - Album/01.wav";

    auto lan = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/music")});
    LinkForm f = linkFormFor(both, lan->links(), noted(lan, {playlistItem}).links);
    CHECK(f.candidateIndex == 0 && f.path == linkForm,
          "link -> /Volumes/music, the file found there: that candidate's link form");

    auto vpn = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/music-1")});
    const std::vector<std::string> vpnForms = noted(vpn, {playlistItem}).links;
    f = linkFormFor(both, vpn->links(), vpnForms);
    CHECK(f.candidateIndex == 1 && f.path == linkForm,
          "link -> /Volumes/music-1, found under /Volumes/music first: the candidate under /Volumes/music-1");
    CHECK(linkFormFor({both[0]}, vpn->links(), vpnForms).candidateIndex == -1,
          "the copy only under the mount the link does not lead to: none");

    g_context = "link-off-share";
    auto mirror = MountAliases::build(mounts, {linkRead(kLink, "/Users/x/mirror/music")});
    f = linkFormFor(both, mirror->links(), noted(mirror, {playlistItem}).links);
    CHECK(f.candidateIndex == -1 && f.path.empty(), "link -> mirror: no candidate under it (Swap: LinkOffShare)");
    auto placeholder = MountAliases::build({mounts[0]}, {linkRead(kLink, "/Volumes/music")});
    CHECK(linkFormFor({}, placeholder->links(), noted(placeholder, {playlistItem}).links).candidateIndex == -1,
          "the unmounted placeholder: no library copy was found at all");
    CHECK(std::string(swapSkipText(SwapSkip::LinkOffShare)) == "the share link does not lead to the library copy",
          "the skip's text");

    g_context = "link-unused";
    // The playlist uses no link form: linkFormFor gives none, and Swap keeps
    // the volume-form rule (chooseCanonicalCandidate).
    const PlaylistLinkForms unused = noted(lan, {"mac-volume://U1/library/x.wav"});
    CHECK(unused.empty() && linkFormFor(both, lan->links(), unused.links).candidateIndex == -1,
          "a link the playlist does not use: no link form");

    g_context = "link-mixed";
    std::vector<std::string> playlistForms;
    const std::vector<std::string> mixedItems = {"mac-volume://U1/library/x.wav", playlistItem};
    for (const std::string &i : mixedItems) noteVolumeForm(playlistForms, i);
    const PlaylistLinkForms mixed = noted(lan, mixedItems);
    CHECK(hasVolumeForm(playlistForms, "mac-volume://U1/") && !mixed.empty(),
          "a mixed playlist: a volume form and a link form");
    f = linkFormFor(both, lan->links(), mixed.links);
    CHECK(f.candidateIndex == 0 && f.path == linkForm, "the link form wins");

    g_context = "link-nfd";
    const std::string nfdCandidate = "/Volumes/music/library/" + kNfd + "/01.wav";
    f = linkFormFor({nfdCandidate}, lan->links(), mixed.links);
    CHECK(f.path == "file://" + kLink + "/library/" + kNfd + "/01.wav", "the NFD bytes kept as stat'ed");

    g_context = "link-trailing-slash";
    const ShareLinkList configured = parseShareLinks(kLink + "/\n");
    CHECK(configured.links == std::vector<std::string>({kLink}), "the configured line is cleaned");
    // The read as the loader makes it: the link's folders are local, the
    // target is a network mount, never read past.
    std::vector<std::string> reads;
    LinkReader reader = [&](const std::string &path, std::string &target) {
        reads.push_back(path);
        if (path == kLink) {
            target = "/Volumes/music";
            return LinkCheck::Link;
        }
        return LinkCheck::NotLink;
    };
    const ShareLinkRead read = readShareLink(configured.links[0], mounts, reader);
    CHECK(read.status == ShareLinkStatus::Link && read.linkPath == kLink && read.rawTarget == "/Volumes/music",
          "read as a link to /Volumes/music");
    bool onShare = false;
    for (const std::string &r : reads) onShare = onShare || r.rfind("/Volumes/music", 0) == 0;
    CHECK(!reads.empty() && !onShare, "nothing on the share was read");
    auto cleaned = MountAliases::build(mounts, {read});
    f = linkFormFor(both, cleaned->links(), noted(cleaned, {playlistItem}).links);
    CHECK(f.path == linkForm, "no double slash after the link");
    auto dirty = MountAliases::build(mounts, {linkRead(kLink + "/", "/Volumes/music/")});
    f = linkFormFor(both, dirty->links(), noted(dirty, {playlistItem}).links);
    CHECK(f.candidateIndex == 0 && f.path == linkForm, "a raw link or target with a trailing slash is cleaned here too");

    g_context = "link-spelled-through";
    // The prefix pair may already lead into the link (swap_prefix_to = the link).
    const std::string through = kLink + "/library/Fixture Artist - Album/01.wav";
    f = linkFormFor({through}, lan->links(), mixed.links);
    CHECK(f.candidateIndex == 0 && f.path == "file://" + through, "a candidate spelled through the link itself");
    CHECK(linkFormFor({"/Users/x/Music/NAS/music2/a.wav"}, lan->links(), mixed.links).candidateIndex == -1,
          "the link matched at a component boundary");

    g_context = "link-target-case";
    auto upper = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/MUSIC")});
    f = linkFormFor(both, upper->links(), noted(upper, {playlistItem}).links);
    CHECK(f.candidateIndex == 0 && f.path == linkForm, "the target compared ignoring ASCII case, as mount points are");
    CHECK(linkFormFor({"/Volumes/music2/library/a.wav"}, lan->links(), mixed.links).candidateIndex == -1,
          "the target matched at a component boundary");

    g_context = "link-to-root";
    auto root = MountAliases::build(mounts, {linkRead(kLink, "/")});
    f = linkFormFor(both, root->links(), noted(root, {playlistItem}).links);
    CHECK(f.candidateIndex == 0 && f.path == "file://" + kLink + both[0], "a link to /: the whole path past the link");

    g_context = "link-several";
    auto two = MountAliases::build(mounts, {linkRead("/Users/x/mirror-link", "/Users/x/mirror"),
                                            linkRead(kLink, "/Volumes/music-1")});
    const PlaylistLinkForms twoForms = noted(two, {"file:///Users/x/mirror-link/a.wav", playlistItem});
    CHECK(twoForms.links.size() == 2, "two links in use");
    f = linkFormFor(both, two->links(), twoForms.links);
    CHECK(f.candidateIndex == 1 && f.path == linkForm, "the noted link that leads to a candidate");
    CHECK(linkFormFor(both, two->links(), {"/Users/x/not-a-link"}).candidateIndex == -1,
          "a noted key with no entry: none");
}

static void testLinkSpelling() {
    g_context = "link-spelling";
    const std::vector<MountEntry> mounts = shareMounts();
    auto lan = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/music")});
    const std::string nfc = "file://" + kLink + "/library/" + kNfc + "/01.wav";
    const std::string nfd = "file://" + kLink + "/library/" + kNfd + "/01.wav";
    const PlaylistLinkForms nfdItems = noted(lan, {nfd});
    CHECK(linkSpellingFor(nfdItems, nfc) == nfd, "an item already spells it NFD: that spelling, not the stat'ed NFC");
    CHECK(linkSpellingFor(nfdItems, nfd) == nfd, "the same bytes: itself");
    CHECK(linkSpellingFor(noted(lan, {nfc}), nfd) == nfc, "an NFC item, NFD stat'ed: the NFC spelling");
    const std::string other = "file://" + kLink + "/library/" + kNfc + "/02.wav";
    CHECK(linkSpellingFor(nfdItems, other) == other, "no item spells it: the stat'ed bytes");
    CHECK(linkSpellingFor(PlaylistLinkForms(), nfc) == nfc, "nothing noted: the stat'ed bytes");
    CHECK(linkSpellingFor(noted(lan, {nfc, nfd}), nfd) == nfc, "both spellings in the playlist: the first one seen");
}

// Swap's decision for one row (planOnQueue): the volume-form rule, a skip,
// or the link form.
static void testLinkDecision() {
    g_context = "link-decision";
    const std::vector<MountEntry> mounts = shareMounts();
    const std::vector<std::string> both = {"/Volumes/music/library/Fixture Artist - Album/01.wav",
                                           "/Volumes/music-1/library/Fixture Artist - Album/01.wav"};
    const std::string playlistItem = "file://" + kLink + "/library/Fixture Artist - Other/01.wav";
    auto lan = MountAliases::build(mounts, {linkRead(kLink, "/Volumes/music")});

    LinkDecision d = decideLinkForm(both, lan->links(), noted(lan, {"mac-volume://U1/library/x.wav"}));
    CHECK(d.skip == SwapSkip::None && d.path.empty(), "rule 3, no link form in the playlist: the volume-form rule");
    d = decideLinkForm(both, lan->links(), PlaylistLinkForms());
    CHECK(d.skip == SwapSkip::None && d.path.empty(), "nothing noted: the volume-form rule");

    d = decideLinkForm(both, lan->links(), noted(lan, {playlistItem}));
    CHECK(d.skip == SwapSkip::None && d.path == "file://" + kLink + "/library/Fixture Artist - Album/01.wav",
          "rule 1: the link form");
    const std::string nfdItem = "file://" + kLink + "/library/" + kNfd + "/01.wav";
    d = decideLinkForm({"/Volumes/music/library/" + kNfc + "/01.wav"}, lan->links(), noted(lan, {nfdItem}));
    CHECK(d.skip == SwapSkip::None && d.path == nfdItem, "an item's existing spelling of the link form first");

    auto mirror = MountAliases::build(mounts, {linkRead(kLink, "/Users/x/mirror/music")});
    d = decideLinkForm(both, mirror->links(), noted(mirror, {playlistItem}));
    CHECK(d.skip == SwapSkip::LinkOffShare && d.path.empty(), "rule 2, link -> mirror: skipped, no volume form");
    d = decideLinkForm({}, lan->links(), noted(lan, {playlistItem}));
    CHECK(d.skip == SwapSkip::LinkOffShare && d.path.empty(), "no candidate at all: skipped");

    const PlaylistLinkForms otherCase = noted(lan, {"file:///Users/x/music/NAS/music/a.wav"});
    d = decideLinkForm(both, lan->links(), otherCase);
    CHECK(d.skip == SwapSkip::LinkOffShare && d.path.empty(),
          "the link spelled only in another letter case: skipped, never the volume form");
    d = decideLinkForm(both, lan->links(), noted(lan, {"file:///Users/x/music/NAS/music/a.wav", playlistItem}));
    CHECK(d.skip == SwapSkip::None && d.path == "file://" + kLink + "/library/Fixture Artist - Album/01.wav",
          "with an item in the link's own spelling too: that link form");
}

static void testCensusEntry() {
    g_context = "census";
    CHECK(censusEntry(false, false, false) == CensusEntry::Clear, "no income path: clear");
    CHECK(censusEntry(false, false, true) == CensusEntry::Income, "an income path: an income row");
    CHECK(censusEntry(true, false, false) == CensusEntry::Unchecked, "not converted: unchecked, never clear");
    CHECK(censusEntry(false, true, false) == CensusEntry::Unchecked,
          "under a share link off the share, matching nothing now: unchecked, never clear");
    CHECK(censusEntry(false, true, true) == CensusEntry::Unchecked,
          "under the unmounted placeholder, matching an income root by the last snapshot: still unchecked");
    CHECK(censusEntry(true, true, true) == CensusEntry::Unchecked, "both: unchecked");
}

int main() {
    @autoreleasepool {
        testParse();
        testRead();
        testPrefix();
        testPlanWholeFolder();
        testPlanVirtualAndKeys();
        testAliasPaths();
        testForms();
        testChooseMount();
        testLine();
        testLinkForms();
        testLinkForm();
        testLinkSpelling();
        testLinkDecision();
        testCensusEntry();
    }
    TEST_MAIN_END();
}
