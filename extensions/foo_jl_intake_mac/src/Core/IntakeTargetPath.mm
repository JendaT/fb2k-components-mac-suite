//
//  IntakeTargetPath.mm
//  foo_jl_intake
//

#include "IntakeTargetPath.h"

#include <CoreFoundation/CoreFoundation.h>

#include <vector>

namespace intake {

namespace {

bool hasNonAscii(std::string_view s) {
    for (unsigned char c : s) {
        if (c >= 0x80) return true;
    }
    return false;
}

bool isTrimmed(char c) {
    // JS \s for the ASCII range, plus '.', as sanitizeComponent trims them.
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r' || c == '.';
}

} // anonymous namespace

std::string nfcText(std::string_view text) {
    std::string s(text);
    if (!hasNonAscii(s)) return s;
    CFStringRef str = CFStringCreateWithBytes(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(s.data()),
                                              static_cast<CFIndex>(s.size()), kCFStringEncodingUTF8, false);
    if (!str) return s;  // invalid UTF-8
    CFMutableStringRef mut = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, str);
    CFRelease(str);
    if (!mut) return s;
    CFStringNormalize(mut, kCFStringNormalizationFormC);
    const CFRange range = CFRangeMake(0, CFStringGetLength(mut));
    CFIndex needed = 0;
    CFStringGetBytes(mut, range, kCFStringEncodingUTF8, 0, false, nullptr, 0, &needed);
    std::string result(static_cast<size_t>(needed), '\0');
    CFIndex used = 0;
    const CFIndex converted = CFStringGetBytes(mut, range, kCFStringEncodingUTF8, 0, false,
                                               reinterpret_cast<UInt8 *>(result.data()), needed, &used);
    CFRelease(mut);
    if (converted != range.length) return s;
    result.resize(static_cast<size_t>(used));
    return result;
}

std::string sanitizedPathComponent(std::string_view name) {
    std::string out;
    out.reserve(name.size());
    for (char c : name) {
        const unsigned char u = static_cast<unsigned char>(c);
        if (c == '/' || c == '\\' || c == ':') {
            out += '-';
        } else if (u < 0x20) {
            continue;
        } else {
            out += c;
        }
    }
    size_t begin = 0;
    while (begin < out.size() && isTrimmed(out[begin])) begin++;
    size_t end = out.size();
    while (end > begin && isTrimmed(out[end - 1])) end--;
    return out.substr(begin, end - begin);
}

std::string displayTargetPath(std::string_view targetPath, std::string_view collection) {
    const std::string path = nfcText(targetPath);
    std::vector<std::string_view> parts;
    size_t pos = 0;
    while (pos <= path.size()) {
        size_t slash = path.find('/', pos);
        if (slash == std::string::npos) slash = path.size();
        if (slash > pos) parts.emplace_back(path.data() + pos, slash - pos);
        pos = slash + 1;
    }
    if (parts.empty()) return std::string();

    size_t start = parts.size() > 4 ? parts.size() - 4 : 0;
    const std::string want = nfcText(collection);
    if (!want.empty()) {
        const std::string sanitized = sanitizedPathComponent(want);
        for (size_t i = 0; i < parts.size(); i++) {
            if (parts[i] == want || (!sanitized.empty() && parts[i] == sanitized)) {
                start = i > 0 ? i - 1 : 0;
                break;
            }
        }
    }

    std::string out;
    for (size_t i = start; i < parts.size(); i++) {
        if (!out.empty()) out += '/';
        out.append(parts[i].data(), parts[i].size());
    }
    return out;
}

} // namespace intake
