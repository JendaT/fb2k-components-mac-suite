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
//  caller's problem, which is why this module is unaffected by the open doc 03
//  change requests (CR-002).
//
//  Thread-safety: none. The owner serializes access. Decorate() runs off the
//  main thread and may run concurrently across panels (jl_decorator_api.h), so
//  the provider holds this behind its own lock.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One intake release root, as reported by `intake status --json`.
@interface IntakeRoot : NSObject
/// Sidecar id (doc 03: roots are addressed by sidecar id OR absolute path).
@property (nonatomic, copy, readonly) NSString *identifier;
/// Absolute directory path of the release root.
@property (nonatomic, copy, readonly) NSString *rootPath;

- (instancetype)initWithIdentifier:(NSString *)identifier
                          rootPath:(NSString *)rootPath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Resolves file paths to the intake root that contains them.
///
/// Matching is by path prefix on normalized absolute paths, longest root first,
/// so a nested root wins over its parent. A path equal to a root matches that
/// root. Matching is case-sensitive: APFS is case-insensitive by default but
/// the CLI reports the paths it walked, and lowercasing would break on
/// case-sensitive volumes; callers that need otherwise normalize first.
@interface IntakeRootIndex : NSObject

/// Replaces the entire root set (a full `status --json` load).
- (void)setRoots:(NSArray<IntakeRoot *> *)roots;

/// The root containing `filePath`, or nil. Paths are normalized (trailing
/// slashes stripped, `.`/`..` resolved lexically) before comparison.
- (nullable IntakeRoot *)rootForFilePath:(NSString *)filePath;

/// Number of roots currently indexed. Zero means the provider has nothing to
/// decorate and can answer every batch without allocating.
@property (nonatomic, readonly) NSUInteger rootCount;

@end

NS_ASSUME_NONNULL_END
