//
//  DependencyReleaseTests.mm
//  foo_wave_seekbar_mac
//
//  Reading GitHub's release list (JLComponentInstaller releasesFromJSON) and
//  picking BPM Analyzer's release from it: a response recorded from the
//  suite's repository after BPM Analyzer 0.1.0 (fields trimmed to those
//  read), with a newer draft and prerelease added that must be skipped.
//
// TEST_DEPS: ../../shared/jl_dependency/JLComponentInstaller.mm
//

#include "TestSupport.h"
#import "../../../shared/jl_dependency/JLComponentInstaller.h"

using namespace jl_dep;

namespace {

NSData *fixture() {
    NSString *here = [@__FILE__ stringByDeletingLastPathComponent];
    return [NSData dataWithContentsOfFile:[here stringByAppendingPathComponent:@"fixtures/github_releases.json"]];
}

void testRecordedResponse() {
    TEST_CASE("recorded response");
    NSData *data = fixture();
    CHECK(data.length > 0, "fixture read");
    const std::vector<Release> releases = [JLComponentInstaller releasesFromJSON:data];
    CHECK(releases.size() == 58, "every release read");
    const Pick p = pickRelease(releases, "bpm-v", "foo_jl_bpm.fb2k-component");
    CHECK(p.found, "BPM Analyzer found among the suite's releases");
    CHECK(p.tag == "bpm-v0.1.0", "0.1.0, not the newer draft or prerelease");
    CHECK(p.package.size == 8986039, "the package's size");
    CHECK(p.package.url == "https://github.com/JendaT/fb2k-components-mac-suite/releases/download/bpm-v0.1.0/foo_jl_bpm.fb2k-component",
          "the package's download URL");
    CHECK(p.sums.url == "https://github.com/JendaT/fb2k-components-mac-suite/releases/download/bpm-v0.1.0/SHA256SUMS",
          "the checksums' URL");
    CHECK(!pickRelease(releases, "waveform-seekbar-v", "foo_jl_wave_seekbar.fb2k-component").found,
          "releases without SHA256SUMS are never picked");
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
        testMalformed();
    }
    return testsupport::summarize("DependencyReleaseTests");
}
