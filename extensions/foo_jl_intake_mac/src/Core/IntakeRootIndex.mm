//
//  IntakeRootIndex.mm
//  foo_jl_intake
//

#import "IntakeRootIndex.h"

#include "IntakePath.h"
#include "IntakePathMap.h"

#include <string>
#include <string_view>

@interface IntakeRoot ()
/// Normalized UTF-8 path, or empty when the path is unusable (never indexed).
- (const std::string &)jl_normalizedPath;
@end

@implementation IntakeRoot {
    std::string _normalizedPath;
}

- (instancetype)initWithIdentifier:(NSString *)identifier rootPath:(NSString *)rootPath {
    return [self initWithIdentifier:identifier rootPath:rootPath matchPath:nil];
}

- (instancetype)initWithIdentifier:(NSString *)identifier
                          rootPath:(NSString *)rootPath
                         matchPath:(NSString *)matchPath {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        // The CLI's spelling, untouched: the only one sure to address the
        // folder on disk (NFD names on SMB).
        _rootPath = [rootPath copy] ?: @"";
        std::string raw;
        intake::copyUTF8(matchPath ?: rootPath, raw);
        if (intake::normalizePath(raw, _normalizedPath) == intake::PathStatus::Ok) {
            _matchKey = [[NSString alloc] initWithBytes:_normalizedPath.data()
                                                 length:_normalizedPath.size()
                                               encoding:NSUTF8StringEncoding];
        }
        // Unusable (or not valid UTF-8 after normalization): never indexed.
        if (_matchKey == nil) _normalizedPath.clear();
    }
    return self;
}

- (const std::string &)jl_normalizedPath {
    return _normalizedPath;
}

@end

@implementation IntakeRootIndex {
    // Nearest-ancestor map over the roots' match keys (IntakePathMap.h),
    // shared with IntakeSnapshot.
    intake::PathMap<IntakeRoot *> _byPath;
    NSUInteger _rootCount;
}

- (void)setRoots:(NSArray<IntakeRoot *> *)roots {
    _byPath.clear();
    _rootCount = roots.count;
    _byPath.reserve(roots.count);
    for (IntakeRoot *root in roots) {
        // Unusable roots have an empty key, which the map ignores. A shared
        // directory (virtual roots): the lowest identifier wins, so the
        // answer does not depend on the order the CLI listed them in.
        _byPath.insert([root jl_normalizedPath], root, [](IntakeRoot *existing, IntakeRoot *candidate) {
            return [candidate.identifier compare:existing.identifier] == NSOrderedAscending;
        });
    }
}

- (NSUInteger)rootCount {
    return _rootCount;
}

// Nearest-ancestor lookup of an already-normalized path: the path itself,
// then each parent up to "/". The first hit is the deepest root containing
// the path, so a nested root wins over its parent.
- (IntakeRoot *)rootForNormalizedPath:(std::string_view)path {
    auto hit = _byPath.findNearest(path);
    return hit ? *hit : nil;
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
