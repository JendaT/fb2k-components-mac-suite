//
//  IntakeProposeChainTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeProposeChain (B12: a propose of many roots in chunks
//  of 5): add (order, repeats against pending, in-flight and handled roots,
//  the total), nextChunk (the size, the current status re-check, skipped
//  roots and their Debug line, nothing while a chunk is in flight), record
//  (done and failed per root, roots the call did not name), the stop
//  decision per envelope outcome (the hard-cap kill through
//  interpretProcessResult), the end's ActivityResult (all done, partial,
//  total failure, skipped roots, a chunk error that failed no root), the
//  progress for the status bar's n/m and the chunk numbers. Also through
//  summarizeMutation on synthetic envelopes and the ActivityModel texts, as
//  Integration uses them. Synthetic ids, paths and labels only.
//
// TEST_DEPS: src/Core/IntakeMutationResult.mm src/Core/IntakeEnvelope.mm src/Core/IntakeErrorMap.mm
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeLog.mm src/Core/IntakeCommandArgs.mm
// TEST_DEPS: src/Core/IntakeSemver.mm src/Core/IntakeSettingsParse.mm src/Core/IntakeStatusModel.mm
// TEST_DEPS: src/Core/IntakeRootErrors.mm src/Core/IntakeActivity.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeProposeChain.h"
#include "TestHarness.h"

#include <cstdio>
#include <initializer_list>
#include <map>
#include <string>
#include <vector>

using namespace intake;

namespace {

const std::string kDots = "\xE2\x80\xA6";  // U+2026

std::string idFor(int n) {
    char buf[16];
    snprintf(buf, sizeof buf, "itk_%08d", n);
    return buf;
}

MutationRoot root(const std::string &id, IntakeStatus status = IntakeStatus::Resolved) {
    return MutationRoot{id, "/income/fixture/" + id, status, std::string()};
}

std::vector<MutationRoot> roots(std::initializer_list<int> numbers) {
    std::vector<MutationRoot> out;
    for (int n : numbers) out.push_back(root(idFor(n)));
    return out;
}

std::vector<MutationRoot> range(int from, int to) {
    std::vector<MutationRoot> out;
    for (int n = from; n <= to; n++) out.push_back(root(idFor(n)));
    return out;
}

std::vector<std::string> ids(std::initializer_list<int> numbers) {
    std::vector<std::string> out;
    for (int n : numbers) out.push_back(idFor(n));
    return out;
}

// Every root resolved, except those listed (a status, or missing).
struct Statuses {
    std::map<std::string, std::optional<IntakeStatus>> except;
    ProposeStatusOf fn() const {
        return [this](const std::string &id) -> std::optional<IntakeStatus> {
            auto it = except.find(id);
            if (it == except.end()) return IntakeStatus::Resolved;
            return it->second;
        };
    }
};

const ProposeStatusOf kAllResolved = [](const std::string &) -> std::optional<IntakeStatus> {
    return IntakeStatus::Resolved;
};

MutationOutcome succeededAll(const ProposeChunk &chunk) {
    MutationOutcome o;
    o.succeeded = chunk.ids();
    o.consoleLine = "propose: done for " + std::to_string(chunk.roots.size()) + " roots";
    return o;
}

CliError err(const char *code, const char *msg, const std::string &path = std::string()) {
    CliError e;
    e.code = code;
    e.msg = msg;
    e.path = path;
    e.hasPath = !path.empty();
    return e;
}

EnvelopeResult env(CliOutcome outcome, NSArray *data, std::vector<CliError> errors = {}) {
    EnvelopeResult r;
    r.outcome = outcome;
    r.data = data;
    r.errors = std::move(errors);
    return r;
}

NSArray *rows(const std::vector<std::string> &list) {
    NSMutableArray *out = [NSMutableArray array];
    for (const std::string &id : list) [out addObject:@{@"id" : @(id.c_str())}];
    return out;
}

} // anonymous namespace

