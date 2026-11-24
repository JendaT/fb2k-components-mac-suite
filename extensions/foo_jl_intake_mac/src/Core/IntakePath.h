//
//  IntakePath.h
//  foo_jl_intake
//
//  Path normalisation shared by both sides of the root match: playlist row
//  paths (foobar2000) and root paths from `intake status --json` (the CLI).
//  Both must reach the same byte string for the same folder, or a release is
//  silently undecorated (PLAN.md risk 4: NFC/NFD and `/private` mismatches).
//
//  Steps, in order:
//   1. A leading "file://" (any case) is stripped by hand, never through
//      NSURL: foobar2000 writes the native path unencoded after it, and
//      NSURL rejects paths with spaces (album_art TrackMetadata.mm).
//   2. Lexical normalisation: "//" collapses, "." segments drop, ".." pops a
//      segment (and stays at "/" at the top), and a trailing "/" goes, except
//      for "/" itself. No filesystem access at all: no realpath, symlinks are
//      not followed, "/private" is kept as written, "~" is not expanded.
//      This runs on the decorate path and must never stat() a NAS path.
//   3. Unicode NFC, skipped for pure-ASCII paths.
//
//  Only native POSIX paths and file:// are handled. Other schemes
//  (mac-volume://, http://, ...) are reported as UnhandledScheme: Integration
//  converts them to native paths first (IntakeNativePath, PLAN.md B3), which
//  keeps this module free of the foobar2000 SDK.
//
//  Matching after normalisation stays byte-exact and case-sensitive.
//
//  The result is a match key, never a path for filesystem access. NFC
//  rewrites the bytes of names stored decomposed (SMB shares, HFS+), and an
//  NFC spelling of such a name does not stat. Keep the original spelling for
//  any I/O (IntakeRoot.rootPath).
//
//  Keys from another namespace must start with '/' to pass; anything else is
//  Relative. A mount-alias key (PLAN.md B3, IntakeMountAliases) is therefore
//  spelled "/smbfs:<share>/<relative>", not "smbfs:<share>/<relative>".
//  Normalisation is idempotent, so a caller may normalise, rewrite, and let
//  the index normalise again: the second pass returns the same bytes.
//
//  Cost: the common case (already-normal ASCII, with or without file://)
//  is one scan of the input with no allocation and no Foundation call. Other
//  ASCII input costs one copy into the caller's buffer. Only non-ASCII input
//  goes through CoreFoundation for NFC.
//
//  Thread-safety: all functions are reentrant; there is no shared state.
//

#pragma once

#include <string>
#include <string_view>

namespace intake {

enum class PathStatus {
    Ok,              // The normalised absolute path is in `out`.
    Empty,           // Empty input, or "file://" with nothing after it.
    Relative,        // No scheme and no leading '/', e.g. "a/b", "~/x", "file:/x".
    UnhandledScheme, // A scheme other than file://, or file://host/... .
};

// Normalises `input` (UTF-8). On Ok, `out` views either `input` itself (when
// it was already normal ASCII, so nothing was copied) or `buffer`, which the
// caller owns and may reuse across calls to keep its capacity. `out` is valid
// until `input` or `buffer` changes. On any other status `out` is empty.
// `input` may view `buffer`'s own storage (normalising in place); the call
// then copies the input first, which costs one allocation.
//
// Invalid UTF-8 cannot be normalised to NFC; such input is still lexically
// normalised and returned as Ok with its bytes otherwise unchanged, so an
// exact byte match remains possible.
PathStatus normalizePath(std::string_view input, std::string &buffer, std::string_view &out);

// Convenience overload that always copies the result into `out` (cleared on
// any status other than Ok).
PathStatus normalizePath(std::string_view input, std::string &out);

// The ASCII folder of a path that normalizePath() would send through NFC,
// so a lookup can rule the path out before paying for CoreFoundation
// (IntakeView::mayHaveRecord). For `input` (a native path or file://) with
// a non-ASCII byte: true, with `head` viewing the native part of `input` up
// to the last '/' before the first non-ASCII byte. The match key of `input`
// then lies strictly under the match key of `head`, which is ASCII and so
// needs no NFC: NFC never changes ASCII text that ends in a '/' (a '/'
// composes with nothing and is never reordered), and lexical normalisation
// can only reach into `head` through a ".." segment after it. False, with
// `head` empty, for an ASCII path (its full normalisation is cheap anyway),
// another scheme or a relative path, a non-ASCII byte in the first segment
// (no folder before it), or a ".." segment after the head.
bool asciiFolderOf(std::string_view input, std::string_view &head);

// "Ok", "Empty", "Relative" or "UnhandledScheme", for log lines.
const char *_Nonnull pathStatusName(PathStatus status);

} // namespace intake

#ifdef __OBJC__
#import <Foundation/Foundation.h>

namespace intake {

// Copies the UTF-8 bytes of `string` into `out` without autoreleasing
// anything. A nil string yields an empty `out`.
void copyUTF8(NSString *_Nullable string, std::string &out);

} // namespace intake

NS_ASSUME_NONNULL_BEGIN

/// Foundation convenience for callers holding NSStrings (e.g. root paths from
/// parsed status JSON): the normalised match key, or nil unless the status is
/// Ok. A lookup key only: never use it for filesystem access (see the top of
/// this file). `status` (optional) receives the status either way.
NSString *_Nullable IntakeNormalizedPath(NSString *_Nullable path,
                                         intake::PathStatus *_Nullable status);

NS_ASSUME_NONNULL_END
#endif
