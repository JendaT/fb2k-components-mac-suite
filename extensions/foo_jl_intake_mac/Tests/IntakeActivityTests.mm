//
//  IntakeActivityTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeActivity (the status bar's activity model, B14) with
//  a fake clock: the running and result texts of every kind (singular,
//  plural, an album's label, UTF-8 labels and their cut on a character
//  boundary, never inside a composed character sequence), the 10 s result
//  window to the millisecond, the order of the list, " (+N more)", progress
//  (n/m), rename, keys (begin and end by lane token, run stem, swap serial;
//  unknown and double ends), clear, activityResultFor over hand-built
//  outcomes, deadlines (the execute dry run's 15 minutes),
//  activityAfterAssign and activityReadsResult.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeActivity.h"
#include "TestHarness.h"

#include <string>

using namespace intake;

static const std::string kDots = "\xE2\x80\xA6";   // U+2026
static const std::string kDash = "\xE2\x80\x93";   // U+2013 (albumLabel's)

static std::string lineText(const ActivityModel &m, int64_t now) {
    std::optional<ActivityLine> line = m.line(now);
    return line ? line->text : std::string("(none)");
}

static bool validUtf8(const std::string &s) {
    NSString *ns = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return ns != nil;
}

static ActivityResult failed(const std::string &reason, const std::string &detail = std::string()) {
    ActivityResult r;
    r.succeeded = false;
    r.reason = reason;
    r.detail = detail;
    return r;
}

// The running text of one entry of `kind`.
static std::string runningText(ActivityKind kind, size_t count, const std::string &label) {
    ActivityModel m;
    m.begin("k", kind, count, label, 0);
    return lineText(m, 0);
}

// The result text of one entry of `kind`.
static std::string resultText(ActivityKind kind, size_t count, const std::string &label, const ActivityResult &r) {
    ActivityModel m;
    m.begin("k", kind, count, label, 0);
    m.end("k", r, 5);
    return lineText(m, 5);
}

static void testKeys() {
    g_context = "keys";
    CHECK(activityLaneKey(7) == "lane:7", "lane key");
    CHECK(activityRunKey("execute-20261124-1") == "run:execute-20261124-1", "run key");
    CHECK(activitySwapKey(7) == "swap:7", "swap key");
    CHECK(activityCensusKey(7) == "census:7", "census key");
    CHECK(activityLaneKey(7) != activitySwapKey(7) && activitySwapKey(7) != activityCensusKey(7),
          "the same number in two spaces gives two keys");

    ActivityKind k = ActivityKind::Swap;
    CHECK(activityKindFor(CliCommand::Propose, false, k) && k == ActivityKind::Propose, "propose");
    CHECK(activityKindFor(CliCommand::Assign, false, k) && k == ActivityKind::Assign, "assign");
    CHECK(activityKindFor(CliCommand::Approve, false, k) && k == ActivityKind::Approve, "approve");
    CHECK(activityKindFor(CliCommand::Reject, false, k) && k == ActivityKind::Reject, "reject");
    CHECK(activityKindFor(CliCommand::Execute, true, k) && k == ActivityKind::ExecuteDryRun, "execute dry run");
    CHECK(activityKindFor(CliCommand::Execute, false, k) && k == ActivityKind::Execute, "execute");
    CHECK(activityKindFor(CliCommand::Resume, false, k) && k == ActivityKind::Resume, "resume");
    CHECK(activityKindFor(CliCommand::Gc, false, k) && k == ActivityKind::Gc, "gc");
    CHECK(!activityKindFor(CliCommand::Status, false, k) && !activityKindFor(CliCommand::Version, false, k) &&
              !activityKindFor(CliCommand::Collections, false, k) && !activityKindFor(CliCommand::Income, false, k),
          "read-only commands are no entries");
}

static void testRunningTexts() {
    g_context = "running-texts";
    const std::string album = "Fixture Artist" + kDash + "Fixture Album";
    CHECK(runningText(ActivityKind::Propose, 3, album) == "Proposing 3 albums" + kDots, "propose, 3");
    CHECK(runningText(ActivityKind::Propose, 1, album) == "Proposing " + album + kDots, "propose, one: its label");
    CHECK(runningText(ActivityKind::Propose, 1, "") == "Proposing 1 album" + kDots, "one without a label: 1 album");
    CHECK(runningText(ActivityKind::Assign, 2, album) == "Assigning 2 albums" + kDots, "assign");
    CHECK(runningText(ActivityKind::AssignThenPropose, 2, album) == "Proposing 2 albums" + kDots,
          "the propose after an assign");
    CHECK(runningText(ActivityKind::Approve, 4, album) == "Approving 4 albums" + kDots, "approve");
    CHECK(runningText(ActivityKind::Reject, 1, album) == "Rejecting " + album + kDots, "reject, one");
    CHECK(runningText(ActivityKind::ExecuteDryRun, 3, album) == "Checking placement of 3 albums" + kDots,
          "execute dry run");
    CHECK(runningText(ActivityKind::Execute, 40, album) == "Placing 40 albums" + kDots, "execute, no progress yet");
    CHECK(runningText(ActivityKind::Execute, 1, album) == "Placing " + album + kDots, "execute, one");
    CHECK(runningText(ActivityKind::Resume, 5, album) == "Resuming placement of 5 albums" + kDots, "resume");
    CHECK(runningText(ActivityKind::Gc, 3, album) == "Deleting local copies of 3 albums" + kDots, "gc");
    CHECK(runningText(ActivityKind::DeleteCensus, 2, album) == "Counting playlist rows for 2 albums" + kDots,
          "delete census");
    CHECK(runningText(ActivityKind::Swap, 12, "") == "Swapping 12 playlist rows" + kDots, "swap counts rows");
    CHECK(runningText(ActivityKind::Swap, 1, album) == "Swapping 1 playlist row" + kDots,
          "swap of one row: never a label");

    ActivityModel m;
    m.begin("k", ActivityKind::Propose, 3, album, 100);
    std::optional<ActivityLine> line = m.line(100);
    CHECK(line && line->state == ActivityState::Running && line->icon == ActivityIcon::None, "running: no icon");
    CHECK(line && line->done == 0 && line->total == 0, "propose: no progress bar");
    m.begin("e", ActivityKind::Execute, 40, album, 101);
    line = m.line(101);
    CHECK(line && line->done == 0 && line->total == 40, "execute: 0/40 from the start");
}

