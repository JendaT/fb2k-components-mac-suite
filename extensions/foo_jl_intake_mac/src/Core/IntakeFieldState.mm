//
//  IntakeFieldState.mm
//  foo_jl_intake
//

#include "IntakeFieldState.h"

#include "IntakePath.h"

#include <atomic>

namespace intake {

namespace {

// The snapshot's default for a root without a member entry.
const RootMembers &membersOf(const IntakeSnapshot &snapshot, const std::string &id) {
    static const RootMembers wholeDirectory;
    auto found = snapshot.members().find(id);
    return found == snapshot.members().end() ? wholeDirectory : found->second;
}

bool sameMembers(const RootMembers &a, const RootMembers &b) {
    if (a.kind != b.kind) return false;
    return a.kind != MemberKind::Members || a.relativePaths == b.relativePaths;
}

// The directory key the snapshot files `record` under: its rootKey,
// normalized again (IntakeSnapshot::build). False when it has none.
bool directoryKey(const IntakeRecord &record, std::string &out) {
    out.clear();
    if (record.rootKey.empty()) return false;
    return normalizePath(record.rootKey, out) == PathStatus::Ok;
}

bool viewShowsValues(const IntakeView *view) {
    return view != nullptr && !view->isInert() && !view->rendersNothing();
}

// root + "/" + rest into `out` (the VolumeTable::nativePath form).
void joinRoot(std::string_view root, std::string_view rest, std::string &out) {
    out.assign(root);
    if (rest.empty()) return;
    if (out.back() != '/') out.push_back('/');
    out.append(rest.data(), rest.size());
}

bool sameAliases(const IntakeView &a, const IntakeView &b) {
    return a.aliasesPtr() == b.aliasesPtr() || a.aliases().sameAs(b.aliases());
}

uint64_t nextSerial() {
    static std::atomic<uint64_t> counter{0};
    return counter.fetch_add(1, std::memory_order_relaxed) + 1;
}

bool equalsIgnoringCase(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++) {
        char x = a[i];
        char y = b[i];
        if (x >= 'A' && x <= 'Z') x = static_cast<char>(x - 'A' + 'a');
        if (y >= 'A' && y <= 'Z') y = static_cast<char>(y - 'A' + 'a');
        if (x != y) return false;
    }
    return true;
}

} // anonymous namespace

// --- FieldState ---

FieldState::FieldState(std::shared_ptr<const IntakeView> view, std::shared_ptr<const VolumeTable> volumes)
    : view_(view ? std::move(view) : IntakeView::make(nullptr, nullptr)),
      volumes_(volumes ? std::move(volumes) : VolumeTable::empty()),
      shows_(viewShowsValues(view_.get())),
      serial_(nextSerial()) {}

const IntakeRecord *FieldState::recordFor(std::string_view itemPath, FieldScratch &scratch) const {
    if (!shows_ || itemPath.empty()) return nullptr;
    if (scratch.lastSerial == serial_ && scratch.lastPath == itemPath) return scratch.lastRecord;
    const IntakeRecord *record = nullptr;
    std::string_view uuid;
    std::string_view rest;
    if (splitMacVolumePath(itemPath, uuid, rest)) {
        if (volumes_->nativePath(uuid, rest, scratch.native)) record = view_->recordFor(scratch.native, scratch.view);
    } else {
        // "/..." and "file://..."; IntakePath refuses every other scheme.
        record = view_->recordFor(itemPath, scratch.view);
    }
    scratch.lastSerial = serial_;
    scratch.lastPath.assign(itemPath.data(), itemPath.size());
    scratch.lastRecord = record;
    return record;
}

bool FieldState::value(uint32_t index, std::string_view itemPath, FieldScratch &scratch,
                       std::string_view &out) const {
    if (index >= kIntakeFieldCount) return false;
    const IntakeRecord *record = recordFor(itemPath, scratch);
    if (record == nullptr) return false;
    const std::string &text = record->fields.value(index);
    if (text.empty()) return false;
    out = text;
    return true;
}

// --- FieldDirtySet ---

FieldDirtySet::Group &FieldDirtySet::groupFor(const std::shared_ptr<const MountAliases> &aliases) {
    const std::shared_ptr<const MountAliases> table = aliases ? aliases : MountAliases::none();
    for (Group &g : groups_) {
        if (g.aliases == table || g.aliases->sameAs(*table)) return g;
    }
    groups_.push_back(Group{table, PathMap<char>()});
    return groups_.back();
}

void FieldDirtySet::addKey(const std::shared_ptr<const MountAliases> &aliases, std::string_view key) {
    if (key.empty()) return;
    Group &g = groupFor(aliases);
    if (g.keys.find(key) != nullptr) return;
    g.keys.insert(key, 0, [](char, char) { return false; });
    keyCount_++;
}

