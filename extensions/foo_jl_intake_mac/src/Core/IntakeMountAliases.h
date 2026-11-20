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
//  Share links (B11): foobar2000 may keep share items as file://<link>/<rel>
//  under a local symlink that a mount agent points at the share's mount
//  point (docs/shadow-link.md). build(mounts, links) takes what
//  readShareLink (IntakeWatchSet) found at each configured link and adds an
//  entry that rewrites the link path to its target's key, the target
//  rewritten through the smbfs entries:
//
//    /Users/x/Music/NAS/music/income/a.wav  ->  /smbfs:music/income/a.wav
//                                               (link -> /Volumes/music-1)
//
//  So a link-form row and a /Volumes-form root meet on one key. A link that
//  points anywhere else maps to its target's own key: at the unmounted
//  placeholder /Volumes/<share> its rows match the unaliased /Volumes roots
//  (as /Volumes rows do while unmounted), at a mirror they match only roots
//  that lie there. Such a link is "off the share" (onShare false), and
//  underOffShareLink() tells the Delete census about its rows.
//
//  An entry is added only for a link read locally as a symlink (status
//  Link), with its target even when that does not exist. None is added for
//  any other status, for the root folder, for a path that equals a mount
//  point (ASCII case ignored) or lies under a network mount, so such a path
//  keeps today's behaviour; each case, and each link off the share, leaves
//  one line in notes() for the log. Link paths match byte-exact after
//  IntakePath normalisation (NFC, so an NFD link text meets an NFC row),
//  never ignoring case: they are local paths, not volume names. One
//  longest-prefix pass covers mount points and links (each entry knows
//  whether it folds case); the target key is final, never rewritten again.
//  The links are read on the loader queue, never here: build() itself has
//  no filesystem access.
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

struct ShareLinkRead;  // IntakeWatchSet.h

// The prefix of every alias key.
inline constexpr std::string_view kSmbAliasPrefix = "/smbfs:";

// The share part of an SMB mount source (see the top of this file):
// "<share>[/<path>]" with the share name lowercased and %XX decoded (an
// escape that decodes to '/' or NUL stays escaped). Empty when `source` is
// not "//<host>/<share>..." or a part of the path is empty, "." or "..".
std::string smbShareKey(std::string_view source);

class MountAliases {
public:
    // B11: one share link the table rewrites (see the top of this file).
    struct LinkEntry {
        std::string linkKey;   // IntakePath key of the link path (NFC, case kept)
        std::string rawLink;   // the link path, lexically clean: the spelling the items use
        std::string rawTarget; // where it leads (ShareLinkRead::rawTarget; need not exist)
        std::string targetKey; // rawTarget's key, rewritten through the smbfs entries
        bool onShare = false;  // rawTarget lies under a mounted smbfs mount (with a usable source)
    };

    static std::shared_ptr<const MountAliases> build(const std::vector<MountEntry> &mounts);
    // B11: with share links. `links` are readShareLink's results for the
    // configured links, read with the same mount table.
    static std::shared_ptr<const MountAliases> build(const std::vector<MountEntry> &mounts,
                                                     const std::vector<ShareLinkRead> &links);
    // A table with no mounts: rewrite() returns every key unchanged.
    static std::shared_ptr<const MountAliases> none();

    // `key` must be an IntakePath match key (normalized). Returns the alias
    // key, built in `buffer`, when `key` is an smbfs mount point or a share
    // link or lies under one (the longest one wins); otherwise `key` itself.
    // The result is normalized too. `key` must not view `buffer`.
    std::string_view rewrite(std::string_view key, std::string &buffer) const;
    // Same, as a copy.
    std::string rewritten(std::string_view key) const;

    // smbfs mounts with a usable source (links not counted).
    size_t aliasCount() const { return aliasCount_; }
    bool hasAliases() const { return aliasCount_ != 0; }
    // Same entries (mount point -> alias, link -> target with every
    // LinkEntry field) and the same notes, whatever the input order.
    bool sameAs(const MountAliases &other) const;
    // Where `a` and `b` can rewrite a key differently. For every mount point
    // or link whose entry differs between the two tables (added, removed,
    // another alias or target key, or onShare): that path as `a` rewrites it
    // and as `b` rewrites it. A key that `a` and `b` rewrite differently lies
    // under one such path, and its rewrite by `a` lies under that path's
    // rewrite by `a` (the same for `b`; "under" ignoring ASCII case, as
    // matching does). A link and a mount point never share an entry here,
    // even when spelled alike. Empty when no key rewrites differently (a
    // link whose raw target moved between two mounts of one share counts as
    // unchanged).
    static std::vector<std::string> changedBases(const MountAliases &a, const MountAliases &b);
    // "<mount point> -> <alias>; link <link> -> <target key> (exact case,
    // on a share); ..." for the log; "no smbfs mounts" when neither exists.
    std::string describe() const;

    // B11: the link entries, by link key (Swap reads the raw spellings).
    const std::vector<LinkEntry> &links() const { return links_; }
    // B11: `key` (an IntakePath key, before rewrite()) lies under a link
    // entry whose target is off the share (onShare false), and that link is
    // the entry rewrite() would use. The Delete census counts such rows as
    // unchecked.
    bool underOffShareLink(std::string_view key) const;
    // B11: one line per configured link that got no entry (and why), and
    // per link off the share; sorted, for the log.
    const std::vector<std::string> &notes() const { return notes_; }

    MountAliases(const MountAliases &) = delete;
    MountAliases &operator=(const MountAliases &) = delete;

private:
    struct Token {};

public:
    explicit MountAliases(Token) {}

private:
    struct Entry {
        std::string mountKey; // normalized mount point, or a link's linkKey
        std::string aliasKey; // normalized "/smbfs:<share>..." or a link's targetKey; empty: pass through
        bool foldCase = true; // mountKey compares ignoring ASCII case: true for mount points, false for links
        bool onShare = false; // links: LinkEntry::onShare
    };
    // Only what can change a result: smbfs mounts, the mounts nested inside
    // them, and share links. Longest path first, so the first match wins.
    std::vector<Entry> entries_;
    std::vector<LinkEntry> links_;
    std::vector<std::string> notes_;
    size_t aliasCount_ = 0;
};

} // namespace intake