static void testResultTexts() {
    g_context = "result-texts";
    const std::string album = "Fixture Artist" + kDash + "Fixture Album";
    const ActivityResult ok;
    CHECK(resultText(ActivityKind::Propose, 3, album, ok) == "Proposed 3 albums", "proposed");
    CHECK(resultText(ActivityKind::Propose, 1, album, ok) == "Proposed " + album, "proposed, one");
    CHECK(resultText(ActivityKind::Assign, 3, album, ok) == "Assigned 3 albums", "assigned");
    CHECK(resultText(ActivityKind::AssignThenPropose, 2, album, ok) == "Assigned and proposed 2 albums",
          "assigned and proposed");
    CHECK(resultText(ActivityKind::Approve, 3, album, ok) == "Approved 3 albums", "approved");
    CHECK(resultText(ActivityKind::Reject, 3, album, ok) == "Rejected 3 albums", "rejected");
    CHECK(resultText(ActivityKind::ExecuteDryRun, 3, album, ok) == "Checked placement of 3 albums", "checked");
    CHECK(resultText(ActivityKind::Execute, 40, album, ok) == "Placed 40 albums", "placed");
    CHECK(resultText(ActivityKind::Resume, 2, album, ok) == "Resumed placement of 2 albums", "resumed");
    CHECK(resultText(ActivityKind::Gc, 3, album, ok) == "Deleted local copies of 3 albums", "deleted");
    CHECK(resultText(ActivityKind::DeleteCensus, 3, album, ok) == "Counted playlist rows for 3 albums", "counted");
    CHECK(resultText(ActivityKind::Swap, 12, "", ok) == "Swapped 12 playlist rows", "swapped");

    CHECK(resultText(ActivityKind::Execute, 5, album, failed("target path already exists")) ==
              "Execute failed: target path already exists",
          "execute failed");
    CHECK(resultText(ActivityKind::Propose, 2, album, failed("1 of 2 albums")) == "Propose failed: 1 of 2 albums",
          "propose failed");
    CHECK(resultText(ActivityKind::AssignThenPropose, 2, album, failed("x")) == "Propose failed: x",
          "the propose after an assign failed");
    CHECK(resultText(ActivityKind::ExecuteDryRun, 2, album, failed("x")) == "Placement check failed: x",
          "placement check failed");
    CHECK(resultText(ActivityKind::Resume, 2, album, failed("x")) == "Resume failed: x", "resume failed");
    CHECK(resultText(ActivityKind::Gc, 2, album, failed("x")) == "Delete failed: x", "delete failed");
    CHECK(resultText(ActivityKind::DeleteCensus, 2, album, failed("x")) == "Row count failed: x", "count failed");
    CHECK(resultText(ActivityKind::Swap, 2, "", failed("")) == "Swap failed", "failed without a reason");

    ActivityModel m;
    m.begin("a", ActivityKind::Propose, 3, album, 0);
    m.end("a", ok, 10);
    std::optional<ActivityLine> line = m.line(10);
    CHECK(line && line->state == ActivityState::Succeeded && line->icon == ActivityIcon::Check, "succeeded: check");
    CHECK(line && line->done == 0 && line->total == 0, "a result has no bar");
    m.begin("b", ActivityKind::Execute, 5, album, 20);
    m.end("b", failed("x"), 30);
    line = m.line(30);
    CHECK(line && line->state == ActivityState::Failed && line->icon == ActivityIcon::Cross, "failed: cross");
    CHECK(line && line->done == 0 && line->total == 0, "a failed execute has no bar either");

    // The result count may differ from the running one (Swap: rows swapped).
    ActivityModel s;
    s.begin("s", ActivityKind::Swap, 12, "", 0);
    s.end("s", ok, 1, 10);
    CHECK(lineText(s, 1) == "Swapped 10 playlist rows", "end's count replaces the running count");
}