static void testAdd() {
    g_context = "add";
    ProposeChain c;
    CHECK(c.firstRoot() == nullptr && c.total() == 0 && c.finished(), "empty chain");
    CHECK_EQ(c.add(roots({1, 2, 3, 2, 4, 5, 6})), 6, "a repeat in the input counts once");
    CHECK_EQ(c.total(), 6, "total");
    CHECK(c.pendingIds() == ids({1, 2, 3, 4, 5, 6}), "pending in the order added");
    CHECK(c.firstRoot() != nullptr && c.firstRoot()->id == idFor(1), "the first root (the status bar's label)");
    CHECK_EQ(c.add({MutationRoot{"", "/income/fixture/x", IntakeStatus::Resolved, ""}}), 0, "an empty id is ignored");

    struct Row {
        const char *what;
        std::vector<MutationRoot> join;
        size_t added;
        size_t total;
    };
    // After the first chunk: 1..5 in flight, 6 pending; then 1 and 2 done,
    // 3 failed, 4 and 5 skipped would be handled.
    ProposeChain d;
    d.add(range(1, 6));
    const ProposeChunk first = d.nextChunk(kAllResolved);
    const Row table[] = {
        {"a root in flight", roots({3}), 0, 6},
        {"a pending root", roots({6}), 0, 6},
        {"two new, one in flight", roots({7, 1, 8}), 2, 8},
        {"nothing new", roots({7, 8}), 0, 8},
    };
    for (const Row &row : table) {
        g_context = std::string("add/") + row.what;
        CHECK_EQ(d.add(row.join), row.added, "added");
        CHECK_EQ(d.total(), row.total, "total");
    }
    g_context = "add/handled";
    MutationOutcome partial;
    partial.succeeded = ids({1, 2, 4, 5});
    partial.rootErrors.push_back({idFor(3), "propose: No target found"});
    d.record(first.roots, partial);
    CHECK_EQ(d.add(roots({1, 3, 9})), 1, "done and failed roots do not join again");
    Statuses gone;
    gone.except[idFor(6)] = IntakeStatus::Proposed;
    d.nextChunk(gone.fn());
    CHECK_EQ(d.add(roots({6})), 0, "a skipped root does not join again");
    CHECK_EQ(d.total(), 9, "the total counts every root added");
    CHECK(d.firstRoot()->id == idFor(1), "the first root stays");
}

