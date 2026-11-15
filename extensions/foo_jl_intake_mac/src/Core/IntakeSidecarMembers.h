//
//  IntakeSidecarMembers.h
//  foo_jl_intake
//
//  Which files belong to each root (doc 04 "Members"; PLAN.md B2).
//
//   - A root whose directory holds the named sidecar `.intake.<id>.json`
//     (a virtual root or a single; doc 01, CLI sidecar.ts) owns only the
//     files its `files[].path` list names: root_path + "/" + path.
//   - Any other root (`.intake.json`) is a whole-directory root and owns
//     every file under root_path. Its sidecar is never read.
//
//  The roots sit on an SMB share where every filesystem round trip costs
//  7 to 139 ms (S0, docs/intake-mac-paths.md), so the load:
//   - lists each distinct root directory once (virtual roots share one) and
//     reads `.intake.<id>.json` only where the listing shows it; it never
//     stats a file and never reads `.intake.json`;
//   - spends no I/O at all on a directory whose roots all render nothing
//     (the caller's `needsMembers` predicate, normally statusHasVisual:
//     gc_done tombstones, placed unverified, unknown statuses). gc keeps a
//     tombstone sidecar per root forever (CR-004.13), so these pile up.
//
//  Sidecar writes are not atomic (CLI sidecar.ts writeFileSync). A named
//  sidecar that cannot be read or parsed is read once more at once; if it
//  still fails, the root keeps its previous member list (`previous`, from
//  the last snapshot), else it matches nothing. FSEvents (B4) reports the
//  writer's later event and triggers another load. A sidecar is accepted
//  only when it is a JSON object whose `files` is an array of objects with
//  a safe relative `path`, the CLI's own readSidecar rule (util.ts
//  isSafeRelPath: non-empty, not absolute, no backslash or NUL, no empty,
//  "." or ".." segment); one bad entry fails the whole sidecar, as in the
//  CLI.
//
//  A directory that cannot be listed (unmounted share, removed folder)
//  keeps each root's previous classification. Without one, and for skipped
//  directories, membership is assumed: a directory holding exactly one root
//  is taken as a whole-directory root; several roots in one directory are
//  virtual for certain and match nothing until a listing succeeds.
//
//  Thread-safety: loadMembers runs on one thread at a time per
//  SidecarFileAccess (the loader queue); it calls `fs` synchronously and in
//  order. The POSIX access is stateless and may be shared. Results are
//  plain values.
//

#pragma once

#include <cstddef>
#include <functional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace intake {

struct IntakeRecord;

// The file access the load needs, injectable for tests. Implementations
// must not follow up with any other filesystem call (no stat).
class SidecarFileAccess {
public:
    virtual ~SidecarFileAccess() = default;
    // The entry names of `directory` (not "." or ".."), raw bytes as stored.
    // False when it cannot be listed.
    virtual bool listDirectory(const std::string &directory, std::vector<std::string> &names) = 0;
    // The whole content of `path`. False when it cannot be read.
    virtual bool readFile(const std::string &path, std::string &contents) = 0;
};

// opendir/readdir and open/read; files over 16 MB fail to read. Stateless,
// so the one instance may serve any thread.
SidecarFileAccess &posixSidecarFileAccess();

enum class MemberKind {
    WholeDirectory, // every file under root_path
    Members,        // only root_path + "/" + relativePaths
    None,           // nothing: a virtual root whose member list is unknown
                    // (unusable sidecar and no previous list, an unlisted
                    // shared directory) or not read (it renders nothing)
};

enum class MemberSource {
    Listed,   // this load listed the directory (and read the sidecar for Members)
    Previous, // kept from `previous` after a failed listing, read or parse
    Assumed,  // not verified: skipped or unlistable directory (see above)
};

struct RootMembers {
    MemberKind kind = MemberKind::WholeDirectory;
    MemberSource source = MemberSource::Assumed;
    std::vector<std::string> relativePaths;  // files[].path, for Members
};

// By root id.
using MemberTable = std::unordered_map<std::string, RootMembers>;

struct MemberLoadStats {
    size_t directories = 0;        // distinct root directories (by rootKey)
    size_t directoriesListed = 0;  // listDirectory calls
    size_t directoriesSkipped = 0; // no root in it needed members: no I/O
    size_t listFailures = 0;
    size_t sidecarReads = 0;       // readFile calls, retries included
    size_t sidecarRetries = 0;     // second reads after a failed read or parse
    size_t sidecarFailures = 0;    // still unusable after the retry
    size_t keptPrevious = 0;       // roots answered from `previous`
};

// ".intake.<id>.json".
std::string namedSidecarName(std::string_view id);

// The CLI's isSafeRelPath (util.ts).
bool isSafeRelativePath(std::string_view path);

// The `files[].path` list of a sidecar document; false when the document is
// not acceptable (see above). Unknown fields are ignored.
bool parseSidecarMemberPaths(std::string_view json, std::vector<std::string> &paths);

// Classifies every record (one entry per record id). `needsMembers` decides
// which roots are worth I/O; an empty function means every root. `previous`
// is the last snapshot's table, or null.
MemberTable loadMembers(const std::vector<IntakeRecord> &records,
                        SidecarFileAccess &fs,
                        const MemberTable *previous,
                        const std::function<bool(const IntakeRecord &)> &needsMembers,
                        MemberLoadStats *stats = nullptr);

} // namespace intake