static void testUtf8() {
    g_context = "utf8";
    const std::string bjork = "Bj\xC3\xB6rk" + kDash + "Homog\xC3\xA9nic";
    CHECK(runningText(ActivityKind::Propose, 1, bjork) == "Proposing " + bjork + kDots, "Latin-1 range kept");
    const std::string japanese = "\xE5\xAE\x87\xE5\xA4\x9A\xE7\x94\xB0" + kDash + "First Love";
    CHECK(runningText(ActivityKind::Approve, 1, japanese) == "Approving " + japanese + kDots, "CJK kept");
    const std::string nfd = "Beyonce\xCC\x81" + kDash + "Lemonade";  // e + U+0301
    CHECK(runningText(ActivityKind::Reject, 1, nfd) == "Rejecting " + nfd + kDots, "decomposed accents kept");

    // Cuts: at most the limit, "…" at the end, never inside a character.
    CHECK(activityShorten("short", 60) == "short", "short text untouched");
    CHECK(activityShorten(std::string(60, 'a'), 60) == std::string(60, 'a'), "exactly the limit: untouched");
    CHECK(activityShorten(std::string(61, 'a'), 60) == std::string(57, 'a') + kDots, "one over: cut to 57 + …");
    // An en dash (3 bytes) at 57..59: the cut at 57 falls before it.
    std::string s = std::string(57, 'a') + kDash + "bbbb";
    CHECK(activityShorten(s, 60) == std::string(57, 'a') + kDots, "the cut before a 3-byte character");
    // An en dash at 56..58: 57 is inside it, so the cut moves back to 56.
    s = std::string(56, 'a') + kDash + "bbbb";
    CHECK(activityShorten(s, 60) == std::string(56, 'a') + kDots, "never inside a 3-byte character");
    // A 4-byte character (U+1F3B5) across the cut.
    s = std::string(55, 'a') + "\xF0\x9F\x8E\xB5" + "bbbb";
    CHECK(activityShorten(s, 60) == std::string(55, 'a') + kDots, "never inside a 4-byte character");
    // e + U+0301 with the accent at the cut: the letter goes with it.
    s = std::string(56, 'a') + "e\xCC\x81" + "bbbbbb";
    CHECK(activityShorten(s, 60) == std::string(56, 'a') + kDots, "a letter never loses its accent");
    // Two accents on one letter.
    s = std::string(54, 'a') + "o\xCC\x88\xCC\x81" + "bbbbbb";
    CHECK(activityShorten(s, 60) == std::string(54, 'a') + kDots, "nor its accents");
    // Trailing spaces before the ellipsis go.
    s = std::string(50, 'a') + "          bbbbbb";
    CHECK(activityShorten(s, 60) == std::string(50, 'a') + kDots, "no space before the ellipsis");
    // Long multi-byte labels of every width stay valid UTF-8.
    std::string many;
    for (int i = 0; i < 40; i++) many += "\xC3\xA9\xE2\x80\x93\xF0\x9F\x8E\xB5" "e\xCC\x81";
    for (size_t limit = 3; limit < 80; limit++) {
        const std::string cut = activityShorten(many, limit);
        if (cut.size() > limit || !validUtf8(cut)) {
            CHECK(false, ("cut to " + std::to_string(limit) + " bytes stays within it and valid").c_str());
        }
    }
    CHECK(activityShorten(many, 2).empty(), "no room even for the ellipsis: empty");

    // Other combining marks of NFD names stay with their letter too (review
    // finding: only U+0300-U+036F did).
    const std::string ke = "\xE3\x82\xB1";            // KATAKANA KE
    const std::string dakuten = "\xE3\x82\x99";       // U+3099 voicing mark: KE + it = GE
    s = std::string(54, 'a') + ke + dakuten + "bbbbbb";  // the mark at 57..59
    CHECK(activityShorten(s, 60) == std::string(54, 'a') + kDots, "kana keeps its voicing mark");
    s = std::string(51, 'a') + ke + dakuten + "\xE3\x83\x95\xE3\x82\x9A" + "bbbbbb";  // GE, then PU (U+309A)
    CHECK(activityShorten(s, 60) == std::string(51, 'a') + ke + dakuten + kDots, "a whole kana before the cut stays");
    s = std::string(56, 'a') + "e\xE2\x83\x97" + "bbbbbb";  // e + U+20D7
    CHECK(activityShorten(s, 60) == std::string(56, 'a') + kDots, "U+20D0-U+20FF marks");
    s = std::string(56, 'a') + "e\xE1\xB7\x80" + "bbbbbb";  // e + U+1DC0
    CHECK(activityShorten(s, 60) == std::string(56, 'a') + kDots, "U+1DC0-U+1DFF marks");
    s = std::string(56, 'a') + "e\xEF\xB8\xA0" + "bbbbbb";  // e + U+FE20
    CHECK(activityShorten(s, 60) == std::string(56, 'a') + kDots, "U+FE20-U+FE2F marks");
    // Decomposed Hangul HAN (U+1112 U+1161 U+11AB): the cut never splits
    // the syllable into loose jamo.
    const std::string han = "\xE1\x84\x92\xE1\x85\xA1\xE1\x86\xAB";
    s = std::string(54, 'a') + han + "bbbbbb";  // the cut at 57 falls on the vowel
    CHECK(activityShorten(s, 60) == std::string(54, 'a') + kDots, "a Hangul syllable keeps its jamo");
    s = std::string(51, 'a') + han + han + "bbbbbb";  // the cut at 57 falls on the final consonant
    CHECK(activityShorten(s, 60) == std::string(51, 'a') + kDots, "nor from its final consonant");
    s = std::string(48, 'a') + han + han + "bbbbbb";  // the second syllable starts at 57
    CHECK(activityShorten(s, 60) == std::string(48, 'a') + han + kDots, "a whole syllable before the cut stays");
    // A mark on a character outside the BMP (two UTF-16 units).
    s = std::string(52, 'a') + "\xF0\x9F\x8E\xB5" + "\xE2\x83\x9D" + "bbbbbb";  // U+1F3B5 + U+20DD at 56..58
    CHECK(activityShorten(s, 60) == std::string(52, 'a') + kDots, "an enclosing mark keeps its character");
    // Accents after a surrogate pair: the UTF-16 index maps back to bytes.
    s = std::string(50, 'a') + "\xF0\x9F\x8E\xB5" + "e\xCC\x81\xCC\x88" + "bbbbbb";  // U+0308 at 57..58
    CHECK(activityShorten(s, 60) == std::string(50, 'a') + "\xF0\x9F\x8E\xB5" + kDots,
          "the offsets hold past a surrogate pair");
    // Text that is not UTF-8: the UTF-8 boundary only, never a crash.
    s = std::string(56, 'a') + "e\xCC\x81" + "\xFF" + "bbbbbb";
    CHECK(activityShorten(s, 60) == std::string(56, 'a') + "e" + kDots, "invalid UTF-8: the byte cut");
    // A leading BOM keeps the offsets right (or the byte cut).
    s = "\xEF\xBB\xBF" + std::string(53, 'a') + "e\xCC\x81" + "bbbbbb";
    CHECK(activityShorten(s, 60) == "\xEF\xBB\xBF" + std::string(53, 'a') + kDots, "a BOM before the text");

    // Control characters become spaces.
    CHECK(activityShorten("a\nb\tc\rd", 60) == "a b c d", "newlines and tabs become spaces");

    // A long label in the line is cut to kActivityLabelMaxBytes.
    const std::string longLabel = std::string(30, 'x') + kDash + std::string(80, 'y');
    const std::string text = runningText(ActivityKind::Propose, 1, longLabel);
    CHECK(text.size() <= std::string("Proposing ").size() + kActivityLabelMaxBytes + kDots.size(),
          "the label is cut in the line");
    CHECK(validUtf8(text), "and stays valid UTF-8");
    // A long reason is cut to kActivityReasonMaxBytes.
    const std::string reason = resultText(ActivityKind::Execute, 2, "", failed(std::string(300, 'r')));
    CHECK(reason.size() == std::string("Execute failed: ").size() + kActivityReasonMaxBytes, "the reason is cut");
}

