//
//  IntakeMountAliases.h
//  foo_jl_intake
//
//  Share-relative match keys for paths on SMB mounts (PLAN.md B3, S0
//  finding in docs/intake-mac-paths.md).
//
//  The same SMB share can be mounted twice, e.g. at /Volumes/<share> by its
//  LAN name and at /Volumes/<share>-1 by a VPN address, and macOS picks the
//  suffix by mount order. foobar2000 resolves its mac-volume:// items to one
//  mount point, and the CLI reports root paths under whichever mount point
//  its config names. So before matching, a path under an smbfs mount is
//  rewritten to a key that names the share instead of the mount point:
//
//    /Volumes/<share>-1/income/a.wav   ->  /smbfs:<share>/income/a.wav
//    /Volumes/<share>/income/a.wav     ->  /smbfs:<share>/income/a.wav
//
//  The leading '/' keeps the key acceptable to IntakePath (IntakePath.h).
//  The share part comes from the mount's source, "//[user@]host/<share>[/<path>]":
//  user and host are ignored (the two mounts differ exactly there), the
//  share name is lowercased (ASCII; SMB share names are case-insensitive),
//  percent escapes are decoded, and a source that mounts a folder inside the
//  share keeps that folder ("//h/<share>/sub" -> "/smbfs:<share>/sub").
//  Trade-off: two different servers exporting a share of the same name are
//  treated as one share.
//
//  Only smbfs mounts are rewritten. Other mounts pass through unchanged,
//  except that the longest mount point wins: a mount nested inside an smbfs
//  mount (another share, a local disk image) is matched first, so its paths
//  are rewritten for that mount or not at all.
//
//  Mount points match ignoring ASCII case: macOS compares volume names
//  case-insensitively and /Volumes on the default APFS volume is
//  case-insensitive, so a CLI root under /Volumes/share works on disk while
//  the share is mounted at /Volumes/Share. Only the mount-point prefix is
//  folded; the rest of a path keeps its case, as everywhere else in
//  matching. Trade-off: on a case-sensitive boot volume a folder that
//  differs from a mount point only in case is treated as that mount.
//
//  No filesystem access: the input is a mount list (Integration reads it
//  with getmntinfo(MNT_NOWAIT), which never asks the server). A share that is
//  unmounted is simply absent from the list, so its paths are not rewritten
//  and match nothing aliased: no tint, never a hang. Mount points and alias
//  keys are IntakePath-normalized when the table is built (NFC, lexical), so
//  an NFD mount point matches an NFC query.
//
//  Thread-safety: immutable once built; any number of threads may call the
//  const members concurrently.
//

#pragma once

#include <cstddef>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace intake {

// One row of the mount table (struct statfs).
struct MountEntry {
    std::string mountPoint; // f_mntonname, e.g. "/Volumes/<share>-1"
    std::string source;     // f_mntfromname, e.g. "//user@host/<share>"
    std::string fsType;     // f_fstypename, e.g. "smbfs"
    // f_flags has MNT_LOCAL. Not used for aliases; IntakeWatchSet reads it
    // (with the type) to decide whether lstat/readlink may touch a path.
    bool local = true;
};

// The prefix of every alias key.
inline constexpr std::string_view kSmbAliasPrefix = "/smbfs:";

// The share part of an SMB mount source (see the top of this file):
// "<share>[/<path>]" with the share name lowercased and %XX decoded (an
// escape that decodes to '/' or NUL stays escaped). Empty when `source` is
// not "//<host>/<share>..." or a part of the path is empty, "." or "..".
std::string smbShareKey(std::string_view source);

class MountAliases {
public:
    static std::shared_ptr<const MountAliases> build(const std::vector<MountEntry> &mounts);
    // A table with no mounts: rewrite() returns every key unchanged.
    static std::shared_ptr<const MountAliases> none();

    // `key` must be an IntakePath match key (normalized). Returns the alias
    // key, built in `buffer`, when `key` is an smbfs mount point or lies
    // under one; otherwise `key` itself. The result is normalized too.
    // `key` must not view `buffer`.
    std::string_view rewrite(std::string_view key, std::string &buffer) const;
    // Same, as a copy.
    std::string rewritten(std::string_view key) const;

    // smbfs mounts with a usable source.
    size_t aliasCount() const { return aliasCount_; }
    bool hasAliases() const { return aliasCount_ != 0; }
    // Same entries (mount point -> alias), whatever the input order.
    bool sameAs(const MountAliases &other) const;
    // Where `a` and `b` can rewrite a key differently. For every mount point
    // whose entry differs between the two tables (added, removed, or another
    // alias): that mount point as `a` rewrites it and as `b` rewrites it. A
    // key that `a` and `b` rewrite differently lies under one such mount
    // point, and its rewrite by `a` lies under that mount point's rewrite by
    // `a` (the same for `b`; "under" ignoring ASCII case, as matching does).
    // Empty when the tables are the same.
    static std::vector<std::string> changedBases(const MountAliases &a, const MountAliases &b);
    // "<mount point> -> <alias>; ..." for the log; "no smbfs mounts" when empty.
    std::string describe() const;

    MountAliases(const MountAliases &) = delete;
    MountAliases &operator=(const MountAliases &) = delete;

private:
    struct Token {};

public:
    explicit MountAliases(Token) {}

private:
    struct Entry {
        std::string mountKey; // normalized mount point
        std::string aliasKey; // normalized "/smbfs:<share>..."; empty: pass through
    };
    // Only what can change a result: smbfs mounts and the mounts nested
    // inside them. Longest mount point first, so the first match wins.
    std::vector<Entry> entries_;
    size_t aliasCount_ = 0;
};

} // namespace intake