void FieldDirtySet::addAllKeys(const IntakeView &view) {
    std::string key;
    for (const IntakeRecord &r : view.snapshot().records()) {
        if (directoryKey(r, key)) addKey(view.aliasesPtr(), key);
    }
}

void FieldDirtySet::noteVolumeRoot(std::string_view uuid, std::string_view root) {
    if (uuid.empty() || root.empty()) return;
    for (NotedVolume &v : volumes_) {
        if (!equalsIgnoringCase(v.uuid, uuid)) continue;
        for (const std::string &r : v.roots) {
            if (r == root) return;
        }
        v.roots.emplace_back(root);
        return;
    }
    volumes_.push_back(NotedVolume{std::string(uuid), {std::string(root)}});
}

bool FieldDirtySet::keyMatches(std::string_view nativePath, FieldScratch &scratch) const {
    std::string_view key;
    if (normalizePath(nativePath, scratch.view.normalized, key) != PathStatus::Ok) return false;
    // `key` views `nativePath` or scratch.view.normalized, never
    // scratch.view.aliased.
    for (const Group &g : groups_) {
        if (g.keys.findNearest(g.aliases->rewrite(key, scratch.view.aliased)) != nullptr) return true;
    }
    return false;
}

bool FieldDirtySet::matches(std::string_view itemPath, const VolumeTable &current, FieldScratch &scratch) const {
    if (keyCount_ == 0 || itemPath.empty()) return false;
    std::string_view uuid;
    std::string_view rest;
    if (!splitMacVolumePath(itemPath, uuid, rest)) return keyMatches(itemPath, scratch);

    const std::string *now = current.rootFor(uuid);
    if (now != nullptr) {
        joinRoot(*now, rest, scratch.native);
        if (keyMatches(scratch.native, scratch)) return true;
    }
    for (const NotedVolume &v : volumes_) {
        if (!equalsIgnoringCase(v.uuid, uuid)) continue;
        for (const std::string &root : v.roots) {
            if (now != nullptr && *now == root) continue;  // tried above
            joinRoot(root, rest, scratch.native);
            if (keyMatches(scratch.native, scratch)) return true;
        }
        break;
    }
    return false;
}

// --- the diffs ---

void addViewChanges(const IntakeView *before, const IntakeView *after, FieldDirtySet &out) {
    const bool beforeShows = viewShowsValues(before);
    const bool afterShows = viewShowsValues(after);
    if (!beforeShows && !afterShows) return;  // no row had a value, none has one
    if (!beforeShows) {
        out.addAllKeys(*after);
        return;
    }
    if (!afterShows) {
        out.addAllKeys(*before);
        return;
    }
    if (!sameAliases(*before, *after)) {
        // A row's own key may have moved (a second mount of a share now
        // aliased, a share gone): every root of both may gain or lose rows.
        out.addAllKeys(*before);
        out.addAllKeys(*after);
        return;
    }
    const IntakeSnapshot &a = before->snapshot();
    const IntakeSnapshot &b = after->snapshot();
    if (&a == &b) return;  // the same snapshot and aliases (a library-index republish)

    std::string oldKey;
    std::string newKey;
    for (const IntakeRecord &r : b.records()) {
        const bool hasNew = directoryKey(r, newKey);
        const IntakeRecord *o = a.recordForId(r.id);
        if (o == nullptr) {
            if (hasNew) out.addKey(after->aliasesPtr(), newKey);
            continue;
        }
        const bool hasOld = directoryKey(*o, oldKey);
        const bool same = hasOld == hasNew && oldKey == newKey && o->fields == r.fields &&
                          sameMembers(membersOf(a, o->id), membersOf(b, r.id));
        if (same) continue;
        if (hasOld) out.addKey(before->aliasesPtr(), oldKey);
        if (hasNew) out.addKey(after->aliasesPtr(), newKey);
    }
    for (const IntakeRecord &o : a.records()) {
        if (b.recordForId(o.id) != nullptr) continue;
        if (directoryKey(o, oldKey)) out.addKey(before->aliasesPtr(), oldKey);
    }
}

void addVolumeChanges(const VolumeTable &before, const VolumeTable &after, const IntakeView *view,
                      FieldDirtySet &out) {
    const std::vector<VolumeChange> changes = volumeChanges(before, after);
    if (changes.empty()) return;
    for (const VolumeChange &c : changes) {
        if (!c.before.empty()) out.noteVolumeRoot(c.uuid, c.before);
    }
    if (viewShowsValues(view)) out.addAllKeys(*view);
}

} // namespace intake