static void testExpiry() {
    g_context = "expiry";
    ActivityModel m;
    CHECK(!m.line(0).has_value(), "idle: no line at all");
    CHECK(!m.nextExpiry(0).has_value(), "idle: no expiry");
    m.begin("a", ActivityKind::Propose, 3, "", 1000);
    CHECK(!m.nextExpiry(1000).has_value(), "a running entry never expires");
    CHECK(m.end("a", ActivityResult(), 5000), "ended");
    CHECK(lineText(m, 5000) == "Proposed 3 albums", "the result at its end");
    CHECK(lineText(m, 14999) == "Proposed 3 albums", "still there 1 ms before 10 s");
    CHECK(!m.line(15000).has_value(), "gone at exactly 10 s");
    CHECK(m.nextExpiry(5000) == std::optional<int64_t>(15000), "the expiry is 10 s after the end");
    CHECK(m.nextExpiry(14999) == std::optional<int64_t>(15000), "and stays until then");
    CHECK(!m.nextExpiry(15000).has_value(), "none after it");
    CHECK(m.items(14999).size() == 1 && m.items(15000).empty(), "the list follows the same window");
    CHECK(!m.line(4999).has_value(), "a result that ends after now (the clock went back) is not shown");
    CHECK(m.size() == 1 && !m.prune(14999) && m.size() == 1, "prune keeps a shown result");
    CHECK(m.prune(15000) && m.size() == 0, "prune drops it at 10 s");

    // Two results: the newest shows; each goes after its own 10 s.
    ActivityModel two;
    two.begin("a", ActivityKind::Approve, 2, "", 0);
    two.begin("b", ActivityKind::Reject, 2, "", 0);
    two.end("a", ActivityResult(), 1000);
    two.end("b", failed("x"), 4000);
    CHECK(lineText(two, 4000) == "Reject failed: x", "the newest result");
    CHECK(two.nextExpiry(4000) == std::optional<int64_t>(11000), "the next expiry is the older one's");
    CHECK(lineText(two, 11000) == "Reject failed: x", "after the older one went");
    CHECK(two.nextExpiry(11000) == std::optional<int64_t>(14000), "then the newer one's");
    CHECK(!two.line(14000).has_value(), "both gone");

    // Ending the newer first: the later end is newest, whatever began first.
    ActivityModel order;
    order.begin("a", ActivityKind::Approve, 2, "", 0);
    order.begin("b", ActivityKind::Reject, 2, "", 10);
    order.end("b", ActivityResult(), 20);
    order.end("a", ActivityResult(), 20);  // same millisecond: the later call wins
    CHECK(lineText(order, 20) == "Approved 2 albums", "newest by end order");
}

static void testOrderAndMore() {
    g_context = "order";
    ActivityModel m;
    const uint64_t a = m.begin("a", ActivityKind::Propose, 2, "", 0);
    const uint64_t b = m.begin("b", ActivityKind::Approve, 2, "", 10);
    const uint64_t c = m.begin("c", ActivityKind::Reject, 2, "", 20);
    CHECK(a != b && b != c && a != 0, "distinct ids");
    CHECK(lineText(m, 20) == "Rejecting 2 albums" + kDots + " (+2 more)", "the newest running, +2 more");
    m.end("b", ActivityResult(), 30);
    CHECK(lineText(m, 30) == "Rejecting 2 albums" + kDots + " (+1 more)", "+1 more");
    m.end("a", failed("x"), 40);
    CHECK(lineText(m, 40) == "Rejecting 2 albums" + kDots, "one running: no (+N more)");
    const uint64_t d = m.begin("d", ActivityKind::Gc, 2, "", 50);
    std::vector<ActivityItem> items = m.items(50);
    CHECK(items.size() == 4, "four items");
    CHECK(items.size() == 4 && items[0].id == d && items[1].id == c && items[2].id == a && items[3].id == b,
          "running first (newest first), then results (newest first)");
    CHECK(items.size() == 4 && items[0].state == ActivityState::Running && items[2].state == ActivityState::Failed &&
              items[3].state == ActivityState::Succeeded,
          "their states");
    CHECK(items.size() == 4 && items[0].startedMs == 50 && items[0].endedMs == 0 && items[2].endedMs == 40,
          "started and ended times");
    // A running entry wins the line over a newer result.
    m.end("c", ActivityResult(), 60);
    CHECK(lineText(m, 60) == "Deleting local copies of 2 albums" + kDots, "running beats a newer result");
    m.end("d", ActivityResult(), 70);
    CHECK(lineText(m, 70) == "Deleted local copies of 2 albums", "nothing running: the newest result");
    CHECK(m.runningCount() == 0, "none running");
}

