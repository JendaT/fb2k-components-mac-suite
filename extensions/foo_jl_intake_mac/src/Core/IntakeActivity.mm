//
//  IntakeActivity.mm
//  foo_jl_intake
//
//  See IntakeActivity.h.
//

#include "IntakeActivity.h"

#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <climits>
#include <string_view>

namespace intake {

namespace {

const char *const kEllipsis = "\xE2\x80\xA6";  // U+2026

// The words of a kind's texts.
struct Words {
    const char *running;   // before the object: "Checking placement of"
    const char *progress;  // before n/m: "Checking placement"
    const char *done;      // before the object: "Checked placement of"
    const char *failed;    // before ": <reason>"
};

Words wordsFor(ActivityKind kind) {
    switch (kind) {
        case ActivityKind::Propose: return {"Proposing", "Proposing", "Proposed", "Propose failed"};
        case ActivityKind::Assign: return {"Assigning", "Assigning", "Assigned", "Assign failed"};
        case ActivityKind::AssignThenPropose:
            return {"Proposing", "Proposing", "Assigned and proposed", "Propose failed"};
        case ActivityKind::Approve: return {"Approving", "Approving", "Approved", "Approve failed"};
        case ActivityKind::Reject: return {"Rejecting", "Rejecting", "Rejected", "Reject failed"};
        case ActivityKind::ExecuteDryRun:
            return {"Checking placement of", "Checking placement", "Checked placement of", "Placement check failed"};
        case ActivityKind::Execute: return {"Placing", "Placing", "Placed", "Execute failed"};
        case ActivityKind::Resume:
            return {"Resuming placement of", "Resuming placement", "Resumed placement of", "Resume failed"};
        case ActivityKind::Gc:
            return {"Deleting local copies of", "Deleting local copies", "Deleted local copies of", "Delete failed"};
        case ActivityKind::DeleteCensus:
            return {"Counting playlist rows for", "Counting playlist rows", "Counted playlist rows for",
                    "Row count failed"};
        case ActivityKind::Swap: return {"Swapping", "Swapping playlist rows", "Swapped", "Swap failed"};
        case ActivityKind::Scan: return {"Scanning income", "Scanning income", "Scanned", "Scan failed"};
        // Its result has a text of its own (lineText).
        case ActivityKind::ScanThenPropose: return {"Proposing", "Proposing", "Scanned", "Propose failed"};
    }
    return {"Working on", "Working on", "Done with", "Failed"};
}

bool hasProgressFromStart(ActivityKind kind) {
    return kind == ActivityKind::Execute || kind == ActivityKind::Resume;
}

uint32_t clamp32(size_t n) {
    return n > UINT32_MAX ? UINT32_MAX : static_cast<uint32_t>(n);
}

// Control characters (newlines, tabs, DEL) become spaces; UTF-8 bytes are
// all >= 0x80 and stay.
std::string oneLine(const std::string &text) {
    std::string out = text;
    for (char &c : out) {
        const unsigned char u = static_cast<unsigned char>(c);
        if (u < 0x20 || u == 0x7F) c = ' ';
    }
    return out;
}

bool isContinuation(unsigned char c) {
    return (c & 0xC0) == 0x80;
}

// The UTF-16 length of the UTF-8 bytes s[0, bytes): one unit per
// character, two for one of four bytes (outside the BMP).
CFIndex utf16Length(std::string_view s, size_t bytes) {
    CFIndex units = 0;
    for (size_t i = 0; i < bytes; i++) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        if (isContinuation(c)) continue;
        units += c >= 0xF0 ? 2 : 1;
    }
    return units;
}

// The byte offset in UTF-8 `s` of UTF-16 index `units` (a character start).
size_t utf8Offset(std::string_view s, CFIndex units) {
    size_t i = 0;
    CFIndex seen = 0;
    while (i < s.size() && seen < units) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        seen += c >= 0xF0 ? 2 : 1;
        i++;
        while (i < s.size() && isContinuation(static_cast<unsigned char>(s[i]))) i++;
    }
    return i;
}

