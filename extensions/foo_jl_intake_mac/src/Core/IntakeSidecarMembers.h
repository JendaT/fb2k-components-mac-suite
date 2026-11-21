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
//   - lists only directories that hold two or more roots (virtual roots
//     share one listing), plus a lone root's directory when the previous
//     load gave that root a member list; it reads `.intake.<id>.json` only
//     where the listing shows it; it never stats a file and never reads
//     `.intake.json`;
//   - takes any other lone root as whole-directory without I/O (Assumed).
//     The CLI writes virtual roots two or more to a folder (resolver.ts
//     pass 3: several albums, or several singles). Trade-off: a lone
//     virtual root is taken as whole-directory, so its folder's other files
//     take its visual: an ISO root (`files: []`), or, on a first load only,
//     the survivor of a folder whose sibling sidecars an E_PARSE partial
//     dropped from `status`;
//   - spends no I/O at all on a directory whose roots all render nothing
//     (the caller's `needsMembers` predicate, normally statusHasVisual:
//     gc_done tombstones, placed unverified, unknown statuses). gc keeps a
//     tombstone sidecar per root forever (CR-004.13), so these pile up. A
//     virtual root that renders nothing is not read either (MemberKind::None;
//     see the known gap in IntakeSnapshot.h).
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
//  Stopping early (a stalled share blocks each call for the SMB timeout,
//  and the loader queue is also the read lane): before every filesystem
//  call the load checks `limits.cancel` (on_quit) and `limits.deadline`,
//  and a listing or read that fails with an errno saying the share is gone
//  (ETIMEDOUT, ENOTCONN, EIO, EHOSTDOWN, ...: isShareUnreachableError) ends
//  all further I/O. Every root not yet answered then keeps its previous
//  classification or is assumed, as for an unlistable directory (a root
//  whose named sidecar the listing showed keeps only a previous member
//  list, else matches nothing). At most the call in flight blocks; it
//  cannot be interrupted.
//
//  Incremental loads (B4, MemberReuse): a load triggered by FSEvents knows
//  which directories had a sidecar written, created or removed since the
//  last load. Every other directory that this load would list keeps the
//  previous classification without I/O (MemberSource::Reused), when every
//  root in it had one that came from a listing (Listed or Reused, so a
//  directory that failed to list or was only assumed is listed again), the
//  root's match key is the one it had in the previous load, and a root that
//  now renders something did not have its member list skipped (kind None).
//  Changed directories, new roots and everything else are listed as above.
//  The changed keys are compared ignoring ASCII case: a doubt costs one
//  listing, never a stale member list. The loader turns reuse off (a full
//  listing) for every load not started only by FSEvents batches (reload(),
//  reload(true), the post-command refresh), after a mount change, after a
//  rescan batch, and after a member pass that stopped early (IntakeLoader.h).
//
//  Thread-safety: loadMembers runs on one thread at a time per
//  SidecarFileAccess (the loader queue); it calls `fs` synchronously and in
//  order. The POSIX access is stateless and may be shared. `limits.cancel`
//  may be set from any thread. Results are plain values.
//

#pragma once

#include <atomic>
#include <chrono>
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
    // False when it cannot be listed, with `error` set to the errno (0 when
    // there is none).
    virtual bool listDirectory(const std::string &directory, std::vector<std::string> &names, int &error) = 0;
    // The whole content of `path`. False when it cannot be read, with
    // `error` as above.
    virtual bool readFile(const std::string &path, std::string &contents, int &error) = 0;
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
    Previous, // kept from `previous` after a failed listing, read or parse, or a stop
    Assumed,  // not verified: a lone root, or a skipped, unlistable or untried directory
    Reused,   // an incremental load kept a listed classification of an unchanged directory
};

struct RootMembers {
    MemberKind kind = MemberKind::WholeDirectory;
    MemberSource source = MemberSource::Assumed;
    std::vector<std::string> relativePaths;  // files[].path, for Members
    // Members only: the named sidecar says "singles": true (doc 01: a
    // singles-queue entry, a per-file virtual sidecar). Read with files[],
    // no extra I/O.
    bool singles = false;
};

// By root id.
using MemberTable = std::unordered_map<std::string, RootMembers>;

// Why a load stopped doing I/O before the end.
enum class MemberLoadStop {
    None,
    Cancelled,         // limits.cancel was set
    Deadline,          // limits.deadline passed
    ShareUnreachable,  // a call failed with isShareUnreachableError
};

struct MemberLoadLimits {
    // Checked before every filesystem call; on_quit sets it. Null: none.
    const std::atomic<bool> *cancel = nullptr;
    // No filesystem call starts at or after this moment.
    std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::time_point::max();
};

struct MemberLoadStats {
    size_t directories = 0;        // distinct root directories (by rootKey)
    size_t directoriesListed = 0;  // listDirectory calls
    size_t directoriesSkipped = 0; // no root in it needed members: no I/O
    size_t directoriesAssumed = 0; // a lone root, no previous member list: whole-directory, no I/O
    size_t directoriesNotTried = 0; // left unlisted after a stop
    size_t directoriesReused = 0;  // incremental: unchanged, previous classification kept, no I/O
    MemberLoadStop stop = MemberLoadStop::None;
    int stopError = 0;             // the errno, for ShareUnreachable
    size_t listFailures = 0;
    size_t sidecarReads = 0;       // readFile calls, retries included
    size_t sidecarRetries = 0;     // second reads after a failed read or parse
    size_t sidecarFailures = 0;    // still unusable after the retry
    size_t keptPrevious = 0;       // roots answered from `previous`
};

// An incremental load (see "Incremental loads" above). Default: off.
struct MemberReuse {
    bool enabled = false;
    // Match keys (IntakeRecord::rootKey form: normalized, aliased) of the
    // directories with sidecar events since the previous load.
    std::vector<std::string> changedKeys;
    // The previous load's rootKey by root id. Null: no root is reused.
    const std::unordered_map<std::string, std::string> *previousKeys = nullptr;
};

// ".intake.<id>.json".
std::string namedSidecarName(std::string_view id);

// The CLI's isSafeRelPath (util.ts).
bool isSafeRelativePath(std::string_view path);

// An errno that says the share itself is unreachable (a stalled or dropped
// network mount), not that one entry is missing: ETIMEDOUT, ENOTCONN, EIO,
// EHOSTDOWN, EHOSTUNREACH, ENETDOWN, ENETUNREACH, ECONNRESET, ECONNABORTED,
// ESTALE.
bool isShareUnreachableError(int error);

// The `files[].path` list of a sidecar document; false when the document is
// not acceptable (see above). Unknown fields are ignored. `singles`
// (optional): set to whether `singles` is the JSON boolean true.
bool parseSidecarMemberPaths(std::string_view json, std::vector<std::string> &paths, bool *singles = nullptr);

// Classifies every record (one entry per record id). `needsMembers` decides
// which roots are worth I/O; an empty function means every root. `previous`
// is the last snapshot's table, or null. `limits` bounds the I/O (see
// "Stopping early"). `reuse` makes it incremental (see above; it needs
// `previous`).
MemberTable loadMembers(const std::vector<IntakeRecord> &records,
                        SidecarFileAccess &fs,
                        const MemberTable *previous,
                        const std::function<bool(const IntakeRecord &)> &needsMembers,
                        MemberLoadStats *stats = nullptr,
                        const MemberLoadLimits &limits = MemberLoadLimits(),
                        const MemberReuse &reuse = MemberReuse());

} // namespace intake