static void testNextChunk() {
    g_context = "next-chunk";
    struct Row {
        const char *what;
        std::vector<MutationRoot> add;
        std::map<std::string, std::optional<IntakeStatus>> except;
        std::vector<std::string> chunk;
        std::vector<std::string> skipped;
        std::vector<std::string> pendingAfter;
    };
    const Row table[] = {
        {"five of seven", range(1, 7), {}, ids({1, 2, 3, 4, 5}), {}, ids({6, 7})},
        {"fewer than five", range(1, 3), {}, ids({1, 2, 3}), {}, {}},
        {"skipped roots are passed over",
         range(1, 8),
         {{idFor(2), IntakeStatus::Proposed}, {idFor(4), std::nullopt}},
         ids({1, 3, 5, 6, 7}),
         {idFor(2) + " (proposed)", idFor(4) + " (not in the view)"},
         ids({8})},
        {"every other status is skipped",
         range(1, 6),
         {{idFor(1), IntakeStatus::New},
          {idFor(2), IntakeStatus::Approved},
          {idFor(3), IntakeStatus::Rejected},
          {idFor(4), IntakeStatus::Unknown}},
         ids({5, 6}),
         {idFor(1) + " (new)", idFor(2) + " (approved)", idFor(3) + " (rejected)", idFor(4) + " (unknown)"},
         {}},
        {"all skipped", range(1, 2), {{idFor(1), std::nullopt}, {idFor(2), IntakeStatus::Placed}}, {},
         {idFor(1) + " (not in the view)", idFor(2) + " (placed)"}, {}},
    };
    for (const Row &row : table) {
        g_context = std::string("next-chunk/") + row.what;
        ProposeChain c;
        c.add(row.add);
        Statuses s;
        s.except = row.except;
        const ProposeChunk chunk = c.nextChunk(s.fn());
        CHECK(chunk.ids() == row.chunk, "the chunk's ids");
        CHECK(chunk.skipped == row.skipped, "skipped, with why");
        CHECK(c.pendingIds() == row.pendingAfter, "pending after");
        CHECK_EQ(c.skipped().size(), row.skipped.size(), "skipped roots are handled");
        CHECK_EQ(chunk.number, row.chunk.empty() ? 0 : 1, "its number");
        bool baseline = true;
        for (const MutationRoot &r : chunk.roots) baseline = baseline && r.status == IntakeStatus::Resolved;
        CHECK(baseline, "chunk roots carry status Resolved");
        CHECK(row.chunk.empty() ? !c.inFlight() : c.inFlight(), "in flight when not empty");
    }

    g_context = "next-chunk/line";
    ProposeChain c;
    c.add(range(1, 3));
    Statuses s;
    s.except[idFor(1)] = IntakeStatus::Proposed;
    s.except[idFor(3)] = std::nullopt;
    ProposeChunk chunk = c.nextChunk(s.fn());
    CHECK(chunk.skippedLine == "propose: skipped 2 roots no longer resolved: " + idFor(1) + " (proposed), " +
                                   idFor(3) + " (not in the view)",
          "one Debug line for the skipped");
    ProposeChain one;
    one.add(range(1, 2));
    Statuses s1;
    s1.except[idFor(1)] = IntakeStatus::New;
    CHECK(one.nextChunk(s1.fn()).skippedLine == "propose: skipped 1 root no longer resolved: " + idFor(1) + " (new)",
          "singular");
    ProposeChain none;
    none.add(range(1, 2));
    CHECK(none.nextChunk(kAllResolved).skippedLine.empty(), "nothing skipped: no line");

    g_context = "next-chunk/in-flight";
    ProposeChain f;
    f.add(range(1, 12));
    const ProposeChunk a = f.nextChunk(kAllResolved);
    const ProposeChunk b = f.nextChunk(kAllResolved);
    CHECK(a.roots.size() == 5 && b.roots.empty() && b.number == 0, "nothing while a chunk is in flight");
    CHECK_EQ(f.pendingCount(), 7, "the pending roots stay");
    f.record(a.roots, succeededAll(a));
    const ProposeChunk next = f.nextChunk(kAllResolved);
    CHECK(next.number == 2 && next.ids() == ids({6, 7, 8, 9, 10}), "the second chunk, in order");

    g_context = "next-chunk/no-lookup";
    ProposeChain n;
    n.add(range(1, 2));
    const ProposeChunk empty = n.nextChunk(ProposeStatusOf());
    CHECK(empty.roots.empty() && n.skipped().size() == 2 && n.finished(), "no lookup: every root missing");
}

static void testRecord() {
    g_context = "record";
    ProposeChain c;
    c.add(range(1, 7));
    const ProposeChunk chunk = c.nextChunk(kAllResolved);
    MutationOutcome o;
    o.succeeded = ids({1, 3, 5});
    o.rootErrors.push_back({idFor(2), "propose: No target found"});
    o.failedWithoutError.push_back(idFor(4));
    o.isError = true;
    c.record(chunk.roots, o);
    CHECK(c.succeeded() == ids({1, 3, 5}), "done: in data");
    CHECK(c.failed() == ids({2, 4}), "failed: the rest, in order");
    CHECK(!c.inFlight() && c.chunksRecorded() == 1, "nothing in flight after");
    CHECK_EQ(c.done(), 5, "done counts handled roots");
    CHECK_EQ(c.named(), 5, "named: done and failed");

    g_context = "record/not-named";
    ProposeChain d;
    d.add(range(1, 7));
    const ProposeChunk dc = d.nextChunk(kAllResolved);
    // The call named only the first three (a caller bug): the other two go
    // back to the front.
    const std::vector<MutationRoot> named(dc.roots.begin(), dc.roots.begin() + 3);
    MutationOutcome ok;
    ok.succeeded = ids({1, 2, 3});
    d.record(named, ok);
    CHECK(d.pendingIds() == ids({4, 5, 6, 7}), "roots in flight the call did not name are pending again");
    CHECK_EQ(d.done(), 3, "only the named ones are handled");

    g_context = "record/nothing-in-flight";
    ProposeChain e;
    e.add(range(1, 2));
    e.record(roots({1}), ok);
    CHECK(e.done() == 0 && e.chunksRecorded() == 0 && e.pendingCount() == 2, "ignored");

    g_context = "record/summary";
    // As Integration calls it: summarizeMutation on the chunk's envelope.
    ProposeChain s;
    s.add(range(1, 6));
    const ProposeChunk sc = s.nextChunk(kAllResolved);
    const EnvelopeResult partial =
        env(CliOutcome::Partial, rows(ids({1, 2, 4, 5})),
            {err("E_NO_TARGET", "no collection matched", "/income/fixture/" + idFor(3))});
    const MutationOutcome po = summarizeMutation(CliCommand::Propose, sc.roots, partial);
    s.record(sc.roots, po);
    CHECK(s.succeeded() == ids({1, 2, 4, 5}) && s.failed() == ids({3}), "exit 1: the subset in data");
    CHECK(!proposeChainStopFor(partial).stop, "and the chain goes on");
}