// `cut` (a UTF-8 character start in `s`, 0 < cut < s.size()) moved back to
// the start of the composed character sequence it lies in
// (CFStringGetRangeOfComposedCharactersAtIndex): a letter keeps the
// combining marks after it, a Hangul syllable its jamo. An ASCII byte at
// `cut` always starts one (control characters are spaces by now, so no
// CR LF). Text that is not valid UTF-8 keeps `cut`.
size_t composedStart(const std::string &s, size_t cut) {
    if (cut == 0 || static_cast<unsigned char>(s[cut]) < 0x80) return cut;
    // CoreFoundation drops a leading UTF-8 BOM even from bytes that are not
    // an external representation; a BOM is a character of its own, so the
    // text after it is enough (cut, a character start, lies past it).
    const size_t skip = s.compare(0, 3, "\xEF\xBB\xBF") == 0 ? 3 : 0;
    const std::string_view body = std::string_view(s).substr(skip);
    CFStringRef str = CFStringCreateWithBytes(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(body.data()),
                                              static_cast<CFIndex>(body.size()), kCFStringEncodingUTF8, false);
    if (str == nullptr) return cut;
    const CFIndex at = utf16Length(body, cut - skip);
    size_t start = cut;
    // The units must line up with the bytes (a second BOM would shift them).
    if (CFStringGetLength(str) == utf16Length(body, body.size())) {
        const CFRange range = CFStringGetRangeOfComposedCharactersAtIndex(str, at);
        if (range.location < at) start = skip + utf8Offset(body, range.location);
    }
    CFRelease(str);
    return start;
}

std::string plural(size_t n, const char *one, const char *many) {
    return std::to_string(n) + " " + (n == 1 ? one : many);
}

bool startsWith(const std::string &s, const std::string &prefix) {
    return s.size() >= prefix.size() && s.compare(0, prefix.size(), prefix) == 0;
}

} // anonymous namespace

std::string activityLaneKey(uint64_t token) {
    return "lane:" + std::to_string(token);
}

std::string activityRunKey(const std::string &stem) {
    return "run:" + stem;
}

std::string activitySwapKey(uint64_t serial) {
    return "swap:" + std::to_string(serial);
}

std::string activityCensusKey(uint64_t serial) {
    return "census:" + std::to_string(serial);
}

bool activityKindFor(CliCommand command, bool dryRun, ActivityKind &out) {
    switch (command) {
        case CliCommand::Propose: out = ActivityKind::Propose; return true;
        case CliCommand::Assign: out = ActivityKind::Assign; return true;
        case CliCommand::Approve: out = ActivityKind::Approve; return true;
        case CliCommand::Reject: out = ActivityKind::Reject; return true;
        case CliCommand::Execute: out = dryRun ? ActivityKind::ExecuteDryRun : ActivityKind::Execute; return true;
        case CliCommand::Resume: out = ActivityKind::Resume; return true;
        case CliCommand::Gc: out = ActivityKind::Gc; return true;
        case CliCommand::Scan: out = ActivityKind::Scan; return true;
        case CliCommand::Version:
        case CliCommand::Status:
        case CliCommand::Collections:
        case CliCommand::Income: return false;
    }
    return false;
}

std::string activityShorten(const std::string &text, size_t maxBytes) {
    std::string s = oneLine(text);
    if (s.size() <= maxBytes) return s;
    const size_t ellipsis = 3;
    if (maxBytes < ellipsis) return std::string();
    size_t cut = maxBytes - ellipsis;
    // Never inside a character...
    while (cut > 0 && isContinuation(static_cast<unsigned char>(s[cut]))) cut--;
    // ...and never inside a composed character sequence: a letter goes with
    // the combining marks that follow it.
    cut = composedStart(s, cut);
    while (cut > 0 && s[cut - 1] == ' ') cut--;
    return s.substr(0, cut) + kEllipsis;
}

