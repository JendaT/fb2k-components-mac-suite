//
//  IntakeRootIndex.mm
//  foo_jl_intake
//

#import "IntakeRootIndex.h"

// Lexical normalization only — no filesystem access, so this stays pure and
// testable, and never blocks the decorate() path on a stat() of a NAS path.
static NSString *JLNormalizePath(NSString *path) {
    if (path.length == 0) return @"";
    NSString *standardized = [path stringByStandardizingPath];
    // stringByStandardizingPath keeps a trailing slash for "/" only; strip any
    // other so "/a/b/" and "/a/b" compare equal.
    while (standardized.length > 1 && [standardized hasSuffix:@"/"]) {
        standardized = [standardized substringToIndex:standardized.length - 1];
    }
    return standardized;
}

@implementation IntakeRoot

- (instancetype)initWithIdentifier:(NSString *)identifier rootPath:(NSString *)rootPath {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _rootPath = [JLNormalizePath(rootPath) copy];
    }
    return self;
}

@end

@implementation IntakeRootIndex {
    // Sorted by descending path length so the first prefix hit is the longest
    // (deepest) root. Root counts are small — tens, not thousands — so a linear
    // scan beats the bookkeeping of a trie; revisit if that stops being true.
    NSArray<IntakeRoot *> *_roots;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _roots = @[];
    }
    return self;
}

- (void)setRoots:(NSArray<IntakeRoot *> *)roots {
    _roots = [roots sortedArrayUsingComparator:^NSComparisonResult(IntakeRoot *a, IntakeRoot *b) {
        NSUInteger la = a.rootPath.length, lb = b.rootPath.length;
        if (la > lb) return NSOrderedAscending;   // longer first
        if (la < lb) return NSOrderedDescending;
        // Stable tiebreak so the index is deterministic for equal-length roots.
        return [a.rootPath compare:b.rootPath];
    }];
}

- (NSUInteger)rootCount {
    return _roots.count;
}

- (IntakeRoot *)rootForFilePath:(NSString *)filePath {
    if (_roots.count == 0 || filePath.length == 0) return nil;

    NSString *path = JLNormalizePath(filePath);
    for (IntakeRoot *root in _roots) {
        NSString *rootPath = root.rootPath;
        if (rootPath.length == 0) continue;
        if (path.length < rootPath.length) continue;
        if (![path hasPrefix:rootPath]) continue;
        // Exact match, or a real child: guard against "/a/bc" matching "/a/b".
        if (path.length == rootPath.length) return root;
        if ([path characterAtIndex:rootPath.length] == '/') return root;
    }
    return nil;
}

@end
