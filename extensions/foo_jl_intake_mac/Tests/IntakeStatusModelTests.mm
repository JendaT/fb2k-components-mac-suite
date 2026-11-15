//
//  IntakeStatusModelTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeStatusModel (one record per `status --json` row,
//  doc 03 v1.2), including the rows of the mock CLI's `default` (contract
//  v1.2, CLI 0.3.0), `cli-0.2.1` and `no-ranked` scenarios. Synthetic data
//  only; the mock runs with INTAKE_MOCK_STATE in a fresh temp directory.
//
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeLog.mm src/Core/IntakeEnvelope.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeEnvelope.h"
#include "../src/Core/IntakeLog.h"
#include "../src/Core/IntakeStatusModel.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <map>
#include <string>
#include <vector>

using namespace intake;

static std::vector<std::string> g_logLines;

static void captureLog(LogLevel level, const char *message) {
    if (level <= LogLevel::Info) g_logLines.push_back(message ? message : "");
}

static StatusParseResult parse(const char *text) {
    return parseStatusRows(parseJsonValue(text));
}

static const IntakeRecord *byId(const StatusParseResult &r, const std::string &id) {
    for (const IntakeRecord &rec : r.records) {
        if (rec.id == id) return &rec;
    }
    return nullptr;
}

static void testFullRow() {
    g_context = "full-row";
    StatusParseResult r = parse(R"([{"id":"itk_000000a1","root_path":"/income/dump/Fixture Artist - Test Album",
        "status":"proposed","needs_review":true,
        "cluster":{"albumartist":"Fixture Artist","album":"Test Album"},
        "proposal":{"target_collection":"Test Collection A","confidence":0.91,
                    "ranked":[{"collection":"Test Collection A","confidence":0.91},{"collection":"Test Collection B","confidence":0.5}],
                    "assigned_by":"engine","target_path":"/library/Test Collection A/Fixture Artist - Test Album"},
        "placed":null,"future_field":{"x":1}}])");
    CHECK(r.ok, "array parses");
    CHECK_EQ(r.records.size(), 1, "one record");
    CHECK_EQ(r.dropped, 0, "nothing dropped");
    const IntakeRecord &a = r.records[0];
    CHECK(a.id == "itk_000000a1", "id");
    CHECK(a.rootPath == "/income/dump/Fixture Artist - Test Album", "rootPath kept");
    CHECK(a.rootKey == "/income/dump/Fixture Artist - Test Album", "rootKey");
    CHECK(a.status == IntakeStatus::Proposed && a.statusText == "proposed", "status");
    CHECK(a.needsReview, "needs_review");
    CHECK(a.albumartist == "Fixture Artist" && a.album == "Test Album", "cluster");
    CHECK(a.hasProposal, "proposal present");
    CHECK(a.proposal.targetCollection == "Test Collection A", "target_collection");
    CHECK(a.proposal.hasConfidence, "confidence present");
    CHECK_FLOAT_EQ(a.proposal.confidence, 0.91, "confidence value");
    CHECK(a.proposal.rankedState == RankedState::Present, "ranked present");
    CHECK_EQ(a.proposal.ranked.size(), 2, "two candidates");
    CHECK(a.proposal.ranked[1].collection == "Test Collection B", "candidate order kept");
    CHECK_FLOAT_EQ(a.proposal.ranked[1].confidence, 0.5, "candidate confidence");
    CHECK(a.proposal.assignedBy == AssignedBy::Engine, "assigned_by engine");
    CHECK(a.proposal.targetPathState == TargetPathState::Set, "target_path set");
    CHECK(a.proposal.targetPath == "/library/Test Collection A/Fixture Artist - Test Album", "target_path value");
    CHECK(!a.hasPlaced, "placed null");
    CHECK(a.visual.isNone() && a.lastError.empty(), "derived fields start empty");
}

