//
//  LibraryLayout.h
//  foo_jl_tidal_mac
//
//  Pure path/naming logic for the personal "save to library" feature.
//  Builds paths matching the music.hq layout:
//
//    [Genre Collection]/Artist/Artist [YYYY] Title/01 - Track Title.flac
//    [Genre Collection]/[Releases]/Artist [YYYY] Title/...
//    [Genre Collection]/[Compilations]/VA [YYYY] Title/...
//
//  Foundation-only — no foobar2000 SDK — so it compiles standalone for
//  unit tests. All naming decisions live here; TidalLibrarySaver does I/O.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Slot names inside a genre collection.
extern NSString *const JLTidalLibraryReleasesSlot;      // "[Releases]"
extern NSString *const JLTidalLibraryCompilationsSlot;  // "[Compilations]"

@interface JLTidalLibraryLayout : NSObject

/// File-system-safe path component: replaces / : \ * ? " < > | and control
/// characters, collapses whitespace runs, trims leading/trailing whitespace
/// and trailing dots, caps length. nil/empty input yields "Unknown".
+ (NSString *)sanitizeComponent:(nullable NSString *)name;

/// "1997" from a release date (UTC), or nil when date is nil.
+ (nullable NSString *)yearStringFromDate:(nullable NSDate *)date;

/// YES for "Various Artists" / "VA" / "V.A." / "Various" (case-insensitive).
+ (BOOL)isVariousArtists:(nullable NSString *)albumArtist;

/// "Artist [YYYY] Title". Unknown year renders as "[0000]" so the canonical
/// shape (and sort order) is preserved. Label/cat# are omitted — the Tidal
/// API does not expose them.
+ (NSString *)releaseFolderNameForArtist:(nullable NSString *)artist
                                    year:(nullable NSString *)year
                                   title:(nullable NSString *)title;

/// "VA [YYYY] Title" for compilations.
+ (NSString *)compilationFolderNameForYear:(nullable NSString *)year
                                     title:(nullable NSString *)title;

/// Relative album path below a genre-collection folder, per the slot rules:
///   compilation           -> "[Compilations]/VA [YYYY] Title"
///   artistFolder non-nil  -> "<artistFolder>/Artist [YYYY] Title"
///   otherwise             -> "[Releases]/Artist [YYYY] Title"
/// artistFolder is the existing on-disk folder name (may differ in case
/// from the sanitized artist); promotion to a named artist folder is a
/// manual curation act, so this never invents one.
+ (NSString *)albumPathForArtist:(nullable NSString *)artist
                            year:(nullable NSString *)year
                      albumTitle:(nullable NSString *)title
                   isCompilation:(BOOL)isCompilation
                    artistFolder:(nullable NSString *)artistFolder;

/// "01 - Title.flac"; disc numbers >= 2 prefix the disc: "2-01 - Title.flac".
/// trackNumber <= 0 drops the numeric prefix entirely.
+ (NSString *)trackFileNameForNumber:(NSInteger)trackNumber
                          discNumber:(NSInteger)discNumber
                               title:(nullable NSString *)title
                           extension:(NSString *)extension;

/// Genre-collection folder names ("[Ambient]", ...) from a root directory
/// listing: bracket-wrapped names excluding the slot folders, sorted.
+ (NSArray<NSString *> *)collectionNamesFromListing:(NSArray<NSString *> *)names;

/// Case-insensitive match of the (sanitized) artist against a collection
/// listing. Returns the actual on-disk folder name, or nil. Slot folders
/// ("[...]") never match.
+ (nullable NSString *)artistFolderInListing:(NSArray<NSString *> *)names
                                      artist:(nullable NSString *)artist;

/// ffmpeg argv (excluding the executable) for a lossless stream-copy remux
/// with tags: -y -i <in> -map_metadata -1 -vn -c:a copy -metadata k=v ... <out>.
/// Metadata keys are emitted in sorted order; entries with empty values are
/// dropped.
+ (NSArray<NSString *> *)ffmpegArgumentsForInput:(NSString *)inputPath
                                          output:(NSString *)outputPath
                                        metadata:(NSDictionary<NSString *, NSString *> *)metadata;

@end

NS_ASSUME_NONNULL_END
