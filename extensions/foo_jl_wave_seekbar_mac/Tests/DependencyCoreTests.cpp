//
//  DependencyCoreTests.cpp
//  foo_wave_seekbar_mac
//
//  Installing BPM Analyzer from the preferences (shared/jl_dependency):
//  versions, picking the release from the suite's release list, the
//  checksum, the archive listing (the published 0.1.0 package and crafted
//  bad ones), download hosts, the gate's state and the resume note.
//

#include "TestSupport.h"
#include "../../../shared/jl_dependency/jl_dependency_core.h"

using namespace jl_dep;

namespace {

void testVersions() {
    TEST_CASE("versions");
    CHECK(parseVersion("0.1.0").valid, "0.1.0");
    CHECK(parseVersion("v1.12.3").valid && parseVersion("v1.12.3").minor == 12, "v1.12.3");
    CHECK(!parseVersion("1.2").valid, "two parts");
    CHECK(!parseVersion("1.2.3-beta").valid, "a suffix");
    CHECK(!parseVersion("").valid && !parseVersion("1..3").valid && !parseVersion(" 1.2.3").valid, "junk");
    CHECK(compare(parseVersion("0.10.0"), parseVersion("0.9.9")) > 0, "numeric, not text order");
    CHECK(compare(parseVersion("1.0.0"), parseVersion("1.0.0")) == 0, "equal");
    CHECK(compare(Version{}, parseVersion("0.0.1")) < 0, "nothing before anything");
    CHECK(toString(parseVersion("v2.0.11")) == "2.0.11", "printed back");
}

const char *const kRepo = "JendaT/fb2k-components-mac-suite";

std::vector<Release> suiteReleases() {
    auto rel = [](const char *tag, std::vector<Asset> assets, bool draft = false, bool pre = false) {
        Release r;
        r.tag = tag;
        r.draft = draft;
        r.prerelease = pre;
        r.assets = std::move(assets);
        return r;
    };
    auto assets = [](const char *tag, bool withSums = true) {
        std::vector<Asset> a = { { "foo_jl_bpm.fb2k-component", 8986039,
                                   releaseAssetURL(kRepo, tag, "foo_jl_bpm.fb2k-component") } };
        if (withSums) a.push_back({ "SHA256SUMS", 92, releaseAssetURL(kRepo, tag, "SHA256SUMS") });
        return a;
    };
    std::vector<Asset> elsewhere = assets("bpm-v0.4.0");
    elsewhere[0].url = "https://github.com/someone/else/releases/download/bpm-v0.4.0/foo_jl_bpm.fb2k-component";
    return {
        rel("waveform-seekbar-v2.0.0", { { "foo_jl_wave_seekbar.fb2k-component", 1, "u" } }),   // the repo's latest
        rel("bpm-v0.1.0", assets("bpm-v0.1.0")),
        rel("bpm-v0.3.0", assets("bpm-v0.3.0"), true),          // draft
        rel("bpm-v0.2.0", assets("bpm-v0.2.0"), false, true),   // prerelease
        rel("bpm-v0.1.5", assets("bpm-v0.1.5", false)),         // no checksums
        rel("bpm-v0.1.9-test", assets("bpm-v0.1.9-test")),      // not X.Y.Z
        rel("bpmx-v9.0.0", assets("bpmx-v9.0.0")),              // another prefix
        rel("bpm-v0.4.0", elsewhere),                           // its package served from another repository
        rel("bpm-v0.1.2", assets("bpm-v0.1.2")),
    };
}

void testPickRelease() {
    TEST_CASE("pick release");
    const Pick p = pickRelease(suiteReleases(), kRepo, "bpm-v", "foo_jl_bpm.fb2k-component");
    CHECK(p.found, "found");
    CHECK(p.tag == "bpm-v0.1.2", "the newest published bpm-v release with both assets from its own URLs");
    CHECK(p.package.size == 8986039 && p.sums.name == "SHA256SUMS", "its assets");
    CHECK(!pickRelease(suiteReleases(), kRepo, "bpm-v", "other.fb2k-component").found, "no such asset");
    CHECK(!pickRelease({}, kRepo, "bpm-v", "foo_jl_bpm.fb2k-component").found, "no releases");
    CHECK(!pickRelease(suiteReleases(), "someone/else", "bpm-v", "foo_jl_bpm.fb2k-component").found,
          "pinned to the repository");

    // Tags from the repository's tag list, newest first
    const std::vector<std::string> tags = newestTags(
        { "refs/tags/bpm-v0.1.0", "refs/tags/bpm-v0.10.0", "refs/tags/bpm-v0.9.1", "refs/tags/bpm-v1.0.0-rc1",
          "refs/tags/bpm-vnext", "refs/tags/bpmx-v5.0.0", "refs/heads/bpm-v9.0.0" }, "bpm-v", 2);
    CHECK(tags.size() == 2 && tags[0] == "bpm-v0.10.0" && tags[1] == "bpm-v0.9.1", "newest two X.Y.Z tags");
    CHECK(newestTags({}, "bpm-v", 5).empty(), "no tags");
}

void testChecksum() {
    TEST_CASE("checksum");
    const std::string hex = "b509f48e957267e8e3a615ea87d0ad722242d78bcdcd3983106d0ea6d34ac712";
    CHECK(findSha256(hex + "  foo_jl_bpm.fb2k-component\n", "foo_jl_bpm.fb2k-component") == hex, "shasum's format");
    CHECK(findSha256(hex + " *foo_jl_bpm.fb2k-component\r\n", "foo_jl_bpm.fb2k-component") == hex, "binary marker, CRLF");
    std::string upper = hex;
    for (char &c : upper) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    CHECK(findSha256(upper + "  foo_jl_bpm.fb2k-component", "foo_jl_bpm.fb2k-component") == hex, "upper case read as lower");
    CHECK(findSha256(hex + "  other.fb2k-component\n", "foo_jl_bpm.fb2k-component").empty(), "another file");
    CHECK(findSha256(hex.substr(1) + "  foo_jl_bpm.fb2k-component", "foo_jl_bpm.fb2k-component").empty(), "short hash");
    CHECK(findSha256(hex + "  foo_jl_bpm.fb2k-component\n" + hex + "  foo_jl_bpm.fb2k-component\n",
                     "foo_jl_bpm.fb2k-component").empty(), "listed twice");
    CHECK(findSha256(hex + "  foo_jl_bpm.fb2k-component.bak", "foo_jl_bpm.fb2k-component").empty(), "a longer name");
}

void testHosts() {
    TEST_CASE("hosts");
    CHECK(allowedDownloadHost("https", "github.com"), "github.com");
    CHECK(allowedDownloadHost("https", "api.github.com"), "the API");
    CHECK(allowedDownloadHost("https", "objects.githubusercontent.com"), "release storage");
    CHECK(allowedDownloadHost("https", "Release-Assets.GitHubUserContent.com"), "case-insensitive");
    CHECK(!allowedDownloadHost("https", "raw.githubusercontent.com"), "not anyone's raw files");
    CHECK(!allowedDownloadHost("https", "gist.githubusercontent.com"), "not gists");
    CHECK(!allowedDownloadHost("http", "github.com"), "not plain HTTP");
    CHECK(!allowedDownloadHost("https", "githubusercontent.com.evil.example"), "not a lookalike");
    CHECK(!allowedDownloadHost("https", "evilgithubusercontent.com"), "not a suffix without the dot");
    CHECK(!allowedDownloadHost("https", "example.com"), "nothing else");
}

// zipinfo's listing of the published foo_jl_bpm.fb2k-component 0.1.0
const char *kPublished = R"(Archive:  /tmp/foo_jl_bpm.fb2k-component
Zip file size: 8986039 bytes, number of entries: 18
drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/
drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/
drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/
drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/_CodeSignature/
-rw-r--r--  3.0 unx     3888 tx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/_CodeSignature/CodeResources
drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/MacOS/
-rwxr-xr-x  3.0 unx  3371616 bx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/MacOS/foo_jl_bpm
drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/
-rw-r--r--  3.0 unx     1486 tx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/BeatThis-LICENSE.txt
drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/BeatThisSmall0.mlmodelc/
drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/BeatThisSmall0.mlmodelc/weights/
-rw-r--r--  3.0 unx  8810496 bx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/BeatThisSmall0.mlmodelc/weights/weight.bin
-rw-r--r--  3.0 unx     2538 tx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/BeatThisSmall0.mlmodelc/metadata.json
-rw-r--r--  3.0 unx   234603 tx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/BeatThisSmall0.mlmodelc/model.mil
-rw-r--r--  3.0 unx      588 bx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/BeatThisSmall0.mlmodelc/coremldata.bin
drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/BeatThisSmall0.mlmodelc/analytics/
-rw-r--r--  3.0 unx      243 bx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Resources/BeatThisSmall0.mlmodelc/analytics/coremldata.bin
-rw-r--r--  3.0 unx     1457 tx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/Info.plist
18 files, 12426915 bytes uncompressed, 8981601 bytes compressed:  27.7%
)";

