//
//  UUIDRemappingWindowController.h
//  foo_plorg_mac
//
//  Network Volume UUID Remapping Tool
//  Repairs orphaned playlist entries caused by network volume UUID changes
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Error Domain

extern NSErrorDomain const UUIDRemappingErrorDomain;

typedef NS_ERROR_ENUM(UUIDRemappingErrorDomain, UUIDRemappingErrorCode) {
    UUIDRemappingErrorBackupFailed = 1,
    UUIDRemappingErrorFileWriteFailed = 2,
    UUIDRemappingErrorFileLocked = 3,
    UUIDRemappingErrorVolumeUnmounted = 4,
    UUIDRemappingErrorNoPlaylistsFound = 5,
};

#pragma mark - Data Structures

/// Represents a single UUID and its usage statistics
@interface VolumeUUIDEntry : NSObject

@property (nonatomic, copy, readonly) NSString *uuid;
@property (nonatomic, assign, readonly) NSUInteger entryCount;
@property (nonatomic, assign, readonly) BOOL isActive;
@property (nonatomic, copy, readonly, nullable) NSString *mountPath;
@property (nonatomic, strong, readonly) NSSet<NSString *> *affectedPlaylistPaths;
@property (nonatomic, strong, readonly) NSDictionary<NSString *, NSNumber *> *perPlaylistCounts;  // path -> count

- (instancetype)initWithUUID:(NSString *)uuid
                  entryCount:(NSUInteger)entryCount
                    isActive:(BOOL)isActive
                   mountPath:(nullable NSString *)mountPath
       affectedPlaylistPaths:(NSSet<NSString *> *)paths
          perPlaylistCounts:(NSDictionary<NSString *, NSNumber *> *)perPlaylistCounts;

/// Returns entry count for a specific playlist path
- (NSUInteger)entryCountForPlaylist:(NSString *)playlistPath;

@end

/// Represents a discovered mount point with its UUIDs
@interface MountPointGroup : NSObject

@property (nonatomic, copy, readonly) NSString *mountPointName;
@property (nonatomic, strong, readonly) NSArray<VolumeUUIDEntry *> *uuidEntries;
@property (nonatomic, strong, readonly, nullable) VolumeUUIDEntry *activeEntry;

- (instancetype)initWithMountPointName:(NSString *)name
                           uuidEntries:(NSArray<VolumeUUIDEntry *> *)entries;

/// Returns all orphaned (non-active) UUID entries
- (NSArray<VolumeUUIDEntry *> *)orphanedEntries;

/// Total entry count across all UUIDs
- (NSUInteger)totalEntryCount;

@end

/// User's remapping decision for a mount point
@interface RemappingAction : NSObject

@property (nonatomic, strong) MountPointGroup *group;
@property (nonatomic, copy) NSString *targetUUID;
@property (nonatomic, copy, nullable) NSString *updatedMountPointName;
@property (nonatomic, strong) NSSet<NSString *> *sourceUUIDs;

@end

#pragma mark - Delegate Protocol

@class UUIDRemappingWindowController;

@protocol UUIDRemappingWindowDelegate <NSObject>

/// Called on main thread when remapping completes (with or without errors).
/// @param controller The window controller
/// @param changedFiles Full paths to successfully modified playlist files
/// @param errors Array of NSError for files that failed (empty if all succeeded)
/// @note Unlike PathMappingWindowDelegate, this includes errors parameter because
///       UUID remapping has more failure modes (volume unmount, file locks, etc.)
- (void)uuidRemappingDidComplete:(UUIDRemappingWindowController *)controller
                    changedFiles:(NSArray<NSString *> *)changedFiles
                          errors:(NSArray<NSError *> *)errors;

/// Called on main thread when user cancels or closes window during operation.
- (void)uuidRemappingDidCancel:(UUIDRemappingWindowController *)controller;

@optional

/// Called on main thread for critical failures (backup creation failed, etc.)
/// If not implemented, controller shows alert and calls didCancel.
- (void)uuidRemappingDidFail:(UUIDRemappingWindowController *)controller
                       error:(NSError *)error;

@end

#pragma mark - Window Controller

@interface UUIDRemappingWindowController : NSWindowController

@property (nonatomic, weak) id<UUIDRemappingWindowDelegate> delegate;

/// Begins asynchronous scanning of all playlist files at the specified directory.
/// Returns immediately. Shows window and displays progress.
/// Scanning runs on background thread; delegate methods called on main thread.
/// Closing the window during scan triggers uuidRemappingDidCancel.
/// @param playlistsDir Directory containing .fplite files to scan
- (void)beginScanningWithPlaylistsDir:(NSString *)playlistsDir;

/// Begins scanning for a single playlist file only.
/// @param playlistsDir Directory containing .fplite files (for backup location)
/// @param playlistPath Full path to the specific playlist file to scan/repair
/// @param playlistName Display name of the playlist (from tree, not filename)
- (void)beginScanningWithPlaylistsDir:(NSString *)playlistsDir
                   singlePlaylistPath:(nullable NSString *)playlistPath
                   singlePlaylistName:(nullable NSString *)playlistName;

@end

NS_ASSUME_NONNULL_END
