//
//  IntakeCollectionSearch.mm
//  foo_jl_intake
//

#include "IntakeCollectionSearch.h"

#include "IntakeCollections.h"

#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <unordered_set>

namespace intake {

namespace {

bool isAsciiSpace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

// A letter or digit for the word-start rule: ASCII alphanumerics and every
// non-ASCII byte (folding leaves few, and they belong to letters).
bool isWordByte(unsigned char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80;
}

std::string foldWithCF(std::string_view text) {
    std::string s(text);
    CFStringRef str = CFStringCreateWithBytes(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(s.data()),
                                              static_cast<CFIndex>(s.size()), kCFStringEncodingUTF8, false);
    if (!str) return s;  // invalid UTF-8: compared as it is
    CFMutableStringRef mut = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, str);
    CFRelease(str);
    if (!mut) return s;
    CFStringFold(mut, kCFCompareCaseInsensitive | kCFCompareDiacriticInsensitive | kCFCompareWidthInsensitive,
                 nullptr);
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

// 0: at the start, 1: at a word start, 2: elsewhere, 3: no match.
int matchRank(const std::string &key, const std::string &query) {
    int best = 3;
    for (size_t pos = key.find(query); pos != std::string::npos; pos = key.find(query, pos + 1)) {
        if (pos == 0) return 0;
        const int rank = isWordByte(static_cast<unsigned char>(key[pos - 1])) ? 2 : 1;
        best = std::min(best, rank);
        if (best == 1) break;  // a later start cannot reach 0
    }
    return best;
}

} // anonymous namespace

std::string searchKey(std::string_view text) {
    bool ascii = true;
    for (unsigned char c : text) {
        if (c >= 0x80) {
            ascii = false;
            break;
        }
    }
    std::string folded;
    if (ascii) {
        folded.reserve(text.size());
        for (char c : text) folded += (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
    } else {
        folded = foldWithCF(text);
    }
    std::string out;
    out.reserve(folded.size());
    for (char c : folded) {
        if (c != '[' && c != ']') out += c;
    }
    size_t begin = 0;
    while (begin < out.size() && isAsciiSpace(out[begin])) begin++;
    size_t end = out.size();
    while (end > begin && isAsciiSpace(out[end - 1])) end--;
    return out.substr(begin, end - begin);
}

std::vector<size_t> matchCollections(const std::vector<std::string> &names, std::string_view query) {
    std::vector<size_t> out;
    const std::string q = searchKey(query);
    if (q.empty()) {
        out.reserve(names.size());
        for (size_t i = 0; i < names.size(); i++) out.push_back(i);
        return out;
    }
    struct Hit {
        size_t index;
        int rank;
        std::string key;
    };
    std::vector<Hit> hits;
    for (size_t i = 0; i < names.size(); i++) {
        std::string key = searchKey(names[i]);
        const int rank = matchRank(key, q);
        if (rank < 3) hits.push_back({i, rank, std::move(key)});
    }
    std::stable_sort(hits.begin(), hits.end(), [&names](const Hit &a, const Hit &b) {
        if (a.rank != b.rank) return a.rank < b.rank;
        if (a.key != b.key) return a.key < b.key;
        return names[a.index] < names[b.index];
    });
    out.reserve(hits.size());
    for (const Hit &h : hits) out.push_back(h.index);
    return out;
}

std::vector<std::string> parseRecentCollections(std::string_view stored) {
    std::vector<std::string> out;
    std::unordered_set<std::string> seen;
    size_t pos = 0;
    while (pos <= stored.size() && out.size() < kRecentCollectionsMax) {
        size_t end = stored.find('\n', pos);
        if (end == std::string_view::npos) end = stored.size();
        std::string_view line = stored.substr(pos, end - pos);
        if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
        if (!line.empty() && seen.insert(std::string(line)).second) out.emplace_back(line);
        pos = end + 1;
    }
    return out;
}

std::string formatRecentCollections(const std::vector<std::string> &recent) {
    std::string out;
    for (const std::string &name : recent) {
        if (!out.empty()) out += '\n';
        out += name;
    }
    return out;
}

std::vector<std::string> updateRecentCollections(const std::vector<std::string> &recent, const std::string &chosen,
                                                 const std::vector<std::string> &names) {
    std::vector<std::string> candidates;
    candidates.reserve(recent.size() + 1);
    if (!chosen.empty()) candidates.push_back(chosen);
    candidates.insert(candidates.end(), recent.begin(), recent.end());
    std::vector<std::string> out;
    std::unordered_set<std::string> seen;
    for (const std::string &name : candidates) {
        if (out.size() >= kRecentCollectionsMax) break;
        if (name.empty()) continue;
        std::string kept = name;
        if (!names.empty()) {
            const std::string *listed = listedCollectionFor(names, name);
            if (listed == nullptr) continue;
            kept = *listed;
        }
        if (seen.insert(kept).second) out.push_back(std::move(kept));
    }
    return out;
}

std::vector<std::string> shownRecentCollections(const std::vector<std::string> &recent,
                                                const std::vector<std::string> &names) {
    std::vector<std::string> out;
    std::unordered_set<std::string> seen;
    for (const std::string &name : recent) {
        if (out.size() >= kRecentCollectionsMax) break;
        const std::string *listed = name.empty() ? nullptr : listedCollectionFor(names, name);
        if (listed != nullptr && seen.insert(*listed).second) out.push_back(*listed);
    }
    return out;
}

std::vector<std::string> suggestedCollections(const std::vector<std::string> &topRanked,
                                              const std::vector<std::string> &names) {
    std::vector<std::string> out;
    std::unordered_set<std::string> seen;
    for (const std::string &name : topRanked) {
        if (out.size() >= kSuggestedCollectionsMax) break;
        const std::string *listed = name.empty() ? nullptr : listedCollectionFor(names, name);
        if (listed != nullptr && seen.insert(*listed).second) out.push_back(*listed);
    }
    return out;
}

std::vector<PickerRow> pickerRows(const std::vector<std::string> &suggested, const std::vector<std::string> &recent,
                                  const std::vector<std::string> &names, std::string_view query) {
    std::vector<PickerRow> rows;
    if (!searchKey(query).empty()) {
        for (size_t index : matchCollections(names, query)) rows.push_back({false, names[index]});
        return rows;
    }
    auto section = [&rows](const char *title, const std::vector<std::string> &list) {
        if (list.empty()) return;
        rows.push_back({true, title});
        for (const std::string &name : list) rows.push_back({false, name});
    };
    section("Suggested", suggested);
    section("Recent", recent);
    section("All collections", names);
    return rows;
}

long pickerHighlight(const std::vector<PickerRow> &rows, const std::vector<std::string> &names, std::string_view query) {
    if (searchKey(query).empty()) return -1;
    if (const std::string *exact = listedCollectionFor(names, std::string(query))) {
        for (size_t i = 0; i < rows.size(); i++) {
            if (!rows[i].header && rows[i].text == *exact) return static_cast<long>(i);
        }
    }
    for (size_t i = 0; i < rows.size(); i++) {
        if (!rows[i].header) return static_cast<long>(i);
    }
    return -1;
}

} // namespace intake
