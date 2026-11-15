//
//  IntakeRootIndex.h
//  foo_jl_intake
//
//  Maps playlist file paths to intake sidecar roots.
//
//  Doc 03, "Component read patterns": the component matches playlist row paths
//  against sidecar roots obtained from `intake status --json`. This is that
//  match, isolated as pure logic: no SDK, no Cocoa beyond Foundation, no I/O.
//  Where the roots come from (and what else the summary carries) is the
//  caller's problem.
//
//  Thread-safety: setRoots: must not run concurrently with anything else on
//  the same index; the owner serializes it. Lookups do not mutate the index,
//  so any number of them may run concurrently while no setRoots: is in
//  progress. Decorate() runs off the main thread and may run concurrently
//  across panels (jl_decorator_api.h), so the provider either holds the index
//  behind its own lock or swaps in a fresh, never-mutated index.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One intake release root, as reported by `intake status --json`.
@interface IntakeRoot : NSObject
/// Sidecar id (doc 03: roots are addressed by sidecar id OR absolute path).
@property (nonatomic, copy, readonly) NSString *identifier;
/// The release root's directory exactly as the CLI reported it (`root_path`).
/// This is the path for filesystem access (sidecars, watch paths, stat):
/// on SMB and HFS+ the on-disk name may be NFD, and only this spelling is
/// sure to address the folder.
@property (nonatomic, copy, readonly) NSString *rootPath;
/// The lookup key: the match path normalized with IntakePath (file://
/// stripped, lexical normalization, NFC). Never use it for I/O. nil when
/// IntakePath cannot handle the match path (empty, relative, another
/// scheme); such a root never matches anything.
@property (nonatomic, copy, readonly, nullable) NSString *matchKey;

/// Matches on `rootPath` itself.
- (instancetype)initWithIdentifier:(NSString *)identifier rootPath:(NSString *)rootPath;
/// Matches on `matchPath` when given (e.g. a mount-alias key such as
/// "/smbfs:<share>/<relative>", which must start with '/'), else on
/// `rootPath`. `rootPath` is kept as given either way.
- (instancetype)initWithIdentifier:(NSString *)identifier
                          rootPath:(NSString *)rootPath
                         matchPath:(nullable NSString *)matchPath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Resolves file paths to the intake root that contains them.
///
/// Both sides are normalized with IntakePath (lexical only, no filesystem
/// access, then NFC), so "/private/tmp" and "/tmp" stay different and an NFD
/// query matches an NFC root. Queries in another key namespace (a mount-alias
/// key) must be spelled the way the roots' match paths were, starting with
/// '/'. A path equal to a root matches that root; a nested root wins over its
/// parent (the nearest ancestor wins). Matching is case-sensitive: APFS is
/// case-insensitive by default but the CLI reports the paths it walked, and
/// lowercasing would break on case-sensitive volumes; callers that need
/// otherwise normalize first.
///
/// Lookup walks the query's ancestors through a hash map, so its cost grows
/// with the path's depth, not with the number of roots.
///
/// Several roots may share one directory (virtual roots, `.intake.<id>.json`).
/// The index answers one of them deterministically, the lowest identifier;
/// telling their member files apart needs the sidecars' `files[]`.
@interface IntakeRootIndex : NSObject

/// Replaces the entire root set (a full `status --json` load).
- (void)setRoots:(NSArray<IntakeRoot *> *)roots;

/// The root containing `filePath`, or nil. Accepts native POSIX paths and
/// file:// paths; any other scheme (mac-volume://, ...) matches nothing and
/// must be converted to a native path first.
- (nullable IntakeRoot *)rootForFilePath:(NSString *)filePath;

/// Same as rootForFilePath: for a NUL-terminated UTF-8 path, such as
/// foobar2000's own path strings. The already-normal ASCII case allocates
/// nothing; this is the variant for the decorate path. NULL matches nothing.
- (nullable IntakeRoot *)rootForUTF8Path:(const char *_Nullable)path;

/// Number of roots passed to the last setRoots:, including any whose path is
/// unusable. Zero means the provider has nothing to decorate and can answer
/// every batch without allocating.
@property (nonatomic, readonly) NSUInteger rootCount;

@end

NS_ASSUME_NONNULL_END