ActivityResult activityResultFor(const MutationOutcome &outcome, size_t named, const std::string &commandName) {
    ActivityResult r;
    if (!outcome.isError && outcome.rootErrors.empty() && outcome.failedWithoutError.empty()) return r;
    r.succeeded = false;
    r.detail = outcome.consoleLine;
    const std::string prefix = commandName + ": ";
    const size_t succeeded = outcome.succeeded.size();
    const size_t failed = named > succeeded ? named - succeeded : 0;
    if (succeeded > 0 && failed > 0) {
        r.reason = std::to_string(failed) + " of " + plural(named, "album", "albums");
        return r;
    }
    if (!outcome.rootErrors.empty()) {
        const std::string &text = outcome.rootErrors.front().second;
        r.reason = startsWith(text, prefix) ? text.substr(prefix.size()) : text;
        return r;
    }
    // No root's error to show: the console line without what it repeats
    // ("propose: cancelled", "propose failed for 3 roots: <error>", "propose:
    // done for 3 of 3 roots; <error>").
    std::string line = outcome.consoleLine;
    const std::string failedFor = commandName + " failed for ";
    if (startsWith(line, failedFor)) {
        const size_t colon = line.find(": ", failedFor.size());
        line = colon == std::string::npos ? line.substr(failedFor.size()) : line.substr(colon + 2);
    } else if (startsWith(line, prefix)) {
        line = line.substr(prefix.size());
        const size_t semicolon = line.find("; ");
        if (semicolon != std::string::npos) line = line.substr(semicolon + 2);
    }
    r.reason = line;
    return r;
}

ActivityResult activityAfterAssign(const ActivityResult &assign, const ActivityResult &propose) {
    if (assign.succeeded) {
        ActivityResult r = propose;
        r.kind.reset();  // the entry's own: AssignThenPropose
        return r;
    }
    ActivityResult r = assign;
    r.kind = ActivityKind::Assign;
    if (!propose.succeeded) {
        const std::string &more = propose.detail.empty() ? propose.reason : propose.detail;
        if (!more.empty()) r.detail = r.detail.empty() ? more : r.detail + "; " + more;
    }
    return r;
}

ActivityResult activityAfterScan(const ActivityResult &scan, const ActivityResult &propose) {
    // The propose's kind stays when it names one (a propose that could not
    // start before the entry became ScanThenPropose).
    if (scan.succeeded) return propose;
    ActivityResult r = scan;
    r.kind = ActivityKind::Scan;
    if (!propose.succeeded) {
        const std::string &more = propose.detail.empty() ? propose.reason : propose.detail;
        if (!more.empty()) r.detail = r.detail.empty() ? more : r.detail + "; " + more;
    }
    return r;
}

ActivityResult activityReadsResult(size_t named, const std::vector<std::string> &unread) {
    ActivityResult r;
    if (unread.empty()) return r;
    r.succeeded = false;
    const size_t total = std::max(named, unread.size());
    const std::string &first = unread.front();
    r.reason = unread.size() < total ? std::to_string(unread.size()) + " of " + plural(total, "album", "albums") : first;
    r.detail = "no file list for " + std::to_string(unread.size()) + " of " + plural(total, "album", "albums") +
               (first.empty() ? std::string() : ": " + first);
    return r;
}

// --- the model ---

ActivityModel::Entry *ActivityModel::findRunning(const std::string &key) {
    for (Entry &e : entries_) {
        if (e.state == ActivityState::Running && e.key == key) return &e;
    }
    return nullptr;
}

const ActivityModel::Entry *ActivityModel::findRunning(const std::string &key) const {
    for (const Entry &e : entries_) {
        if (e.state == ActivityState::Running && e.key == key) return &e;
    }
    return nullptr;
}

bool ActivityModel::shown(const Entry &e, int64_t now) {
    if (e.state == ActivityState::Running) return true;
    return e.endedMs <= now && now - e.endedMs < kActivityResultMs;
}

uint64_t ActivityModel::begin(const std::string &key, ActivityKind kind, size_t count, const std::string &firstLabel,
                              int64_t now) {
    prune(now);
    entries_.erase(std::remove_if(entries_.begin(), entries_.end(),
                                  [&key](const Entry &e) { return e.state == ActivityState::Running && e.key == key; }),
                   entries_.end());
    Entry e;
    e.id = nextId_++;
    e.key = key;
    e.kind = kind;
    e.count = count;
    e.label = activityShorten(firstLabel, kActivityLabelMaxBytes);
    if (hasProgressFromStart(kind)) e.total = clamp32(count);
    e.startedMs = now;
    entries_.push_back(std::move(e));
    return entries_.back().id;
}

bool ActivityModel::progress(const std::string &key, uint32_t done, uint32_t total, const std::string &currentLabel) {
    Entry *e = findRunning(key);
    if (e == nullptr) return false;
    std::string current = activityShorten(currentLabel, kActivityLabelMaxBytes);
    if (e->done == done && e->total == total && e->current == current) return false;
    e->done = done;
    e->total = total;
    e->current = std::move(current);
    return true;
}