ArchiveCheck checkWith(const std::string &extra) {
    return checkArchiveListing(std::string(kPublished) + extra, "foo_jl_bpm.component", "foo_jl_bpm");
}

void testArchive() {
    TEST_CASE("archive");
    const ArchiveCheck ok = checkArchiveListing(kPublished, "foo_jl_bpm.component", "foo_jl_bpm");
    CHECK(ok.ok, "the published package passes");
    CHECK(ok.files == 9, "its 9 files");
    const std::string row = "-rw-r--r--  3.0 unx      243 bx defN 26-Nov-03 23:39 ";
    CHECK(!checkWith("lrwxr-xr-x  3.0 unx       11 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/link\n").ok, "a symlink");
    CHECK(!checkWith(row + "mac/foo_jl_bpm.component/../../evil\n").ok, "a .. component");
    CHECK(!checkWith(row + "/etc/evil\n").ok, "an absolute path");
    CHECK(!checkWith(row + "mac/other.component/Contents/Info.plist\n").ok, "another bundle");
    CHECK(!checkWith(row + "evil.txt\n").ok, "a file at the top");
    CHECK(!checkWith(row + "mac/evil.txt\n").ok, "a file beside the bundle");
    CHECK(!checkWith(row + "mac/foo_jl_bpm.component\\..\\evil\n").ok, "a backslash");
    CHECK(!checkWith("-rw-a--     2.0 fat      243 bx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/x\n").ok, "a non-Unix entry");
    CHECK(!checkWith("prw-r--r--  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/foo_jl_bpm.component/fifo\n").ok, "a pipe");
    CHECK(checkWith(row + "mac/foo_jl_bpm.component/Contents/Resources/with space.txt\n").ok, "a name with a space is fine");
    CHECK(checkArchiveListing("drwxr-xr-x  3.0 unx        0 bx stor 26-Nov-03 23:39 mac/\n"
                              "-rwxr-xr-x  3.0 unx        1 bx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/MacOS/foo_jl_bpm\n"
                              "1 file, 1 bytes uncompressed, 1 bytes compressed:  0.0%\n",
                              "foo_jl_bpm.component", "foo_jl_bpm").ok, "the singular trailer line");

    std::string noExe = kPublished;
    const std::string exeLine = "-rwxr-xr-x  3.0 unx  3371616 bx defN 26-Nov-03 23:39 mac/foo_jl_bpm.component/Contents/MacOS/foo_jl_bpm\n";
    noExe.erase(noExe.find(exeLine), exeLine.size());
    CHECK(!checkArchiveListing(noExe, "foo_jl_bpm.component", "foo_jl_bpm").ok, "no executable");
    std::string notExecutable = kPublished;
    notExecutable.replace(notExecutable.find("-rwxr-xr-x  3.0 unx  3371616"), 10, "-rw-r--r--");
    CHECK(!checkArchiveListing(notExecutable, "foo_jl_bpm.component", "foo_jl_bpm").ok, "the executable without its x bit");
    CHECK(!checkArchiveListing("", "foo_jl_bpm.component", "foo_jl_bpm").ok, "an empty listing");
    CHECK(!checkArchiveListing(kPublished, "foo_jl_other.component", "foo_jl_other").ok, "a package of another component");
}

