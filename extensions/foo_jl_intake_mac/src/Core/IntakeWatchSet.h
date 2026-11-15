//
//  IntakeWatchSet.h
//  foo_jl_intake
//
//  What the FSEvents stream watches, and how its event paths map back to
//  match keys (PLAN.md B4, 3.5; doc 04 v1.2 "Refresh and invalidation").
//
//  Candidates, in this order (watchCandidates):
//   - the `foo_jl_intake.watch_folders` setting (parseWatchFolders: one
//     absolute path per line);
//   - the income folders from `intake income --json` (CLI 0.3.0 and later);
//   - the parent directory of every root_path from the last `status` load.
//  "/" is never watched (a firehose for a stream with file events).
//
//  Each candidate is cleaned lexically (lexicalAbsolutePath: no NFC, no
//  filesystem access) and then, only when it lies on a local filesystem,
//  resolved with realpath (e.g. /tmp -> /private/tmp, /var -> /private/var),
//  because FSEvents reports resolved paths. Whether a path is local is read
//  from the mount table the loader already has (getmntinfo MNT_NOWAIT):
//  the longest mount point holding it (ignoring ASCII case, as
//  IntakeMountAliases does) must be a local filesystem
//  (MountEntry::local and not a network type). A path under a network
//  mount (smbfs, nfs, afpfs, webdav, autofs, ...), or any path when the
//  table is empty, is never resolved: realpath is a round trip per
//  component on the share (S0: 7-139 ms each, and a stalled share blocks for
//  the SMB timeout). A local path that does not exist yet (an income folder
//  not created yet) resolves its deepest existing ancestor and keeps the
//  rest as written.
//
//  The stream gets the resolved paths reduced to top-level ancestors
//  (FSEvents is recursive): a path equal to or under another one is dropped
//  (compared as IntakePath keys, case-sensitively, so a doubt keeps both).
//  streamPaths() is sorted, so two sets compare with ==.
//
//  Mapping an event back (mapEventDirectory): the directory of a sidecar
//  event, as FSEvents spelled it, is matched against every candidate's
//  resolved key (prefix at a '/' boundary, ignoring ASCII case), rewritten
//  onto that candidate's original spelling, and then put through the same
//  pipeline as root keys: IntakePath normalisation, then the mount alias
//  rewrite. So an event under /private/var/... for a root the CLI reported
//  under /var/..., or under /Volumes/<share>-1/... for a root reported under
//  /Volumes/<share>/..., gives the root's own match key. A directory under
//  no candidate maps to nothing and returns false: the caller then treats
//  everything as changed.
//
//  Thread-safety: a built WatchSet is immutable; build() runs the resolver
//  on the calling thread (the loader queue).
//

#pragma once

#include <functional>
#include <string>
#include <string_view>
#include <vector>

#include "IntakeMountAliases.h"

namespace intake {

struct WatchFolderList {
    std::vector<std::string> folders;  // absolute, trimmed, in order, each once
    std::vector<std::string> ignored;  // non-empty lines that are not absolute paths
};

// The watch_folders setting: lines split on '\n' or '\r', each trimmed of
// spaces and tabs; empty lines skipped; a line that does not start with '/'
// is ignored (reported in `ignored`).
WatchFolderList parseWatchFolders(std::string_view text);

// `path` with "//" collapsed, "." segments dropped, ".." popping a segment
// (staying at "/"), and a trailing '/' removed (except for "/"). Bytes are
// otherwise kept (no NFC). Empty when `path` is empty or not absolute.
std::string lexicalAbsolutePath(std::string_view path);

// The parent of a lexically clean absolute path: "/a" for "/a/b", "/" for
// "/a", "" for "/" or a relative path.
std::string parentDirectory(std::string_view path);

// A mount whose filesystem is not local: MountEntry::local is false, or
// the type is smbfs, nfs, afpfs, webdav, cifs, ftp, autofs or a FUSE type.
bool isNetworkMount(const MountEntry &mount);

// The longest mount point holding `path` (ignoring ASCII case), or null.
const MountEntry *mountHolding(std::string_view path, const std::vector<MountEntry> &mounts);

// True only when the mount holding `path` is known and local: then realpath
// cannot reach a server.
bool mayResolvePath(std::string_view path, const std::vector<MountEntry> &mounts);

// realpath(3) into `resolved`; false when it fails.
using PathResolver = std::function<bool(const std::string &path, std::string &resolved)>;
bool realPathResolver(const std::string &path, std::string &resolved);

// The candidates in the order described above, lexically cleaned, each once
// (by exact bytes), "/" and anything not absolute left out. `rootPaths` are
// root_path values; their parents are taken here.
std::vector<std::string> watchCandidates(const std::vector<std::string> &configured,
                                         const std::vector<std::string> &income,
                                         const std::vector<std::string> &rootPaths);

class WatchSet {
public:
    struct Entry {
        std::string original;    // the candidate as cleaned
        std::string fsPath;      // what FSEvents gets (resolved when local)
        std::string originalKey; // IntakePath key of `original`
        std::string fsKey;       // IntakePath key of `fsPath`
        bool resolved = false;   // realpath ran on it (a local path)
    };

    // `resolve` runs only for candidates mayResolvePath allows; an empty
    // function resolves nothing.
    static WatchSet build(const std::vector<std::string> &candidates, const std::vector<MountEntry> &mounts,
                          const PathResolver &resolve);

    // Top-level resolved paths for the stream, sorted.
    const std::vector<std::string> &streamPaths() const { return streamPaths_; }
    // Every candidate (before the reduction), for the mapping.
    const std::vector<Entry> &entries() const { return entries_; }
    bool empty() const { return streamPaths_.empty(); }

    // See the top of this file. Appends each distinct match key to `keys`;
    // false when `directory` lies under no candidate.
    bool mapEventDirectory(std::string_view directory, const MountAliases &aliases,
                           std::vector<std::string> &keys) const;

private:
    std::vector<Entry> entries_;
    std::vector<std::string> streamPaths_;
};

} // namespace intake
