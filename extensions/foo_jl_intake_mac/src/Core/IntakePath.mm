//
//  IntakePath.mm
//  foo_jl_intake
//

#include "IntakePath.h"

#import <CoreFoundation/CoreFoundation.h>

#include <functional>

namespace intake {

namespace {

constexpr std::string_view kFileScheme = "file://";

bool isAlpha(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

bool isDigit(char c) {
    return c >= '0' && c <= '9';
}

// RFC 3986: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ).
bool isScheme(std::string_view s) {
    if (s.empty() || !isAlpha(s[0])) return false;
    for (char c : s) {
        if (!isAlpha(c) && !isDigit(c) && c != '+' && c != '-' && c != '.') return false;
    }
    return true;
}

bool equalsIgnoringASCIICase(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++) {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z') x = static_cast<char>(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = static_cast<char>(y - 'A' + 'a');
        if (x != y) return false;
    }
    return true;
}

bool hasNonASCII(std::string_view s) {
    for (char c : s) {
        if (static_cast<unsigned char>(c) & 0x80) return true;
    }
    return false;
}

// True when `p` (which starts with '/') is ASCII and already in normal form,
// so it can be returned as is. One pass, no allocation.
bool isNormalASCII(std::string_view p) {
    const size_t n = p.size();
    for (size_t i = 0; i < n; i++) {
        const char c = p[i];
        if (static_cast<unsigned char>(c) & 0x80) return false;
        if (c != '/') continue;
        if (i + 1 == n) return n == 1;          // trailing '/', unless the path is "/"
        const char next = p[i + 1];
        if (next == '/') return false;          // "//"
        if (next != '.') continue;
        if (i + 2 == n || p[i + 2] == '/') return false;   // "/." segment
        if (p[i + 2] == '.' && (i + 3 == n || p[i + 3] == '/')) return false;  // "/.."
    }
    return true;
}

// Lexical normalisation of `p` (which starts with '/') into `out`.
void normalizeLexically(std::string_view p, std::string &out) {
    out.clear();
    out.reserve(p.size());
    const size_t n = p.size();
    size_t i = 0;
    while (i < n) {
        while (i < n && p[i] == '/') i++;
        size_t j = i;
        while (j < n && p[j] != '/') j++;
        const std::string_view seg = p.substr(i, j - i);
        i = j;
        if (seg.empty() || seg == ".") continue;
        if (seg == "..") {
            // Pop the last segment; at the top, ".." stays at "/".
            const size_t slash = out.rfind('/');
            out.resize(slash == std::string::npos ? 0 : slash);
            continue;
        }
        out += '/';
        out.append(seg.data(), seg.size());
    }
    if (out.empty()) out = "/";
}

// Rewrites `s` (UTF-8) to NFC in place. Leaves it unchanged when it is not
// valid UTF-8. Uses CoreFoundation directly, so nothing is autoreleased on
// the caller's thread.
void toNFC(std::string &s) {
    CFStringRef str = CFStringCreateWithBytes(kCFAllocatorDefault,
                                              reinterpret_cast<const UInt8 *>(s.data()),
                                              static_cast<CFIndex>(s.size()),
                                              kCFStringEncodingUTF8, false);
    if (!str) return;  // invalid UTF-8
    CFMutableStringRef mut = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, str);
    CFRelease(str);
    if (!mut) return;
    CFStringNormalize(mut, kCFStringNormalizationFormC);

    const CFRange range = CFRangeMake(0, CFStringGetLength(mut));
    CFIndex needed = 0;
    CFStringGetBytes(mut, range, kCFStringEncodingUTF8, 0, false, nullptr, 0, &needed);
    std::string result(static_cast<size_t>(needed), '\0');
    CFIndex used = 0;
    const CFIndex converted = CFStringGetBytes(mut, range, kCFStringEncodingUTF8, 0, false,
                                               reinterpret_cast<UInt8 *>(result.data()),
                                               needed, &used);
    CFRelease(mut);
    if (converted != range.length) return;
    result.resize(static_cast<size_t>(used));
    s.swap(result);
}

} // anonymous namespace

