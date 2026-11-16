//
//  IntakeTestActionScript.mm
//  foo_jl_intake
//

#include "IntakeTestActionScript.h"

#include "IntakeCommandArgs.h"

#include <cmath>
#include <cstdlib>

namespace intake {

namespace {

bool isSpace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

std::string trim(const std::string &s) {
    size_t a = 0;
    size_t b = s.size();
    while (a < b && isSpace(s[a])) a++;
    while (b > a && isSpace(s[b - 1])) b--;
    return s.substr(a, b - a);
}

std::vector<std::string> words(const std::string &s) {
    std::vector<std::string> out;
    size_t i = 0;
    while (i < s.size()) {
        while (i < s.size() && isSpace(s[i])) i++;
        size_t start = i;
        while (i < s.size() && !isSpace(s[i])) i++;
        if (i > start) out.push_back(s.substr(start, i - start));
    }
    return out;
}

bool parseSeconds(const std::string &text, double &out) {
    if (text.empty()) return false;
    for (char c : text) {
        if (!((c >= '0' && c <= '9') || c == '.')) return false;
    }
    char *end = nullptr;
    const double v = std::strtod(text.c_str(), &end);
    if (end == nullptr || *end != '\0' || !std::isfinite(v)) return false;
    out = v;
    return true;
}

// The first position of `marker` at the start of a word, or npos.
size_t findMarker(const std::string &body, const char *marker) {
    size_t at = body.find(marker);
    while (at != std::string::npos) {
        if (at == 0 || isSpace(body[at - 1])) return at;
        at = body.find(marker, at + 1);
    }
    return std::string::npos;
}

// 0 < seconds <= kTestActionMaxWait; `what` names the value in the error.
bool parseBoundedSeconds(const std::string &text, const char *what, double &out, std::string &error) {
    double seconds = 0;
    if (!parseSeconds(text, seconds)) {
        error = std::string(what) + " needs one number of seconds";
        return false;
    }
    if (seconds <= 0 || seconds > kTestActionMaxWait) {
        error = std::string(what) + " must be more than 0 and at most 30 seconds";
        return false;
    }
    out = seconds;
    return true;
}

TestActionStep parseStep(const std::string &raw) {
    TestActionStep step;
    std::string body = trim(raw);
    step.text = body;

    // reason=<text> and collection=<name> take the rest of the step; the
    // first of the two wins.
    const size_t reasonAt = findMarker(body, "reason=");
    const size_t collectionAt = findMarker(body, "collection=");
    if (reasonAt != std::string::npos && (collectionAt == std::string::npos || reasonAt < collectionAt)) {
        step.reason = trim(body.substr(reasonAt + 7));
        step.hasReason = true;
        body = body.substr(0, reasonAt);
    } else if (collectionAt != std::string::npos) {
        step.collection = trim(body.substr(collectionAt + 11));
        step.hasCollection = true;
        body = body.substr(0, collectionAt);
    }

    std::vector<std::string> w = words(body);
    if (w.empty()) {
        step.error = "empty step";
        return step;
    }
    const std::string verb = w[0];
    std::vector<std::string> rest;
    std::string closeText;
    bool hasClose = false;
    for (size_t i = 1; i < w.size(); i++) {
        if (w[i].compare(0, 6, "close=") == 0) {
            if (hasClose) {
                step.error = "close= given twice";
                return step;
            }
            closeText = w[i].substr(6);
            hasClose = true;
        } else {
            rest.push_back(w[i]);
        }
    }
    if (hasClose && verb != "picker" && verb != "execute-sheet") {
        step.error = "only picker and execute-sheet take close=";
        return step;
    }

    if (verb == "runs") {
        if (step.hasReason) {
            step.error = "runs takes no reason";
            return step;
        }
        if (step.hasCollection) {
            step.error = "runs takes no collection";
            return step;
        }
        if (!rest.empty()) {
            step.error = "runs takes no ids";
            return step;
        }
        step.kind = TestStepKind::Runs;
        return step;
    }

    if (verb == "wait") {
        if (step.hasReason) {
            step.error = "wait takes no reason";
            return step;
        }
        if (step.hasCollection) {
            step.error = "wait takes no collection";
            return step;
        }
        if (rest.size() != 1) {
            step.error = "wait needs one number of seconds";
            return step;
        }
        if (!parseBoundedSeconds(rest[0], "wait", step.seconds, step.error)) return step;
        step.kind = TestStepKind::Wait;
        return step;
    }

    TestStepKind kind = TestStepKind::Invalid;
    IntakeAction action = IntakeAction::Refresh;
    if (verb == "menu") {
        kind = TestStepKind::Menu;
    } else if (verb == "badge") {
        kind = TestStepKind::Badge;
    } else if (verb == "propose") {
        kind = TestStepKind::Dispatch;
        action = IntakeAction::Propose;
    } else if (verb == "approve") {
        kind = TestStepKind::Dispatch;
        action = IntakeAction::Approve;
    } else if (verb == "reject") {
        kind = TestStepKind::Dispatch;
        action = IntakeAction::Reject;
    } else if (verb == "refresh") {
        kind = TestStepKind::Dispatch;
        action = IntakeAction::Refresh;
    } else if (verb == "assign") {
        kind = TestStepKind::Dispatch;
        action = IntakeAction::AssignTo;
    } else if (verb == "assign-other") {
        kind = TestStepKind::AssignOther;
        action = IntakeAction::AssignOther;
    } else if (verb == "picker") {
        kind = TestStepKind::Picker;
        action = IntakeAction::AssignOther;
    } else if (verb == "execute") {
        kind = TestStepKind::Execute;
        action = IntakeAction::Execute;
    } else if (verb == "execute-sheet") {
        kind = TestStepKind::ExecuteSheet;
        action = IntakeAction::Execute;
    } else if (verb == "resume") {
        kind = TestStepKind::Resume;
        action = IntakeAction::Resume;
    } else {
        step.error = "unknown step \"" + verb + "\"";
        return step;
    }
    if (step.hasReason && action != IntakeAction::Reject) {
        step.error = "only reject takes reason=";
        return step;
    }
    const bool takesCollection = verb == "assign" || verb == "assign-other";
    if (step.hasCollection && !takesCollection) {
        step.error = "only assign and assign-other take collection=";
        return step;
    }
    if (takesCollection && !step.hasCollection) {
        step.error = verb + " needs collection=<name>";
        return step;
    }
    if (takesCollection && step.collection.empty()) {
        step.error = "collection= needs a name";
        return step;
    }
    if (kind == TestStepKind::Picker || kind == TestStepKind::ExecuteSheet) {
        if (!hasClose) {
            step.error = verb + " needs close=<seconds>";
            return step;
        }
        if (!parseBoundedSeconds(closeText, "close", step.closeSeconds, step.error)) return step;
    }
    for (const std::string &id : rest) {
        if (!isSidecarId(id)) {
            step.error = "not a sidecar id: " + id;
            return step;
        }
        bool seen = false;
        for (const std::string &have : step.ids) seen = seen || have == id;
        if (!seen) step.ids.push_back(id);
    }
    const bool refresh = kind == TestStepKind::Dispatch && action == IntakeAction::Refresh;
    if (step.ids.empty() && !refresh) {
        step.error = verb + " needs at least one id";
        return step;
    }
    if (action == IntakeAction::AssignTo && step.ids.size() != 1) {
        step.error = "assign takes exactly one id";
        return step;
    }
    step.kind = kind;
    step.action = action;
    return step;
}

} // anonymous namespace

std::vector<TestActionStep> parseTestActions(const std::string &script) {
    std::vector<TestActionStep> steps;
    size_t start = 0;
    while (start <= script.size()) {
        size_t semi = script.find(';', start);
        if (semi == std::string::npos) semi = script.size();
        const std::string part = script.substr(start, semi - start);
        if (!trim(part).empty()) steps.push_back(parseStep(part));
        start = semi + 1;
    }
    return steps;
}

} // namespace intake
