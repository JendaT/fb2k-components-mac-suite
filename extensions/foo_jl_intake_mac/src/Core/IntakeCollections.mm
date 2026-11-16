//
//  IntakeCollections.mm
//  foo_jl_intake
//

#include "IntakeCollections.h"

#include "IntakeErrorMap.h"

#import <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cmath>
#include <unordered_set>

namespace intake {

namespace {

bool isBoolean(id value) {
    return [value isKindOfClass:[NSNumber class]] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

// A finite JSON number that is not a boolean.
bool countValue(id value, double &out) {
    if (![value isKindOfClass:[NSNumber class]] || isBoolean(value)) return false;
    const double v = [value doubleValue];
    if (!std::isfinite(v)) return false;
    out = v;
    return true;
}

bool utf8Name(id value, std::string &out) {
    if (![value isKindOfClass:[NSString class]]) return false;
    NSString *text = value;
    const NSUInteger bytes = [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (bytes == 0) return false;
    std::string s(bytes, '\0');
    NSUInteger used = 0;
    if (![text getBytes:s.data()
                maxLength:bytes
               usedLength:&used
                 encoding:NSUTF8StringEncoding
                  options:0
                    range:NSMakeRange(0, text.length)
           remainingRange:nullptr] ||
        used != bytes) {
        return false;
    }
    if (s.find('\0') != std::string::npos) return false;
    out = std::move(s);
    return true;
}

// The NFC form of UTF-8 `s`, or nil when it is not valid UTF-8.
NSString *precomposed(const std::string &s) {
    NSString *text = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return text.precomposedStringWithCanonicalMapping;
}

} // anonymous namespace

CollectionsParseResult parseCollections(id data, size_t maxEntries) {
    CollectionsParseResult result;
    @autoreleasepool {
        if (![data isKindOfClass:[NSArray class]]) {
            result.error = data == nil || data == [NSNull null] ? "data is null" : "data is not an array";
            return result;
        }
        if ([(NSArray *)data count] > maxEntries) {
            result.error = "more than " + std::to_string(maxEntries) + " entries";
            return result;
        }
        result.ok = true;
        std::unordered_set<std::string> seen;
        for (id entry in (NSArray *)data) {
            if (![entry isKindOfClass:[NSDictionary class]]) {
                result.skipped++;
                continue;
            }
            NSDictionary *dict = entry;
            CollectionInfo info;
            if (!utf8Name(dict[@"collection"], info.name)) {
                result.skipped++;
                continue;
            }
            if (!seen.insert(info.name).second) {
                result.duplicates++;
                continue;
            }
            info.hasArtists = countValue(dict[@"artists"], info.artists);
            info.hasReleases = countValue(dict[@"releases"], info.releases);
            result.collections.push_back(std::move(info));
        }
    }
    return result;
}

std::vector<std::string> collectionNames(const std::vector<CollectionInfo> &collections) {
    std::vector<std::string> out;
    out.reserve(collections.size());
    for (const CollectionInfo &c : collections) out.push_back(c.name);
    return out;
}

const std::string *listedCollectionFor(const std::vector<std::string> &names, const std::string &text) {
    if (text.empty()) return nullptr;
    auto exact = std::find(names.begin(), names.end(), text);
    if (exact != names.end()) return &*exact;
    const std::string *found = nullptr;
    @autoreleasepool {
        NSString *wanted = precomposed(text);
        if (wanted == nil) return nullptr;
        for (const std::string &name : names) {
            NSString *candidate = precomposed(name);
            if (candidate == nil || ![candidate isEqualToString:wanted]) continue;
            if (found != nullptr) return nullptr;  // ambiguous
            found = &name;
        }
    }
    return found;
}

bool isListedCollection(const std::vector<std::string> &names, const std::string &text) {
    return listedCollectionFor(names, text) != nullptr;
}

std::string collectionsFailureText(const EnvelopeResult &result) {
    if (result.errors.empty()) return cliOutcomeName(result.outcome);
    std::string out = renderError(result.errors.front());
    if (result.errors.size() > 1) out += " (+" + std::to_string(result.errors.size() - 1) + " more)";
    return out;
}

} // namespace intake