static void testProgress() {
    g_context = "progress";
    const std::string first = "Fixture Artist" + kDash + "First";
    const std::string current = "Fixture Artist" + kDash + "Fixture Album";
    ActivityModel m;
    m.begin("run:x", ActivityKind::Execute, 40, first, 0);
    CHECK(lineText(m, 0) == "Placing 40 albums" + kDots, "nothing reported yet");
    CHECK(m.progress("run:x", 0, 40, current), "the first album placing");
    CHECK(lineText(m, 0) == "Placing 0/40: " + current, "0/40 with the album placing now");
    CHECK(!m.progress("run:x", 0, 40, current), "the same progress again: no change");
    CHECK(m.progress("run:x", 12, 40, current), "12 placed");
    std::optional<ActivityLine> line = m.line(0);
    CHECK(line && line->text == "Placing 12/40: " + current && line->done == 12 && line->total == 40,
          "Placing 12/40: Artist – Album, with its bar");
    std::vector<ActivityItem> items = m.items(0);
    CHECK(items.size() == 1 && items[0].title == "Placing 12/40" && items[0].detail == current &&
              items[0].done == 12 && items[0].total == 40,
          "the item: Placing 12/40, the album as its detail");
    CHECK(m.progress("run:x", 13, 40, ""), "between two albums");
    CHECK(lineText(m, 0) == "Placing 13/40", "no album placing: n/m only");
    m.end("run:x", failed("1 of 40 albums"), 5);
    line = m.line(5);
    CHECK(line && line->text == "Execute failed: 1 of 40 albums" && line->total == 0, "its result");
    CHECK(!m.progress("run:x", 14, 40, current), "no progress on an ended entry");

    ActivityModel r;
    r.begin("run:r", ActivityKind::Resume, 5, first, 0);
    r.progress("run:r", 2, 5, "");
    CHECK(lineText(r, 0) == "Resuming placement 2/5", "resume: n/m without an album");

    ActivityModel one;
    one.begin("run:1", ActivityKind::Execute, 1, first, 0);
    one.progress("run:1", 0, 1, first);
    CHECK(lineText(one, 0) == "Placing " + first + kDots, "one album: never n/m");
    std::optional<ActivityLine> l1 = one.line(0);
    CHECK(l1 && l1->done == 0 && l1->total == 1, "but its bar");

    CHECK(!m.progress("nobody", 1, 2, ""), "progress on an unknown key: ignored");
}

static void testRename() {
    g_context = "rename";
    const std::string first = "Fixture Artist" + kDash + "First";
    ActivityModel m;
    m.begin("lane:3", ActivityKind::Assign, 3, first, 0);
    CHECK(lineText(m, 0) == "Assigning 3 albums" + kDots, "the assign");
    CHECK(m.rename("lane:3", ActivityKind::AssignThenPropose, 2, first), "the propose after it");
    CHECK(lineText(m, 0) == "Proposing 2 albums" + kDots, "renamed, with the propose's count");
    CHECK(m.size() == 1, "still one entry");
    m.end("lane:3", ActivityResult(), 10);
    CHECK(lineText(m, 10) == "Assigned and proposed 2 albums", "its result");
    CHECK(!m.rename("lane:3", ActivityKind::Propose, 1, ""), "rename of an ended entry: ignored");
    CHECK(!m.rename("lane:9", ActivityKind::Propose, 1, ""), "rename of an unknown key: ignored");

    ActivityModel p;
    p.begin("k", ActivityKind::Execute, 4, "", 0);
    p.progress("k", 2, 4, "x");
    p.rename("k", ActivityKind::Resume, 3, "");
    std::optional<ActivityLine> line = p.line(0);
    CHECK(line && line->text == "Resuming placement of 3 albums" + kDots && line->done == 0 && line->total == 3,
          "rename resets the progress");
}