static void testStop() {
    g_context = "stop";
    struct Row {
        const char *what;
        CliOutcome outcome;
        std::vector<CliError> errors;
        bool stop;
        std::string reason;
    };
    const Row table[] = {
        {"ok", CliOutcome::Ok, {}, false, ""},
        {"per-root errors (exit 1)", CliOutcome::Partial, {err("E_BAD_STATUS", "cannot propose", "/x")}, false, ""},
        {"other envelope errors (exit 2)", CliOutcome::Failed, {err("E_NO_RULES", "rules folder missing")}, false, ""},
        {"E_INTERNAL (exit 2)", CliOutcome::Failed, {err("E_INTERNAL", "boom")}, false, ""},
        {"hard cap", CliOutcome::Timeout, {err("E_CLI_TIMEOUT", "still running at the hard cap; terminated")}, true,
         "the chunk was terminated at the 15-minute cap"},
        {"E_NO_CLI", CliOutcome::NoCli, {err("E_NO_CLI", "exit code 127")}, true,
         "Intake CLI not available: exit code 127"},
        {"E_NO_CLI without an entry", CliOutcome::NoCli, {}, true, "E_NO_CLI"},
        {"cancelled", CliOutcome::Cancelled, {}, true, "the chunk was cancelled"},
    };
    for (const Row &row : table) {
        g_context = std::string("stop/") + row.what;
        const ProposeChainStop s = proposeChainStopFor(env(row.outcome, nil, row.errors));
        CHECK(s.stop == row.stop, "stop or go on");
        CHECK(s.reason == row.reason, "reason");
    }

    g_context = "stop/hard-cap-process";
    // The structured flags the runner sets for the hard-cap kill.
    ProcessResult killed;
    killed.end = ProcessEnd::Signaled;
    killed.termSignal = 15;
    killed.budgetExceeded = true;
    killed.killedForTimeout = true;
    killed.hardCapHit = true;
    const EnvelopeResult capped = interpretProcessResult(killed);
    CHECK(capped.outcome == CliOutcome::Timeout, "the hard-cap kill is outcome Timeout");
    CHECK(proposeChainStopFor(capped).stop, "it stops the chain");
    ProcessResult late;
    late.end = ProcessEnd::Exited;
    late.exitCode = 0;
    late.budgetExceeded = true;  // ran past 10 s, exited on its own
    late.stdoutData = "{\"ok\":true,\"errors\":[],\"data\":[]}";
    CHECK(!proposeChainStopFor(interpretProcessResult(late)).stop, "past the 10 s budget but exited: go on");
    ProcessResult spawn;
    spawn.end = ProcessEnd::SpawnFailed;
    spawn.spawnStage = "spawn";
    spawn.spawnErrno = 2;
    CHECK(proposeChainStopFor(interpretProcessResult(spawn)).stop, "a failed spawn (E_NO_CLI) stops it");
}

