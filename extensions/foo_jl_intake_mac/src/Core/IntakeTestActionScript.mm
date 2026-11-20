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
    const std::string body = trim(raw);
    step.text = body;

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
    if (hasClose && verb != "delete-sheet") {
        step.error = "only delete-sheet takes close=";
        return step;
    }

    if (verb == "wait") {
        if (rest.size() != 1) {
            step.error = "wait needs one number of seconds";
            return step;
        }
        if (!parseBoundedSeconds(rest[0], "wait", step.seconds, step.error)) return step;
        step.kind = TestStepKind::Wait;
        return step;
    }

    TestStepKind kind = TestStepKind::Invalid;
    if (verb == "rows") {
        kind = TestStepKind::Rows;
    } else if (verb == "swap") {
        kind = TestStepKind::Swap;
    } else if (verb == "show") {
        kind = TestStepKind::Show;
    } else if (verb == "delete-sheet") {
        kind = TestStepKind::DeleteSheet;
    } else {
        step.error = "unknown step \"" + verb + "\"";
        return step;
    }
    if (kind == TestStepKind::DeleteSheet) {
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
    if ((kind == TestStepKind::Rows || kind == TestStepKind::Show) && step.ids.size() != 1) {
        step.error = verb + " takes exactly one id";
        return step;
    }
    if (step.ids.empty()) {
        step.error = verb + " needs at least one id";
        return step;
    }
    step.kind = kind;
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