static void testKeyPairing() {
    g_context = "key-pairing";
    ActivityModel m;
    m.begin(activityLaneKey(5), ActivityKind::Propose, 1, "A", 0);
    m.begin(activityRunKey("execute-1"), ActivityKind::Execute, 3, "B", 1);
    m.begin(activitySwapKey(2), ActivityKind::Swap, 4, "", 2);
    m.begin(activityCensusKey(2), ActivityKind::DeleteCensus, 1, "C", 3);
    CHECK(m.runningCount() == 4, "four running");
    CHECK(m.isRunning(activitySwapKey(2)) && m.isRunning(activityCensusKey(2)), "swap 2 and census 2 are two");
    CHECK(m.end(activitySwapKey(2), ActivityResult(), 10), "the swap ends by its serial");
    CHECK(m.isRunning(activityCensusKey(2)), "the census with the same number keeps running");
    CHECK(m.end(activityRunKey("execute-1"), ActivityResult(), 11), "the run ends by its stem");
    CHECK(m.end(activityLaneKey(5), failed("not started"), 12), "the call ends by its lane token");
    CHECK(!m.end(activityLaneKey(5), ActivityResult(), 13), "a double end is ignored");
    CHECK(lineText(m, 13) == "Counting playlist rows for C" + kDots, "and changes nothing");
    CHECK(!m.end(activityLaneKey(99), ActivityResult(), 14), "the end of an unknown key is ignored");
    CHECK(!m.end(activityRunKey("never"), failed("x"), 14), "also for a stem");
    CHECK(m.runningCount() == 1 && m.size() == 4, "nothing else changed");

    // A key reused after its entry ended: a new entry; the old result stays.
    m.begin(activityLaneKey(5), ActivityKind::Approve, 2, "", 20);
    CHECK(m.isRunning(activityLaneKey(5)) && m.size() == 5, "the key runs again, the old result kept");
    // begin on a key still running: the old entry is dropped.
    m.begin(activityLaneKey(5), ActivityKind::Reject, 2, "", 21);
    CHECK(m.runningCount() == 2 && m.size() == 5, "a second begin replaces the running entry");
    CHECK(lineText(m, 21) == "Rejecting 2 albums" + kDots + " (+1 more)", "the newer one shows");
}

static void testClear() {
    g_context = "clear";
    ActivityModel m;
    CHECK(!m.clear(), "clearing nothing: false");
    m.begin("a", ActivityKind::Execute, 3, "", 0);
    m.begin("b", ActivityKind::Swap, 3, "", 0);
    m.end("b", ActivityResult(), 1);
    CHECK(m.clear(), "clear (quit)");
    CHECK(!m.line(1).has_value() && m.items(1).empty() && m.size() == 0, "nothing left");
    CHECK(!m.nextExpiry(1).has_value(), "no expiry left");
    CHECK(!m.end("a", ActivityResult(), 2), "an end after clear is ignored");
    CHECK(!m.progress("a", 1, 3, ""), "progress after clear is ignored");
    const uint64_t next = m.begin("c", ActivityKind::Propose, 1, "", 3);
    CHECK(next > 0 && m.size() == 1, "the model works again after clear (the hub stops its hooks)");
}

static void testItemDetails() {
    g_context = "item-details";
    const std::string first = "Fixture Artist" + kDash + "First";
    ActivityModel m;
    m.begin("a", ActivityKind::Propose, 3, first, 0);
    m.begin("b", ActivityKind::Propose, 1, first, 1);
    m.begin("s", ActivityKind::Swap, 4, first, 2);
    std::vector<ActivityItem> items = m.items(2);
    CHECK(items.size() == 3 && items[2].title == "Proposing 3 albums" + kDots &&
              items[2].detail == first + " and 2 more",
          "several albums: the first and N more");
    CHECK(items.size() == 3 && items[1].title == "Proposing " + first + kDots && items[1].detail.empty(),
          "one album: the label is in the title");
    CHECK(items.size() == 3 && items[0].detail.empty(), "swap: no album detail");
    m.end("a", failed("1 of 3 albums", "propose: done for 2 of 3 roots; no evidence\nmore"), 5);
    m.end("b", ActivityResult(), 6);
    items = m.items(6);
    CHECK(items.size() == 3 && items[2].title == "Propose failed: 1 of 3 albums" &&
              items[2].detail == "propose: done for 2 of 3 roots; no evidence more",
          "failed: the detail (one line)");
    CHECK(items.size() == 3 && items[1].title == "Proposed " + first && items[1].detail.empty(),
          "succeeded: the result text");
}

// --- activityResultFor ---

static MutationOutcome outcome(std::vector<std::string> succeeded,
                               std::vector<std::pair<std::string, std::string>> errors,
                               std::vector<std::string> withoutError, const std::string &line, bool isError) {
    MutationOutcome o;
    o.succeeded = std::move(succeeded);
    o.rootErrors = std::move(errors);
    o.failedWithoutError = std::move(withoutError);
    o.consoleLine = line;
    o.isError = isError;
    return o;
}

static void testResultFor() {
    g_context = "result-for";
    ActivityResult r = activityResultFor(outcome({"a", "b"}, {}, {}, "propose: done for 2 roots", false), 2, "propose");
    CHECK(r.succeeded && r.reason.empty() && r.detail.empty(), "every root done: succeeded");

    r = activityResultFor(outcome({}, {{"a", "execute: target path already exists (/lib/x)"}}, {},
                                  "execute failed for 1 root: target path already exists (/lib/x)", true),
                          1, "execute");
    CHECK(!r.succeeded && r.reason == "target path already exists (/lib/x)", "none done: the error, no prefix");
    CHECK(r.detail == "execute failed for 1 root: target path already exists (/lib/x)", "the console line as detail");

    r = activityResultFor(outcome({"a", "b", "c", "d"}, {{"e", "execute: verify failed"}}, {},
                                  "execute: done for 4 of 5 roots; verify failed", true),
                          5, "execute");
    CHECK(!r.succeeded && r.reason == "1 of 5 albums", "some done: k of n albums");

    r = activityResultFor(outcome({}, {}, {"a", "b"}, "propose: cancelled", false), 2, "propose");
    CHECK(!r.succeeded && r.reason == "cancelled", "cancelled");

    r = activityResultFor(outcome({}, {}, {"a", "b", "c"}, "propose failed for 3 roots: Intake CLI not available", true),
                          3, "propose");
    CHECK(!r.succeeded && r.reason == "Intake CLI not available", "no root error: the console line's cause");

    r = activityResultFor(outcome({"a", "b"}, {}, {}, "propose: done for 2 of 2 roots; unreadable sidecar (+1 more)", true),
                          2, "propose");
    CHECK(!r.succeeded && r.reason == "unreadable sidecar (+1 more)", "every root done but errors: the error");

    r = activityResultFor(outcome({}, {{"a", "execute dry run: cannot execute from status placed"}}, {},
                                  "execute dry run failed for 1 root: cannot execute from status placed", true),
                          1, "execute dry run");
    CHECK(!r.succeeded && r.reason == "cannot execute from status placed", "a display name prefix is stripped too");

    r = activityResultFor(outcome({}, {{"a", "resume: reverted to approved"}, {"b", "resume: reverted to approved"}},
                                  {}, "resume failed for 2 roots: reverted to approved", true),
                          2, "resume");
    CHECK(!r.succeeded && r.reason == "reverted to approved", "all failed: the first root's error");

    r = activityResultFor(outcome({"a"}, {}, {"b"}, "approve: done for 1 of 2 roots", false), 2, "approve");
    CHECK(!r.succeeded && r.reason == "1 of 2 albums", "a root missing from data counts as failed");
}