static void testResult() {
    g_context = "result";
    // 49 roots: 10 chunks, each handed out against a view where every root
    // is resolved; `fail` names the roots whose propose failed.
    auto run = [](size_t count, const std::map<std::string, std::string> &fail,
                  const std::map<std::string, std::optional<IntakeStatus>> &except) {
        ProposeChain c;
        c.add(range(1, static_cast<int>(count)));
        Statuses s;
        s.except = except;
        for (;;) {
            const ProposeChunk chunk = c.nextChunk(s.fn());
            if (chunk.roots.empty()) break;
            MutationOutcome o;
            for (const MutationRoot &r : chunk.roots) {
                auto f = fail.find(r.id);
                if (f == fail.end()) {
                    o.succeeded.push_back(r.id);
                } else {
                    o.rootErrors.push_back({r.id, f->second});
                    o.isError = true;
                }
            }
            o.consoleLine = "propose: done for some";
            c.record(chunk.roots, o);
        }
        return c;
    };

    ProposeChain all = run(49, {}, {});
    ActivityResult r = all.result();
    CHECK(all.finished() && all.chunksRecorded() == 10, "49 roots in 10 chunks");
    CHECK(r.succeeded && r.reason.empty(), "all done: succeeded");
    CHECK(all.summaryLine() == "propose: done for 49 roots in 10 chunks", "the summary line");

    const std::map<std::string, std::string> three = {{idFor(7), "propose: No target found"},
                                                      {idFor(23), "propose: No target found"},
                                                      {idFor(41), "propose: Not allowed in the current state"}};
    ProposeChain partial = run(49, three, {});
    r = partial.result();
    CHECK(!r.succeeded && r.reason == "3 of 49 albums", "partial: Propose failed: 3 of 49 albums");
    CHECK(r.detail == "propose: done for 46 of 49 roots in 10 chunks; failed: " + idFor(7) + " " + idFor(23) + " " +
                          idFor(41),
          "its detail names the failed roots");

    std::map<std::string, std::string> everyone;
    for (int n = 1; n <= 7; n++) everyone[idFor(n)] = "propose: No target found";
    ProposeChain none = run(7, everyone, {});
    r = none.result();
    CHECK(!r.succeeded && r.reason == "No target found", "every root failed: the first root's error");

    ProposeChain skipped = run(12, {{idFor(3), "propose: No target found"}},
                               {{idFor(5), IntakeStatus::Proposed}, {idFor(9), std::nullopt}});
    r = skipped.result();
    CHECK(skipped.named() == 10 && !r.succeeded && r.reason == "1 of 10 albums", "skipped roots count neither way");
    CHECK(skipped.summaryLine() == "propose: done for 9 of 10 roots in 2 chunks; failed: " + idFor(3) +
                                       "; skipped (no longer resolved): " + idFor(5) + " " + idFor(9),
          "the skipped in the summary");

    ProposeChain onlySkipped = run(6, {}, {{idFor(2), IntakeStatus::Proposed}});
    CHECK(onlySkipped.result().succeeded, "a skipped root is no failure");

    g_context = "result/chunk-error";
    // A chunk whose call reported an error but failed no root (exit 1 with
    // every id in data).
    ProposeChain c;
    c.add(range(1, 6));
    ProposeChunk chunk = c.nextChunk(kAllResolved);
    const EnvelopeResult odd = env(CliOutcome::Partial, rows(chunk.ids()), {err("E_JOURNAL", "journal lagging")});
    c.record(chunk.roots, summarizeMutation(CliCommand::Propose, chunk.roots, odd));
    chunk = c.nextChunk(kAllResolved);
    c.record(chunk.roots, succeededAll(chunk));
    r = c.result();
    CHECK(!r.succeeded, "the chunk's error keeps the cross");
    CHECK(r.reason == "E_JOURNAL: journal lagging" || r.reason == "journal lagging", "its own reason");
    CHECK(c.summaryLine().find("propose: done for 6 roots in 2 chunks; ") == 0, "the summary, then the reason");

    g_context = "result/without-error";
    // Every failed root failed without an error (a cancelled call).
    ProposeChain w;
    w.add(range(1, 6));
    chunk = w.nextChunk(kAllResolved);
    w.record(chunk.roots, summarizeMutation(CliCommand::Propose, chunk.roots, env(CliOutcome::Cancelled, nil)));
    r = w.result();
    CHECK(!r.succeeded && !r.reason.empty() && r.reason.find("failed:") == std::string::npos,
          "the first failing chunk's reason, not the summary's list");
}

