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

TestActionStep parseStep(const std::string &raw) {
    TestActionStep step;
    std::string body = trim(raw);
    step.text = body;

    // reason=<text> takes the rest of the step.
    const size_t reasonAt = body.find("reason=");
    if (reasonAt != std::string::npos && (reasonAt == 0 || isSpace(body[reasonAt - 1]))) {
        step.reason = trim(body.substr(reasonAt + 7));
        step.hasReason = true;
        body = body.substr(0, reasonAt);
    }

    std::vector<std::string> w = words(body);
    if (w.empty()) {
        step.error = "empty step";
        return step;
    }
    const std::string verb = w[0];
    std::vector<std::string> rest(w.begin() + 1, w.end());

    if (verb == "wait") {
        if (step.hasReason) {
            step.error = "wait takes no reason";
            return step;
        }
        double seconds = 0;
        if (rest.size() != 1 || !parseSeconds(rest[0], seconds)) {
            step.error = "wait needs one number of seconds";
            return step;
        }
        if (seconds <= 0 || seconds > kTestActionMaxWait) {
            step.error = "wait must be more than 0 and at most 30 seconds";
            return step;
        }
        step.kind = TestStepKind::Wait;
        step.seconds = seconds;
        return step;
    }

    TestStepKind kind = TestStepKind::Invalid;
    IntakeAction action = IntakeAction::Refresh;
    if (verb == "menu") {
        kind = TestStepKind::Menu;
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
    } else {
        step.error = "unknown step \"" + verb + "\"";
        return step;
    }
    if (step.hasReason && action != IntakeAction::Reject) {
        step.error = "only reject takes reason=";
        return step;
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