bool ActivityModel::rename(const std::string &key, ActivityKind kind, size_t count, const std::string &firstLabel) {
    Entry *e = findRunning(key);
    if (e == nullptr) return false;
    e->kind = kind;
    e->count = count;
    e->label = activityShorten(firstLabel, kActivityLabelMaxBytes);
    e->done = 0;
    e->total = hasProgressFromStart(kind) ? clamp32(count) : 0;
    e->current.clear();
    return true;
}

void ActivityModel::finish(Entry &e, const ActivityResult &result, int64_t at, std::optional<size_t> count) {
    e.state = result.succeeded ? ActivityState::Succeeded : ActivityState::Failed;
    e.reason = result.succeeded ? std::string() : activityShorten(result.reason, kActivityReasonMaxBytes);
    e.detail = result.succeeded ? std::string() : oneLine(result.detail);
    if (result.kind) e.kind = *result.kind;
    if (count) e.count = *count;
    e.current.clear();
    e.endedMs = at;
    e.endSeq = nextEndSeq_++;
    e.deadlineMs.reset();
    e.atDeadline = ActivityResult();
}

bool ActivityModel::end(const std::string &key, const ActivityResult &result, int64_t now,
                        std::optional<size_t> count) {
    prune(now);
    Entry *e = findRunning(key);
    if (e == nullptr) return false;
    finish(*e, result, now, count);
    return true;
}

bool ActivityModel::deadline(const std::string &key, int64_t at, const ActivityResult &result) {
    Entry *e = findRunning(key);
    if (e == nullptr) return false;
    e->deadlineMs = at;
    e->atDeadline = result;
    return true;
}

bool ActivityModel::clear() {
    const bool had = !entries_.empty();
    entries_.clear();
    return had;
}

bool ActivityModel::prune(int64_t now) {
    bool changed = false;
    for (Entry &e : entries_) {
        if (e.state != ActivityState::Running || !e.deadlineMs || *e.deadlineMs > now) continue;
        const ActivityResult result = e.atDeadline;
        finish(e, result, *e.deadlineMs, std::nullopt);
        changed = true;
    }
    const size_t before = entries_.size();
    entries_.erase(std::remove_if(entries_.begin(), entries_.end(), [now](const Entry &e) { return !shown(e, now); }),
                   entries_.end());
    return changed || entries_.size() != before;
}

namespace {

// The object of a text: the album's label for one, else the count. A
// scan's is its income's name (its count is the new albums of its result);
// the propose after it keeps that name as its label, so always the count.
std::string objectText(ActivityKind kind, size_t count, const std::string &label) {
    if (kind == ActivityKind::Swap) return plural(count, "playlist row", "playlist rows");
    if (kind == ActivityKind::Scan) return label;
    if (kind == ActivityKind::ScanThenPropose) return plural(count, "album", "albums");
    if (count == 1 && !label.empty()) return label;
    return plural(count, "album", "albums");
}

// "<first album> and N more" for more than one album; empty otherwise (and
// for a scan and the propose after it, whose label is an income).
std::string albumDetail(ActivityKind kind, size_t count, const std::string &label) {
    if (kind == ActivityKind::Swap || kind == ActivityKind::Scan || kind == ActivityKind::ScanThenPropose ||
        count < 2 || label.empty()) {
        return std::string();
    }
    return label + " and " + std::to_string(count - 1) + " more";
}

} // anonymous namespace

std::string ActivityModel::lineText(const Entry &e) {
    const Words w = wordsFor(e.kind);
    switch (e.state) {
        case ActivityState::Running:
            if (e.total > 1 && (e.done > 0 || !e.current.empty())) {
                std::string text = std::string(w.progress) + " " + std::to_string(e.done) + "/" +
                                   std::to_string(e.total);
                if (!e.current.empty()) text += ": " + e.current;
                return text;
            }
            return std::string(w.running) + " " + objectText(e.kind, e.count, e.label) + kEllipsis;
        case ActivityState::Succeeded: {
            // "Scanned local, proposed 2 albums": the income, then the count.
            if (e.kind == ActivityKind::ScanThenPropose) {
                return std::string(w.done) + " " + e.label + ", proposed " + plural(e.count, "album", "albums");
            }
            std::string text = std::string(w.done) + " " + objectText(e.kind, e.count, e.label);
            // A scan names what it found only when it found something.
            if (e.kind == ActivityKind::Scan && e.count > 0) text += ": " + plural(e.count, "new album", "new albums");
            return text;
        }
        case ActivityState::Failed:
            return e.reason.empty() ? std::string(w.failed) : std::string(w.failed) + ": " + e.reason;
    }
    return std::string();
}