static void testProgress() {
    g_context = "progress";
    ProposeChain c;
    c.add(range(1, 12));
    ProposeChainProgress p = c.progress();
    CHECK(p.done == 0 && p.total == 12 && p.current.id.empty(), "nothing yet");
    ProposeChunk chunk = c.nextChunk(kAllResolved);
    p = c.progress();
    CHECK(p.done == 0 && p.current.id.empty(), "the first chunk: no current root (the plain line)");
    CHECK(c.chunksStarted() == 1 && c.chunkCount() == 3, "chunk 1 of 3");
    c.record(chunk.roots, succeededAll(chunk));
    p = c.progress();
    CHECK(p.done == 5 && p.total == 12 && p.current.id.empty(), "between chunks: 5/12, no current root");
    chunk = c.nextChunk(kAllResolved);
    p = c.progress();
    CHECK(p.done == 5 && p.current.id == idFor(6) && p.current.rootPath == "/income/fixture/" + idFor(6),
          "the second chunk: its first root");
    CHECK(c.chunksStarted() == 2 && c.chunkCount() == 3, "chunk 2 of 3");
    c.add(range(13, 20));
    p = c.progress();
    CHECK(p.total == 20 && c.chunkCount() == 4, "roots join: the total and the estimate grow");

    g_context = "progress/skipped";
    ProposeChain s;
    s.add(range(1, 8));
    Statuses st;
    st.except[idFor(1)] = IntakeStatus::Proposed;
    st.except[idFor(2)] = IntakeStatus::Proposed;
    st.except[idFor(3)] = IntakeStatus::Proposed;
    chunk = s.nextChunk(st.fn());
    p = s.progress();
    CHECK(p.done == 3 && p.current.id == idFor(4), "skipped roots count as done");
    CHECK(s.chunkCount() == 1, "the estimate shrinks");

    g_context = "progress/not-proposed";
    ProposeChain q;
    q.add(range(1, 8));
    q.nextChunk(kAllResolved);
    CHECK(q.notProposed() == ids({1, 2, 3, 4, 5, 6, 7, 8}), "a refused chunk: in flight, then pending");
    CHECK(q.pendingIds() == ids({6, 7, 8}), "pending only (quit: the chunk in flight runs on)");
}

// The status bar texts the chain's entry goes through (ActivityModel).
static void testStatusBarTexts() {
    g_context = "status-bar";
    const std::string first = "Fixture Artist \xE2\x80\x93 First";
    const std::string current = "Fixture Artist \xE2\x80\x93 Tenth";
    ActivityModel m;
    m.begin(activityChainKey(1), ActivityKind::Propose, 49, first, 0);
    CHECK(m.line(0) && m.line(0)->text == "Proposing 49 albums" + kDots, "before the first chunk ends");
    // The first chunk: progress with no current root keeps the plain line.
    m.progress(activityChainKey(1), 0, 49, "");
    CHECK(m.line(0)->text == "Proposing 49 albums" + kDots, "the first chunk runs");
    m.progress(activityChainKey(1), 10, 49, current);
    CHECK(m.line(0)->text == "Proposing 10/49: " + current && m.line(0)->done == 10 && m.line(0)->total == 49,
          "Proposing 10/49: Artist – Album");
    m.rename(activityChainKey(1), ActivityKind::Propose, 55, first);
    m.progress(activityChainKey(1), 10, 55, current);
    CHECK(m.line(0)->text == "Proposing 10/55: " + current, "roots joined: the new total");
    ActivityResult failed3;
    failed3.succeeded = false;
    failed3.reason = "3 of 49 albums";
    m.end(activityChainKey(1), failed3, 1);
    CHECK(m.line(1)->text == "Propose failed: 3 of 49 albums" && m.line(1)->icon == ActivityIcon::Cross,
          "a partial failure shows a cross");
    ActivityModel ok;
    ok.begin(activityChainKey(2), ActivityKind::Propose, 49, first, 0);
    ok.end(activityChainKey(2), ActivityResult(), 1, 49);
    CHECK(ok.line(1)->text == "Proposed 49 albums" && ok.line(1)->icon == ActivityIcon::Check, "all done");
    CHECK(activityChainKey(2) == "chain:2" && activityChainKey(2) != activityLaneKey(2), "its own key space");
}

int main() {
    @autoreleasepool {
        testAdd();
        testNextChunk();
        testRecord();
        testStop();
        testResult();
        testProgress();
        testStatusBarTexts();
    }
    TEST_MAIN_END();
}
