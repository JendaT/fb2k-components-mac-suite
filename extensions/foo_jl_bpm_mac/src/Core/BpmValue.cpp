//
//  BpmValue.cpp
//  foo_jl_bpm_mac
//

#include "BpmValue.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace bpm {

namespace {

bool isSpace(char c) {
    return std::isspace(static_cast<unsigned char>(c)) != 0;
}

bool closeTo(double value, double target) {
    const double tolerance = std::max(0.5, 0.01 * target);
    return std::fabs(value - target) <= tolerance;
}

} // namespace

std::optional<double> parseBpm(std::string_view text) {
    while (!text.empty() && isSpace(text.front())) text.remove_prefix(1);
    while (!text.empty() && isSpace(text.back())) text.remove_suffix(1);
    if (text.size() >= 3) {
        const std::string_view tail = text.substr(text.size() - 3);
        if (std::equal(tail.begin(), tail.end(), "bpm", [](char a, char b) {
                return std::tolower(static_cast<unsigned char>(a)) == b;
            })) {
            text.remove_suffix(3);
            while (!text.empty() && isSpace(text.back())) text.remove_suffix(1);
        }
    }
    if (text.empty() || text.size() > 32) return std::nullopt;

    std::string number(text);
    std::replace(number.begin(), number.end(), ',', '.');
    for (char c : number) {
        if (!std::isdigit(static_cast<unsigned char>(c)) && c != '.') return std::nullopt;
    }
    if (std::count(number.begin(), number.end(), '.') > 1 || number == ".") return std::nullopt;

    char *end = nullptr;
    const double value = std::strtod(number.c_str(), &end);
    if (end != number.c_str() + number.size()) return std::nullopt;
    if (!(value > 0.0) || !(value < 1000.0)) return std::nullopt;
    return value;
}

std::string formatBpmTag(double bpm) {
    return std::to_string(static_cast<long>(std::lround(bpm)));
}

std::string formatBpmExact(double bpm) {
    const double tenths = std::round(bpm * 10.0);
    if (std::fmod(tenths, 10.0) == 0.0) return std::to_string(static_cast<long>(tenths / 10.0));
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.1f", tenths / 10.0);
    return buf;
}

std::string formatBpmDisplay(double bpm) {
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.1f", bpm);
    return buf;
}

Agreement compareBpm(double existing, double estimate) {
    if (closeTo(estimate, existing)) return Agreement::Same;
    if (closeTo(estimate, existing * 2.0)) return Agreement::Double;
    if (closeTo(estimate, existing / 2.0)) return Agreement::Half;
    return Agreement::Different;
}

} // namespace bpm