ActivityItem ActivityModel::itemFor(const Entry &e) {
    ActivityItem item;
    item.id = e.id;
    item.state = e.state;
    item.startedMs = e.startedMs;
    item.endedMs = e.state == ActivityState::Running ? 0 : e.endedMs;
    const std::string albums = albumDetail(e.kind, e.count, e.label);
    if (e.state == ActivityState::Running) {
        item.done = e.done;
        item.total = e.total;
        if (e.total > 1 && (e.done > 0 || !e.current.empty())) {
            item.title = std::string(wordsFor(e.kind).progress) + " " + std::to_string(e.done) + "/" +
                         std::to_string(e.total);
            item.detail = e.current.empty() ? albums : e.current;
            return item;
        }
        item.title = lineText(e);
        item.detail = albums;
        return item;
    }
    item.title = lineText(e);
    item.detail = e.state == ActivityState::Failed && !e.detail.empty() ? e.detail : albums;
    return item;
}

std::optional<ActivityLine> ActivityModel::line(int64_t now) const {
    const Entry *top = nullptr;
    size_t running = 0;
    for (const Entry &e : entries_) {
        if (e.state != ActivityState::Running) continue;
        running++;
        if (top == nullptr || e.id > top->id) top = &e;
    }
    ActivityLine out;
    if (top != nullptr) {
        out.text = lineText(*top);
        if (running > 1) out.text += " (+" + std::to_string(running - 1) + " more)";
        out.done = top->done;
        out.total = top->total;
        out.icon = ActivityIcon::None;
        out.state = ActivityState::Running;
        return out;
    }
    const Entry *newest = nullptr;
    for (const Entry &e : entries_) {
        if (!shown(e, now)) continue;
        if (newest == nullptr || e.endSeq > newest->endSeq) newest = &e;
    }
    if (newest == nullptr) return std::nullopt;
    out.text = lineText(*newest);
    out.state = newest->state;
    out.icon = newest->state == ActivityState::Succeeded ? ActivityIcon::Check : ActivityIcon::Cross;
    return out;
}

std::vector<ActivityItem> ActivityModel::items(int64_t now) const {
    std::vector<const Entry *> running;
    std::vector<const Entry *> ended;
    for (const Entry &e : entries_) {
        if (e.state == ActivityState::Running) {
            running.push_back(&e);
        } else if (shown(e, now)) {
            ended.push_back(&e);
        }
    }
    std::sort(running.begin(), running.end(), [](const Entry *a, const Entry *b) { return a->id > b->id; });
    std::sort(ended.begin(), ended.end(), [](const Entry *a, const Entry *b) { return a->endSeq > b->endSeq; });
    std::vector<ActivityItem> out;
    out.reserve(running.size() + ended.size());
    for (const Entry *e : running) out.push_back(itemFor(*e));
    for (const Entry *e : ended) out.push_back(itemFor(*e));
    return out;
}

std::optional<int64_t> ActivityModel::nextExpiry(int64_t now) const {
    std::optional<int64_t> next;
    for (const Entry &e : entries_) {
        int64_t at = 0;
        if (e.state == ActivityState::Running) {
            if (!e.deadlineMs) continue;
            at = *e.deadlineMs;  // may be past: prune at once
        } else {
            if (!shown(e, now)) continue;
            at = e.endedMs + kActivityResultMs;
        }
        if (!next || at < *next) next = at;
    }
    return next;
}

bool ActivityModel::isRunning(const std::string &key) const {
    return findRunning(key) != nullptr;
}

size_t ActivityModel::runningCount() const {
    size_t n = 0;
    for (const Entry &e : entries_) {
        if (e.state == ActivityState::Running) n++;
    }
    return n;
}

} // namespace intake
