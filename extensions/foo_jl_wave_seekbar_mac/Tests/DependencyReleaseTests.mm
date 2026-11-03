//
//  DependencyReleaseTests.mm
//  foo_wave_seekbar_mac
//
//  Reading GitHub's answers (JLComponentInstaller releasesFromJSON,
//  refNamesFromJSON) and picking BPM Analyzer's release from them: responses
//  recorded from the suite's repository after BPM Analyzer 0.1.0 (fields
//  trimmed to those read), with a newer draft and prerelease added to the
//  release list and tags that are not X.Y.Z added to the tag list.
//

#include "TestSupport.h"
#define JL_DEPENDENCY_PREFIX WaveSeekTest
#include "../../../shared/jl_dependency/JLComponentInstaller.mm"

using namespace jl_dep;

namespace {

NSData *fixture(NSString *name) {
    NSString *here = [@__FILE__ stringByDeletingLastPathComponent];
    return [NSData dataWithContentsOfFile:[[here stringByAppendingPathComponent:@"fixtures"] stringByAppendingPathComponent:name]];
}

const char *const kRepo = "JendaT/fb2k-components-mac-suite";

void testRecordedResponse() {
    TEST_CASE("recorded response");
    NSData *data = fixture(@"github_releases.json");
    CHECK(data.length > 0, "fixture read");
    const std::vector<Release> releases = [JLComponentInstaller releasesFromJSON:data];
    CHECK(releases.size() == 58, "every release read");
    const Pick p = pickRelease(releases, kRepo, "bpm-v", "foo_jl_bpm.fb2k-component");
    CHECK(p.found, "BPM Analyzer found among the suite's releases");
    CHECK(p.tag == "bpm-v0.1.0", "0.1.0, not the newer draft or prerelease");
    CHECK(p.package.size == 8986039, "the package's size");
    CHECK(p.package.url == "https://github.com/JendaT/fb2k-components-mac-suite/releases/download/bpm-v0.1.0/foo_jl_bpm.fb2k-component",
          "the package's download URL");
    CHECK(p.sums.url == "https://github.com/JendaT/fb2k-components-mac-suite/releases/download/bpm-v0.1.0/SHA256SUMS",
          "the checksums' URL");
    CHECK(!pickRelease(releases, kRepo, "waveform-seekbar-v", "foo_jl_wave_seekbar.fb2k-component").found,
          "releases without SHA256SUMS are never picked");
}

// What the lookup reads: the tag list, then the newest tag's release
void testTagLookup() {
    TEST_CASE("tag lookup");
    const std::vector<std::string> refs = [JLComponentInstaller refNamesFromJSON:fixture(@"github_matching_refs.json")];
    CHECK(refs.size() == 3, "every ref read");
    const std::vector<std::string> tags = newestTags(refs, "bpm-v", 5);
    CHECK(tags.size() == 1 && tags[0] == "bpm-v0.1.0", "the one X.Y.Z tag");
    const std::vector<Release> one = [JLComponentInstaller releasesFromJSON:fixture(@"github_release_bpm-v0.1.0.json")];
    CHECK(one.size() == 1, "a single release object read as one release");
    const Pick p = pickRelease(one, kRepo, "bpm-v", "foo_jl_bpm.fb2k-component");
    CHECK(p.found && p.tag == "bpm-v0.1.0" && p.package.size == 8986039, "picked from it");
    CHECK([JLComponentInstaller refNamesFromJSON:nil].empty(), "no refs from nothing");
}

void testMalformed() {
    TEST_CASE("malformed");
    auto read = [](NSString *json) { return [JLComponentInstaller releasesFromJSON:[json dataUsingEncoding:NSUTF8StringEncoding]]; };
    CHECK(read(@"{\"message\": \"API rate limit exceeded\"}").empty(), "an error object");
    CHECK(read(@"not json").empty(), "not JSON");
    CHECK([JLComponentInstaller releasesFromJSON:nil].empty(), "nothing");
    const std::vector<Release> odd = read(@"[{\"tag_name\": 5}, {\"tag_name\": \"bpm-v1.0.0\", \"assets\": []}, "
                                          @"{\"tag_name\": \"bpm-v1.0.1\", \"draft\": \"no\", \"prerelease\": false, \"assets\": []}]");
    CHECK(odd.size() == 2, "entries without a tag skipped");
    CHECK(odd.size() == 2 && odd[0].draft && odd[0].prerelease, "missing flags count as draft and prerelease");
    CHECK(odd.size() == 2 && odd[1].draft, "a flag that is not a boolean counts as set");
}

} // namespace

int main() {
    @autoreleasepool {
        testRecordedResponse();
        testTagLookup();
        testMalformed();
    }
    return testsupport::summarize("DependencyReleaseTests");
}