// A running entry with a deadline (the execute dry run, which the runner
// never kills: review finding, an answer that never comes left it running
// for the session and hid every later result from the line).
static void testDeadline() {
    g_context = "deadline";
    const int64_t cap = 15 * 60 * 1000;
    const ActivityResult noAnswer = failed("no answer within 15 min", "execute dry run: no answer after 15 minutes");
    ActivityModel m;
    m.begin("lane:1", ActivityKind::ExecuteDryRun, 3, "", 1000);
    CHECK(!m.nextExpiry(1000).has_value(), "no deadline: never expires");
    CHECK(m.deadline("lane:1", 1000 + cap, noAnswer), "deadline set");
    CHECK(!m.deadline("lane:9", 1000 + cap, noAnswer), "an unknown key: false");
    CHECK(m.nextExpiry(1000) == std::optional<int64_t>(1000 + cap), "the timer's next time is the deadline");
    CHECK(!m.prune(cap) && m.isRunning("lane:1"), "running until the deadline");
    CHECK(lineText(m, cap) == "Checking placement of 3 albums" + kDots, "and shown as running");

    // A later operation shows "(+1 more)" until the deadline; then the
    // dry run's failure, and later results reach the line again.
    m.begin("lane:2", ActivityKind::Propose, 3, "", 5000);
    CHECK(lineText(m, 5000) == "Proposing 3 albums" + kDots + " (+1 more)", "+1 more while it runs");
    m.end("lane:2", ActivityResult(), 6000);
    CHECK(lineText(m, 6000) == "Checking placement of 3 albums" + kDots, "the running dry run hides the result");
    CHECK(m.prune(1000 + cap), "prune at the deadline ends it");
    CHECK(!m.isRunning("lane:1") && m.runningCount() == 0, "no longer running");
    CHECK(lineText(m, 1000 + cap) == "Placement check failed: no answer within 15 min", "failed at its deadline");
    std::vector<ActivityItem> items = m.items(1000 + cap);
    CHECK(items.size() == 1 && items[0].state == ActivityState::Failed && items[0].endedMs == 1000 + cap &&
              items[0].detail == "execute dry run: no answer after 15 minutes",
          "ended at the deadline, the console line as detail");
    CHECK(m.nextExpiry(1000 + cap) == std::optional<int64_t>(1000 + cap + kActivityResultMs),
          "then the result's 10 s");
    CHECK(!m.end("lane:1", ActivityResult(), 2000 + cap), "a late answer is ignored like a double end");
    CHECK(lineText(m, 2000 + cap) == "Placement check failed: no answer within 15 min", "the line keeps the failure");
    m.begin("lane:3", ActivityKind::Approve, 2, "", 3000 + cap);
    m.end("lane:3", ActivityResult(), 4000 + cap);
    CHECK(lineText(m, 4000 + cap) == "Approved 2 albums", "a later result reaches the line");

    // An end before the deadline wins, and the deadline is gone with it.
    ActivityModel early;
    early.begin("lane:1", ActivityKind::ExecuteDryRun, 1, "Artist" + kDash + "Album", 0);
    early.deadline("lane:1", cap, noAnswer);
    CHECK(early.end("lane:1", ActivityResult(), 15000), "the late answer before the deadline");
    CHECK(lineText(early, 15000) == "Checked placement of Artist" + kDash + "Album", "its own result");
    CHECK(early.nextExpiry(15000) == std::optional<int64_t>(25000), "no deadline left, only the 10 s");
    CHECK(!early.prune(cap) || early.size() == 0, "the deadline does nothing later");
    CHECK(!early.line(cap).has_value(), "nothing shown");

    // A deadline already past (the timer fired late, the Mac slept): the
    // next time is at or before now, and an end() prunes first.
    ActivityModel late;
    late.begin("lane:1", ActivityKind::ExecuteDryRun, 2, "", 0);
    late.deadline("lane:1", 1000, noAnswer);
    CHECK(late.nextExpiry(5000) == std::optional<int64_t>(1000), "an overdue deadline: prune at once");
    CHECK(!late.end("lane:1", ActivityResult(), 5000), "an end after the deadline finds it ended");
    CHECK(lineText(late, 5000) == "Placement check failed: no answer within 15 min", "the deadline's result");
    // Pruned much later than the deadline: ended then, so not shown at all.
    ActivityModel slept;
    slept.begin("lane:1", ActivityKind::ExecuteDryRun, 2, "", 0);
    slept.deadline("lane:1", 1000, noAnswer);
    CHECK(slept.prune(1000 + kActivityResultMs) && slept.size() == 0, "past its 10 s too: gone");
    CHECK(!slept.line(1000 + kActivityResultMs).has_value(), "no line");

    // begin() on the key drops the deadline with the old entry; clear()
    // drops it too.
    ActivityModel again;
    again.begin("lane:1", ActivityKind::ExecuteDryRun, 2, "", 0);
    again.deadline("lane:1", 1000, noAnswer);
    again.begin("lane:1", ActivityKind::Propose, 2, "", 10);
    CHECK(!again.prune(2000) && again.isRunning("lane:1"), "the new entry has no deadline");
    again.deadline("lane:1", 3000, noAnswer);
    CHECK(again.clear() && !again.nextExpiry(0).has_value(), "clear drops the deadline");
}