static void testProposalFields() {
    g_context = "proposal-fields";
    StatusParseResult r = parse(R"([
        {"id":"itk_00000001","root_path":"/i/a","status":"proposed","proposal":{"target_collection":"Test Collection A","confidence":1,"ranked":[],"assigned_by":"user","target_path":null}},
        {"id":"itk_00000002","root_path":"/i/b","status":"proposed","proposal":{"target_collection":"Test Collection A","confidence":0.7,"ranked":[{"collection":"Test Collection A","confidence":0.7}]}},
        {"id":"itk_00000003","root_path":"/i/c","status":"resolved","proposal":{"ranked":"nope","assigned_by":"robot","target_path":""}},
        {"id":"itk_00000004","root_path":"/i/d","status":"proposed","proposal":{"ranked":[{"confidence":0.4},7,{"collection":"Test Collection C"}],"assigned_by":null,"target_path":5,"confidence":true}},
        {"id":"itk_00000005","root_path":"/i/e","status":"resolved","proposal":null},
        {"id":"itk_00000006","root_path":"/i/f","status":"resolved"},
        {"id":"itk_00000007","root_path":"/i/g","status":"resolved","proposal":[1]},
        {"id":"itk_00000008","root_path":"/i/h","status":"proposed","proposal":{"ranked":[7,{"confidence":0.4},{"collection":5}]}}
    ])");
    CHECK_EQ(r.records.size(), 8, "eight records");
    const IntakeRecord *user = byId(r, "itk_00000001");
    CHECK(user && user->proposal.assignedBy == AssignedBy::User, "assigned_by user");
    CHECK(user && user->proposal.rankedState == RankedState::Empty, "ranked [] is Empty, not Absent");
    CHECK(user && user->proposal.targetPathState == TargetPathState::Null, "target_path null is Null (slot pending)");
    const IntakeRecord *old = byId(r, "itk_00000002");
    CHECK(old && old->proposal.assignedBy == AssignedBy::Unknown, "absent assigned_by is Unknown (CLI 0.2.1)");
    CHECK(old && old->proposal.targetPathState == TargetPathState::Unknown, "absent target_path is Unknown, not Null");
    const IntakeRecord *odd = byId(r, "itk_00000003");
    CHECK(odd && odd->proposal.rankedState == RankedState::Absent, "a non-array ranked is Absent");
    CHECK(odd && odd->proposal.assignedBy == AssignedBy::Other && odd->proposal.assignedByText == "robot",
          "an unknown assigned_by string is Other");
    CHECK(odd && odd->proposal.targetPathState == TargetPathState::Null, "an empty target_path is Null");
    CHECK(odd && odd->proposal.targetCollection.empty() && !odd->proposal.hasConfidence,
          "missing target_collection and confidence");
    const IntakeRecord *junk = byId(r, "itk_00000004");
    CHECK(junk && junk->proposal.rankedState == RankedState::Present, "a non-empty ranked array is Present");
    CHECK(junk && junk->proposal.ranked.size() == 1 && junk->proposal.ranked[0].collection == "Test Collection C",
          "malformed candidates are skipped");
    CHECK(junk && !junk->proposal.ranked[0].hasConfidence, "a candidate without confidence");
    CHECK(junk && junk->proposal.assignedBy == AssignedBy::Unknown, "assigned_by null is Unknown");
    CHECK(junk && junk->proposal.targetPathState == TargetPathState::Unknown, "a non-string target_path is Unknown");
    CHECK(junk && !junk->proposal.hasConfidence, "a boolean confidence is not a confidence");
    const IntakeRecord *p5 = byId(r, "itk_00000005"), *p6 = byId(r, "itk_00000006"), *p7 = byId(r, "itk_00000007");
    CHECK(p5 && !p5->hasProposal, "proposal null");
    CHECK(p6 && !p6->hasProposal, "proposal missing");
    CHECK(p7 && !p7->hasProposal, "proposal of another type");
    const IntakeRecord *allBad = byId(r, "itk_00000008");
    CHECK(allBad && allBad->proposal.rankedState == RankedState::Absent && allBad->proposal.ranked.empty(),
          "a ranked array with no usable entry is Absent, never Present with nothing in it");
}

