//
// JLComponentInstaller.h - downloads a suite component from its GitHub
// release and installs it into foobar2000's user-components folder, for a
// dependent's preferences (JLDependencyGate). Foundation only, no
// foobar2000 SDK: the folder is passed in, so it runs outside the host too.
//
// Trust model: HTTPS to GitHub only (its API, the release's own download
// URLs, and redirects only to GitHub's two release storage hosts), the
// suite's repository pinned in every URL, the exact asset name, and its
// SHA-256 from the release's SHA256SUMS: whoever can publish a release can
// publish a matching checksum, so this protects the download, not against a
// compromised GitHub account (signed checksums would). After that the
// package must look like one component: zipinfo's listing is a first filter
// (it reads the central directory, ditto the local headers, so it is not
// the guard), then the unpacked tree is walked (no symlinks, nothing
// outside the bundle), and the bundle's executable, version and code
// signature are checked. The suite's bundles are signed ad hoc, so
// codesign proves the bundle is intact, not who made it.
//
// Objective-C++ (releasesFromJSON returns the core's types). Define
// JL_DEPENDENCY_PREFIX first (see jl_dependency_names.h).
//

#pragma once

#import <Foundation/Foundation.h>

#include "jl_dependency_names.h"
#include "jl_dependency_core.h"

#include <vector>

NS_ASSUME_NONNULL_BEGIN

// What a dependent needs and where it comes from
@interface JLDependencyDescriptor : NSObject
@property (nonatomic, copy) NSString *component;        // "foo_jl_bpm": folder, bundle and executable name
@property (nonatomic, copy) NSString *displayName;      // "BPM Analyzer"
@property (nonatomic, copy) NSString *tagPrefix;        // "bpm-v"
@property (nonatomic, copy) NSString *assetName;        // "foo_jl_bpm.fb2k-component"
@property (nonatomic, copy) NSString *minVersion;       // the oldest version the dependent works with
@property (nonatomic, copy) NSString *repository;       // "JendaT/fb2k-components-mac-suite"
@property (nonatomic, copy) NSString *featureName;      // "Phrase markers"
@property (nonatomic, copy) NSString *dependentName;    // "Waveform Seekbar"
- (NSString *)releasesPageURL;
@end

// The release picked for installing
@interface JLReleaseInfo : NSObject
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *tag;
@property (nonatomic, copy) NSString *packageURL;
@property (nonatomic, copy) NSString *sumsURL;
@property (nonatomic) uint64_t packageSize;
@end

// Progress on the main queue: what is happening, and how far (0..1, or
// negative when unknown)
typedef void (^JLInstallProgress)(NSString *step, double fraction);

@interface JLComponentInstaller : NSObject

- (instancetype)initWithDescriptor:(JLDependencyDescriptor *)descriptor userComponents:(NSString *)folder;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) JLDependencyDescriptor *descriptor;
@property (nonatomic, readonly) NSString *userComponents;   // symlinks resolved

// user-components/<component>/<component>.component
- (NSString *)installedBundlePath;
// The installed bundle's CFBundleShortVersionString; nil when there is none
- (nullable NSString *)installedVersion;
+ (nullable NSString *)versionOfBundleAt:(NSString *)path;

// The newest published release of the component: its newest tags from the
// repository's tag list, then each tag's release until one is published
// with both assets (never drafts or prereleases, never another
// component's). `done` on the main queue; cancel stops it (done with nil, nil).
- (void)lookUp:(void (^)(JLReleaseInfo *_Nullable release, NSString *_Nullable error))done;

// Download, verify and install `release`. `done` on the main queue with nil
// on success; `cancelled` when cancel stopped it first (a cancel once the
// bundle is moving into place no longer stops it). Holds the install lock
// for the whole run; a bundle it replaces is set aside, removed next launch.
- (void)install:(JLReleaseInfo *)release
       progress:(JLInstallProgress)progress
           done:(void (^)(NSString *_Nullable error, BOOL cancelled))done;
- (void)cancel;

// Another dependent's name while it holds the install lock; else nil
- (nullable NSString *)lockHolder;

// At launch: puts a set-aside bundle back if an install died between moving
// it aside and moving the new one in, removes the other set-aside bundles,
// and removes work files an interrupted install left behind
- (void)cleanUpAtLaunch;

+ (std::vector<jl_dep::Release>)releasesFromJSON:(nullable NSData *)data;
+ (std::vector<std::string>)refNamesFromJSON:(nullable NSData *)data;

@end

NS_ASSUME_NONNULL_END
