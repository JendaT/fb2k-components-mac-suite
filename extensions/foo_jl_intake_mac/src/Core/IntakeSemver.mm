//
//  IntakeSemver.mm
//  foo_jl_intake
//

#include "IntakeSemver.h"

namespace intake {

namespace {

// One numeric part: 1 to 9 digits, no leading zero unless it is "0".
// Nine digits keep the value inside int without any overflow check.
bool parsePart(std::string_view part, int &value) {
    if (part.empty() || part.size() > 9) return false;
    if (part.size() > 1 && part[0] == '0') return false;
    int v = 0;
    for (char c : part) {
        if (c < '0' || c > '9') return false;
        v = v * 10 + (c - '0');
    }
    value = v;
    return true;
}

} // anonymous namespace

bool parseSemver(std::string_view text, SemVer &out) {
    size_t firstDot = text.find('.');
    if (firstDot == std::string_view::npos) return false;
    size_t secondDot = text.find('.', firstDot + 1);
    if (secondDot == std::string_view::npos) return false;

    SemVer v;
    if (!parsePart(text.substr(0, firstDot), v.major)) return false;
    if (!parsePart(text.substr(firstDot + 1, secondDot - firstDot - 1), v.minor)) return false;
    // The rest must be the patch alone: a third dot, '-' or '+' fails here.
    if (!parsePart(text.substr(secondDot + 1), v.patch)) return false;
    out = v;
    return true;
}

bool semverAtLeast(std::string_view version, int major, int minor, int patch) {
    SemVer v;
    if (!parseSemver(version, v)) return false;
    if (v.major != major) return v.major > major;
    if (v.minor != minor) return v.minor > minor;
    return v.patch >= patch;
}

} // namespace intake