static void testFlagsAndPlaced() {
    g_context = "flags-placed";
    StatusParseResult r = parse(R"([
        {"id":"itk_00000001","root_path":"/i/a","status":"placed","needs_review":false,"placed":{"verified":true,"target_path":"/library/a"}},
        {"id":"itk_00000002","root_path":"/i/b","status":"placed","needs_review":"true","placed":{"verified":"true"}},
        {"id":"itk_00000003","root_path":"/i/c","status":"new","needs_review":1},
        {"id":"itk_00000004","root_path":"/i/d","status":"new","needs_review":true,"cluster":{"albumartist":null,"album":7}},
        {"id":"itk_00000005","root_path":"/i/e","status":"placed","placed":{"verified":false,"target_path":"/library/e"}}
    ])");
    const IntakeRecord *a = byId(r, "itk_00000001");
    CHECK(a && a->hasPlaced && a->placedVerified && a->placedTargetPath == "/library/a", "placed verified");
    CHECK(a && !a->needsReview, "needs_review false");
    const IntakeRecord *b = byId(r, "itk_00000002");
    CHECK(b && b->hasPlaced && !b->placedVerified, "a string \"true\" is not verified");
    CHECK(b && !b->needsReview, "a string \"true\" is not needs_review");
    const IntakeRecord *c = byId(r, "itk_00000003");
    CHECK(c && !c->needsReview, "1 is not needs_review");
    const IntakeRecord *d = byId(r, "itk_00000004");
    CHECK(d && d->needsReview, "true is needs_review");
    CHECK(d && d->albumartist.empty() && d->album.empty(), "null or non-string cluster fields are empty");
    const IntakeRecord *e = byId(r, "itk_00000005");
    CHECK(e && e->hasPlaced && !e->placedVerified, "placed verified false");
}

static void testDrops() {
    g_context = "drops";
    g_logLines.clear();
    StatusParseResult r = parse(R"([
        "not an object",
        {"root_path":"/i/a","status":"new"},
        {"id":7,"root_path":"/i/b","status":"new"},
        {"id":"","root_path":"/i/c","status":"new"},
        {"id":"itk_00000004","status":"new"},
        {"id":"itk_00000005","root_path":"relative/path","status":"new"},
        {"id":"itk_00000006","root_path":"~/income/x","status":"new"},
        {"id":"itk_00000007","root_path":"mac-volume://0A1B/income/x","status":"new"},
        {"id":"itk_00000008","root_path":"/i/h"},
        {"id":"itk_00000009","root_path":"/i/i","status":null},
        {"id":"itk_0000000a","root_path":"/i/j","status":3},
        {"id":"itk_0000000b","root_path":"/i/k","status":"new"},
        {"id":"itk_0000000b","root_path":"/i/k2","status":"resolved"},
        {"id":"itk_0000000c","root_path":"/i/l","status":"archived"}
    ])");
    CHECK(r.ok, "ok with bad rows");
    CHECK_EQ(r.dropped, 12, "twelve rows dropped");
    CHECK_EQ(r.records.size(), 2, "two rows kept");
    const IntakeRecord *kept = byId(r, "itk_0000000b");
    CHECK(kept && kept->rootPath == "/i/k" && kept->status == IntakeStatus::New, "the first of a repeated id wins");
    const IntakeRecord *unknown = byId(r, "itk_0000000c");
    CHECK(unknown && unknown->status == IntakeStatus::Unknown, "an unknown status is kept as Unknown");
    CHECK(unknown && unknown->statusText == "archived", "the unknown status text is kept");
    // 12 drops: 10 logged one per line, then one summary line.
    CHECK_EQ(g_logLines.size(), 11, "ten drop lines and a summary");
    CHECK(g_logLines.size() > 5 && g_logLines[5].find("Relative") != std::string::npos,
          "a relative root_path is logged with its status");
    CHECK(!g_logLines.empty() && g_logLines.back().find("12 rows dropped") != std::string::npos, "summary line");

    g_logLines.clear();
    StatusParseResult few = parse(R"([{"id":"itk_00000001","status":"new"}])");
    CHECK_EQ(few.dropped, 1, "one drop");
    CHECK_EQ(g_logLines.size(), 1, "one line, no summary under the limit");
}

static void testDataShapes() {
    g_context = "data-shapes";
    StatusParseResult empty = parse("[]");
    CHECK(empty.ok && empty.records.empty(), "[] is an empty inventory");
    StatusParseResult object = parse(R"({"id":"itk_00000001"})");
    CHECK(!object.ok && !object.error.empty(), "an object is not a status array");
    StatusParseResult none = parseStatusRows(nil);
    CHECK(!none.ok, "nil data is not a status array");
}