void testGate() {
    TEST_CASE("gate");
    const Version none, old = parseVersion("0.0.9"), min = parseVersion("0.1.0"), now = parseVersion("0.1.0");
    CHECK(gateState(true, now, min, false, false, false) == GateState::Available, "loaded: available");
    CHECK(gateState(false, none, min, false, false, false) == GateState::Missing, "nothing on disk: missing");
    CHECK(gateState(false, old, min, false, false, false) == GateState::TooOld, "older than needed");
    CHECK(gateState(false, now, min, false, false, false) == GateState::RestartPending, "on disk, not loaded yet");
    CHECK(gateState(false, none, min, true, false, false) == GateState::Working, "working");
    CHECK(gateState(false, none, min, false, true, false) == GateState::Failed, "failed");
    CHECK(gateState(false, none, min, false, false, true) == GateState::BusyElsewhere, "locked by another dependent");
    CHECK(gateState(true, old, min, false, false, true) == GateState::Available, "loaded wins over a lock");
}

void testResume() {
    TEST_CASE("resume");
    ResumeNote n;
    n.component = "foo_jl_bpm";
    n.pageGuid = "{01234567-89AB-CDEF-0123-456789ABCDEF}";
    n.dependent = "Waveform Seekbar";
    n.version = "0.1.0";
    n.timestamp = 1793750400;
    ResumeNote back;
    CHECK(decodeResume(encodeResume(n), back), "round trip");
    CHECK(back.component == n.component && back.pageGuid == n.pageGuid && back.dependent == n.dependent &&
              back.version == n.version && back.timestamp == n.timestamp, "every field");
    CHECK(resumeIsFresh(back, n.timestamp + 30), "half a minute later");
    CHECK(!resumeIsFresh(back, n.timestamp + kResumeMaxAgeSeconds + 1), "after ten minutes: dropped");
    CHECK(!resumeIsFresh(back, n.timestamp - 3600), "from the future: dropped");
    CHECK(!decodeResume("v2|foo_jl_bpm|g|k|0.1.0|1", back), "another format");
    CHECK(!decodeResume("v1|foo_jl_bpm|g|k|0.1.0|12x", back), "a bad time");
    CHECK(!decodeResume("v1||g|k|0.1.0|1", back), "no component");
    CHECK(!decodeResume("", back), "nothing");
}

} // namespace

int main() {
    testVersions();
    testPickRelease();
    testChecksum();
    testHosts();
    testArchive();
    testGate();
    testResume();
    return testsupport::summarize("DependencyCoreTests");
}
