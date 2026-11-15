//
//  IntakeRootIndex.mm
//  foo_jl_intake
//

#import "IntakeRootIndex.h"

#include "IntakePath.h"

#include <functional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace {

// Transparent hash so lookups take a std::string_view of the query's ancestor
// without building a std::string for each one (C++20 heterogeneous lookup).
struct PathHash {
    using is_transparent = void;
    size_t operator()(std::string_view s) const noexcept {
        return std::hash<std::string_view>{}(s);
    }
};

} // anonymous namespace

@interface IntakeRoot ()
/// Normalized UTF-8 path, or empty when the path is unusable (never indexed).
- (const std::string &)jl_normalizedPath;
@end

@implementation IntakeRoot {
    std::string _normalizedPath;
}

- (instancetype)initWithIdentifier:(NSString *)identifier rootPath:(NSString *)rootPath {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        std::string raw;
        intake::copyUTF8(rootPath, raw);
        if (intake::normalizePath(raw, _normalizedPath) == intake::PathStatus::Ok) {
            _rootPath = [[NSString alloc] initWithBytes:_normalizedPath.data()
                                                 length:_normalizedPath.size()
                                               encoding:NSUTF8StringEncoding];
        }
        if (_rootPath == nil) {
            // Unusable (or not valid UTF-8 after normalization): keep the
            // path as given for diagnostics, and never index it.
            _normalizedPath.clear();
            _rootPath = [rootPath copy] ?: @"";
        }
    }
    return self;
}

- (const std::string &)jl_normalizedPath {
    return _normalizedPath;
}

@end

@implementation IntakeRootIndex {
    std::unordered_map<std::string, IntakeRoot *, PathHash, std::equal_to<>> _byPath;
    // _hasLength[n]: some indexed root path is exactly n bytes long. Lets the
    // ancestor walk skip the hash for lengths no root has.
    std::vector<bool> _hasLength;
    NSUInteger _rootCount;
}

- (void)setRoots:(NSArray<IntakeRoot *> *)roots {
    _byPath.clear();
    _hasLength.clear();
    _rootCount = roots.count;
    _byPath.reserve(roots.count);
    for (IntakeRoot *root in roots) {
        const std::string &key = [root jl_normalizedPath];
        if (key.empty()) continue;
        auto [it, inserted] = _byPath.try_emplace(key, root);
        if (!inserted && [root.identifier compare:it->second.identifier] == NSOrderedAscending) {
            // Shared directory (virtual roots): lowest identifier wins, so the
            // answer does not depend on the order the CLI listed them in.
            it->second = root;
        }
        if (key.size() >= _hasLength.size()) _hasLength.resize(key.size() + 1, false);
        _hasLength[key.size()] = true;
    }
}

- (NSUInteger)rootCount {
    return _rootCount;
}

// Nearest-ancestor lookup of an already-normalized path: the path itself,
// then each parent up to "/". The first hit is the deepest root containing
// the path, so a nested root wins over its parent.
- (IntakeRoot *)rootForNormalizedPath:(std::string_view)path {
    std::string_view candidate = path;
    const size_t lengths = _hasLength.size();
    while (true) {
        if (candidate.size() < lengths && _hasLength[candidate.size()]) {
            auto it = _byPath.find(candidate);
            if (it != _byPath.end()) return it->second;
        }
        if (candidate.size() <= 1) return nil;  // "/" was the last ancestor
        const size_t slash = candidate.rfind('/');
        candidate = candidate.substr(0, slash == 0 ? 1 : slash);
    }
}

- (IntakeRoot *)rootForUTF8Path:(const char *)path {
    if (path == nullptr || _byPath.empty()) return nil;
    std::string buffer;
    std::string_view normalized;
    if (intake::normalizePath(path, buffer, normalized) != intake::PathStatus::Ok) return nil;
    return [self rootForNormalizedPath:normalized];
}

- (IntakeRoot *)rootForFilePath:(NSString *)filePath {
    if (_byPath.empty() || filePath.length == 0) return nil;
    std::string raw;
    intake::copyUTF8(filePath, raw);
    std::string buffer;
    std::string_view normalized;
    if (intake::normalizePath(raw, buffer, normalized) != intake::PathStatus::Ok) return nil;
    return [self rootForNormalizedPath:normalized];
}

@end