static void testPathsAndStatuses() {
    g_context = "paths";
    // NFD on the CLI side (SMB): rootPath keeps the bytes, rootKey is NFC.
    StatusParseResult r = parse("[{\"id\":\"itk_00000001\",\"root_path\":\"/income//dump/Cafe\\u0301 Album/\",\"status\":\"new\"},"
                                "{\"id\":\"itk_00000002\",\"root_path\":\"file:///income/dump/Other\",\"status\":\"new\"}]");
    const IntakeRecord *nfd = byId(r, "itk_00000001");
    CHECK(nfd && nfd->rootPath == "/income//dump/Cafe\xCC\x81 Album/", "rootPath keeps the CLI's NFD bytes and slashes");
    CHECK(nfd && nfd->rootKey == "/income/dump/Caf\xC3\xA9 Album", "rootKey is lexical and NFC");
    const IntakeRecord *url = byId(r, "itk_00000002");
    CHECK(url && url->rootKey == "/income/dump/Other", "a file:// root_path is usable");

    g_context = "statuses";
    const char *words[] = {"new", "resolved", "proposed", "approved", "placing", "placed", "gc_done", "rejected"};
    const IntakeStatus values[] = {IntakeStatus::New, IntakeStatus::Resolved, IntakeStatus::Proposed,
                                   IntakeStatus::Approved, IntakeStatus::Placing, IntakeStatus::Placed,
                                   IntakeStatus::GcDone, IntakeStatus::Rejected};
    int roundTrips = 0;
    for (int i = 0; i < 8; i++) {
        if (intakeStatusFromString(words[i]) == values[i] && std::string(intakeStatusName(values[i])) == words[i]) {
            roundTrips++;
        }
    }
    CHECK_EQ(roundTrips, 8, "every doc 03 status word round-trips");
    CHECK(intakeStatusFromString("Placed") == IntakeStatus::Unknown, "status words are case-sensitive");
    CHECK(intakeStatusFromString("") == IntakeStatus::Unknown, "empty is Unknown");
}

// Records from the mock's `status --json` in `scenario`, or ok=false.
static StatusParseResult mockStatus(const std::string &scenario, std::string *rootOut = nullptr) {
    std::string state = mock::setupState(scenario);
    if (state.empty()) return StatusParseResult();
    if (rootOut) *rootOut = state + "/root";
    std::string out;
    int exitCode = mock::runCapture({mock::mockPath(), "status", "--json"}, mock::mockEnv(state), out);
    EnvelopeResult env = parseEnvelope(out, exitCode);
    if (env.outcome != CliOutcome::Ok) return StatusParseResult();
    return parseStatusRows(env.data);
}