PathStatus normalizePath(std::string_view input, std::string &buffer, std::string_view &out) {
    out = std::string_view();
    if (input.empty()) return PathStatus::Empty;

    std::string_view p = input;
    if (p[0] != '/') {
        const size_t sep = p.find("://");
        if (sep == std::string_view::npos || !isScheme(p.substr(0, sep))) {
            return PathStatus::Relative;
        }
        if (!equalsIgnoringASCIICase(p.substr(0, sep + 3), kFileScheme)) {
            return PathStatus::UnhandledScheme;
        }
        p.remove_prefix(kFileScheme.size());
        if (p.empty()) return PathStatus::Empty;
        // "file://host/path": a remote host is not a local path.
        if (p[0] != '/') return PathStatus::UnhandledScheme;
    }

    if (isNormalASCII(p)) {
        out = p;
        return PathStatus::Ok;
    }

    // `input` may view `buffer` itself (a path written into the reusable
    // buffer, then normalized in place). normalizeLexically clears and
    // appends to `buffer` while reading `p`, so copy it out first.
    // std::less gives a total order even for unrelated pointers.
    const std::less<const char *> before;
    const char *const bufBegin = buffer.data();
    if (before(p.data(), bufBegin + buffer.capacity()) &&
        before(bufBegin, p.data() + p.size())) {
        const std::string copy(p);
        normalizeLexically(copy, buffer);
    } else {
        normalizeLexically(p, buffer);
    }
    if (hasNonASCII(buffer)) toNFC(buffer);
    out = buffer;
    return PathStatus::Ok;
}

bool asciiFolderOf(std::string_view input, std::string_view &head) {
    head = std::string_view();
    if (input.empty()) return false;
    std::string_view p = input;
    if (p[0] != '/') {
        // normalizePath accepts "file://" (any case) and then needs a '/'.
        if (p.size() < kFileScheme.size() ||
            !equalsIgnoringASCIICase(p.substr(0, kFileScheme.size()), kFileScheme)) {
            return false;
        }
        p.remove_prefix(kFileScheme.size());
        if (p.empty() || p[0] != '/') return false;
    }
    size_t first = 0;
    while (first < p.size() && !(static_cast<unsigned char>(p[first]) & 0x80)) first++;
    if (first == p.size()) return false;  // ASCII
    const size_t slash = p.rfind('/', first);
    if (slash == std::string_view::npos || slash == 0) return false;  // non-ASCII in the first segment
    // A ".." segment after the head could pop into it ("/a/b/é/../../c").
    const std::string_view rest = p.substr(slash + 1);
    size_t start = 0;
    while (start <= rest.size()) {
        size_t end = rest.find('/', start);
        if (end == std::string_view::npos) end = rest.size();
        if (end - start == 2 && rest[start] == '.' && rest[start + 1] == '.') return false;
        start = end + 1;
    }
    head = p.substr(0, slash);
    return true;
}

PathStatus normalizePath(std::string_view input, std::string &out) {
    std::string buffer;
    std::string_view view;
    const PathStatus status = normalizePath(input, buffer, view);
    if (status != PathStatus::Ok) {
        out.clear();
    } else if (view.data() == buffer.data()) {
        out.swap(buffer);
    } else {
        out.assign(view.data(), view.size());
    }
    return status;
}

const char *pathStatusName(PathStatus status) {
    switch (status) {
        case PathStatus::Ok: return "Ok";
        case PathStatus::Empty: return "Empty";
        case PathStatus::Relative: return "Relative";
        case PathStatus::UnhandledScheme: return "UnhandledScheme";
    }
    return "Unknown";
}

void copyUTF8(NSString *string, std::string &out) {
    out.clear();
    if (string == nil) return;
    CFStringRef cf = (__bridge CFStringRef)string;
    if (const char *fast = CFStringGetCStringPtr(cf, kCFStringEncodingUTF8)) {
        out.assign(fast);
        return;
    }
    const CFRange range = CFRangeMake(0, CFStringGetLength(cf));
    CFIndex needed = 0;
    CFStringGetBytes(cf, range, kCFStringEncodingUTF8, 0, false, nullptr, 0, &needed);
    out.resize(static_cast<size_t>(needed));
    CFIndex used = 0;
    CFStringGetBytes(cf, range, kCFStringEncodingUTF8, 0, false,
                     reinterpret_cast<UInt8 *>(out.data()), needed, &used);
    out.resize(static_cast<size_t>(used));
}

} // namespace intake

NSString *IntakeNormalizedPath(NSString *path, intake::PathStatus *status) {
    std::string raw;
    intake::copyUTF8(path, raw);
    std::string buffer;
    std::string_view out;
    const intake::PathStatus result = intake::normalizePath(raw, buffer, out);
    if (status) *status = result;
    if (result != intake::PathStatus::Ok) return nil;
    if (out.data() == raw.data() && out.size() == raw.size()) return [path copy];
    return [[NSString alloc] initWithBytes:out.data()
                                    length:out.size()
                                  encoding:NSUTF8StringEncoding];
}