// The end of an assign and the propose after it (review finding: a partly
// failed assign ended with the propose's success and the check icon).
static void testAfterAssign() {
    g_context = "after-assign";
    const ActivityResult ok;
    const ActivityResult assignPart = failed("1 of 3 albums", "assign: done for 2 of 3 roots; cannot assign from status placed");
    const ActivityResult proposeFail = failed("unreadable sidecar", "propose failed for 2 roots: unreadable sidecar");

    ActivityResult r = activityAfterAssign(ok, ok);
    CHECK(r.succeeded && !r.kind.has_value(), "both succeeded: the propose's success");
    r = activityAfterAssign(ok, proposeFail);
    CHECK(!r.succeeded && r.reason == "unreadable sidecar" && !r.kind.has_value(), "only the propose failed");
    r = activityAfterAssign(assignPart, ok);
    CHECK(!r.succeeded && r.reason == "1 of 3 albums" && r.kind == std::optional<ActivityKind>(ActivityKind::Assign),
          "the assign failed for one: failed, as the assign");
    CHECK(r.detail == assignPart.detail, "its console line");
    r = activityAfterAssign(assignPart, proposeFail);
    CHECK(!r.succeeded && r.reason == "1 of 3 albums" && r.kind == std::optional<ActivityKind>(ActivityKind::Assign),
          "both failed: the assign's failure");
    CHECK(r.detail == assignPart.detail + "; " + proposeFail.detail, "both console lines");
    r = activityAfterAssign(failed("x"), failed("not started"));
    CHECK(r.detail == "not started", "the propose's reason when it has no detail");

    // Through the model: the entry renamed for the propose, then ended.
    auto ended = [](const ActivityResult &assign, const ActivityResult &propose) {
        ActivityModel m;
        m.begin("lane:1", ActivityKind::Assign, 3, "", 0);
        m.rename("lane:1", ActivityKind::AssignThenPropose, 2, "");
        m.end("lane:1", activityAfterAssign(assign, propose), 10);
        return m;
    };
    ActivityModel m = ended(ok, ok);
    CHECK(lineText(m, 10) == "Assigned and proposed 2 albums", "succeeded: assigned and proposed");
    CHECK(m.line(10)->icon == ActivityIcon::Check, "with the check");
    m = ended(assignPart, ok);
    CHECK(lineText(m, 10) == "Assign failed: 1 of 3 albums", "the partial assign shows");
    CHECK(m.line(10)->icon == ActivityIcon::Cross && m.line(10)->state == ActivityState::Failed, "with the cross");
    CHECK(m.items(10).size() == 1 && m.items(10)[0].title == "Assign failed: 1 of 3 albums", "the list says so too");
    m = ended(ok, proposeFail);
    CHECK(lineText(m, 10) == "Propose failed: unreadable sidecar", "a failed propose");
}

// The Delete flow's census (review finding: it always ended succeeded).
static void testReadsResult() {
    g_context = "reads-result";
    ActivityResult r = activityReadsResult(3, {});
    CHECK(r.succeeded, "every list read: succeeded");
    r = activityReadsResult(3, {"share unreachable (Host is down)", "the share stopped answering",
                                "the share stopped answering"});
    CHECK(!r.succeeded && r.reason == "share unreachable (Host is down)", "none read: the first error");
    CHECK(r.detail == "no file list for 3 of 3 albums: share unreachable (Host is down)", "the detail");
    r = activityReadsResult(3, {"no longer listed by intake status"});
    CHECK(!r.succeeded && r.reason == "1 of 3 albums", "some read: k of n albums");
    CHECK(r.detail == "no file list for 1 of 3 albums: no longer listed by intake status", "the detail");
    r = activityReadsResult(1, {"unreadable"});
    CHECK(!r.succeeded && r.reason == "unreadable", "one root, unread");
    r = activityReadsResult(0, {"x", "y"});
    CHECK(!r.succeeded && r.reason == "x" && r.detail == "no file list for 2 of 2 albums: x",
          "more errors than named: all failed");

    ActivityModel m;
    m.begin("census:1", ActivityKind::DeleteCensus, 3, "", 0);
    m.end("census:1", activityReadsResult(3, {"share unreachable", "the share stopped answering",
                                              "the share stopped answering"}),
          50);
    CHECK(lineText(m, 50) == "Row count failed: share unreachable", "a share that fails at once: failed");
    CHECK(m.line(50)->icon == ActivityIcon::Cross, "with the cross");
}

int main() {
    @autoreleasepool {
        testKeys();
        testRunningTexts();
        testResultTexts();
        testUtf8();
        testExpiry();
        testOrderAndMore();
        testProgress();
        testRename();
        testKeyPairing();
        testClear();
        testItemDetails();
        testResultFor();
        testDeadline();
        testAfterAssign();
        testReadsResult();
    }
    TEST_MAIN_END();
}