static void testMockDefault() {
    g_context = "mock-default";
    std::string root;
    StatusParseResult r = mockStatus("default", &root);
    CHECK(r.ok, "default status parses");
    CHECK_EQ(r.records.size(), 16, "sixteen roots");
    CHECK_EQ(r.dropped, 0, "nothing dropped");
    std::map<IntakeStatus, int> counts;
    for (const IntakeRecord &rec : r.records) counts[rec.status]++;
    CHECK(counts[IntakeStatus::New] == 2 && counts[IntakeStatus::Resolved] == 5 &&
              counts[IntakeStatus::Proposed] == 4 && counts[IntakeStatus::Approved] == 1 &&
              counts[IntakeStatus::Placing] == 1 && counts[IntakeStatus::Placed] == 1 &&
              counts[IntakeStatus::GcDone] == 1 && counts[IntakeStatus::Rejected] == 1,
          "every lifecycle status is present");
    CHECK(counts[IntakeStatus::Unknown] == 0, "no unknown status");

    const IntakeRecord *a = byId(r, "itk_0000000a");
    CHECK(a && a->rootPath == root + "/income/dump/Fixture Artist - New Album", "root_path under the mock root");
    CHECK(a && !a->hasProposal, "new: no proposal");
    const IntakeRecord *d = byId(r, "itk_0000000d");
    CHECK(d && d->proposal.assignedBy == AssignedBy::Engine, "engine proposal");
    CHECK(d && d->proposal.rankedState == RankedState::Present && d->proposal.ranked.size() == 3, "ranked list");
    CHECK(d && d->proposal.targetPathState == TargetPathState::Set, "v1.2 target_path set");
    const IntakeRecord *f = byId(r, "itk_0000000f");
    CHECK(f && f->proposal.assignedBy == AssignedBy::User && f->needsReview, "user override keeps needs_review");
    CHECK(f && f->proposal.hasConfidence && f->proposal.confidence == 1.0, "user override confidence 1");
    const IntakeRecord *va = byId(r, "itk_00000015");
    CHECK(va && va->status == IntakeStatus::Resolved && va->proposal.targetPathState == TargetPathState::Set &&
              va->proposal.targetPath == root + "/library/music.hq/Fixture Downtempo/[Compilations]/"
                                                "Various Artists - 2026 - Test Compilation",
          "Various Artists (CLI 0.3.0, amendment 003): a [Compilations] target");
    const IntakeRecord *single = byId(r, "itk_00000019");
    CHECK(single && single->status == IntakeStatus::Resolved && single->needsReview && single->album.empty() &&
              single->proposal.targetPathState == TargetPathState::Null,
          "the single: target_path null (the singles slot)");
    const IntakeRecord *pick = byId(r, "itk_00000018");
    CHECK(pick && pick->proposal.rankedState == RankedState::Empty, "user-only proposal: ranked []");
    const IntakeRecord *loose = byId(r, "itk_00000016");
    CHECK(loose && loose->status == IntakeStatus::New && loose->needsReview, "new root with needs_review");
    const IntakeRecord *loose2 = byId(r, "itk_00000017");
    CHECK(loose && loose2 && loose->rootKey == loose2->rootKey, "two virtual roots share one root_path");
    const IntakeRecord *placed = byId(r, "itk_00000012");
    CHECK(placed && placed->hasPlaced && placed->placedVerified, "placed verified");
}

static void testMockOld() {
    g_context = "mock-cli-0.2.1";
    StatusParseResult r = mockStatus("cli-0.2.1");
    CHECK(r.ok && r.records.size() == 15 && r.dropped == 0, "cli-0.2.1 status parses all fifteen");
    int unknownAssigned = 0, unknownTarget = 0, proposals = 0;
    for (const IntakeRecord &rec : r.records) {
        if (!rec.hasProposal) continue;
        proposals++;
        if (rec.proposal.assignedBy == AssignedBy::Unknown) unknownAssigned++;
        if (rec.proposal.targetPathState == TargetPathState::Unknown) unknownTarget++;
    }
    CHECK(proposals > 0 && unknownAssigned == proposals, "assigned_by Unknown on every 0.2.1 proposal");
    CHECK(proposals > 0 && unknownTarget == proposals, "target_path Unknown on every 0.2.1 proposal");
    const IntakeRecord *va = byId(r, "itk_00000015");
    CHECK(va && va->proposal.targetPathState == TargetPathState::Unknown,
          "Various Artists on 0.2.1: unknown, not slot pending");
    const IntakeRecord *f = byId(r, "itk_0000000f");
    CHECK(f && f->needsReview && f->proposal.hasConfidence, "0.2.1 override still parses");

    g_context = "mock-no-ranked";
    StatusParseResult nr = mockStatus("no-ranked");
    const IntakeRecord *d = byId(nr, "itk_0000000d");
    CHECK(nr.ok && d && d->hasProposal && d->proposal.rankedState == RankedState::Absent,
          "no-ranked: ranked Absent");
}

int main(void) {
    atexit(mock::removeTempRoot);
    setLogBackend(captureLog);
    setLogLevel(LogLevel::Info);
    @autoreleasepool {
        testFullRow();
        testProposalFields();
        testFlagsAndPlaced();
        testDrops();
        testDataShapes();
        testPathsAndStatuses();
        testMockDefault();
        testMockOld();
    }
    setLogBackend(nullptr);
    mock::removeTempRoot();
    TEST_MAIN_END();
}
