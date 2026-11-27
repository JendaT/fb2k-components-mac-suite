//
//  SVArtistLibrary.mm
//  foo_jl_shellvanced_mac
//

#import "SVArtistLibrary.h"
#include <atomic>
#include <map>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "ArtistIndexCore.h"

NSNotificationName const SVArtistLibraryDidChangeNotification = @"SVArtistLibraryDidChangeNotification";

namespace {

// Immutable result of one rebuild; published on the main thread.
struct Snapshot {
    std::vector<artistindex::ArtistEntry> entries;
    std::unordered_map<std::string, size_t> byKey;
    metadb_handle_list handles;
    std::vector<std::string> handleAlbums;  // parallel to handles
    std::vector<std::string> handleDates;   // parallel to handles
    std::map<std::string, artistindex::CoArtistInfo> coArtists;
};

NSString *NS(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

}  // namespace

@class SVArtistLibrary;
static void SVArtistLibraryScheduleRebuild(SVArtistLibrary *lib);

// Receives library change notifications (main thread) and forwards to the singleton.
namespace {
class SVLibraryListener : public library_callback_dynamic_impl_base {
public:
    explicit SVLibraryListener(SVArtistLibrary *owner) : m_owner(owner) {}
    void on_items_added(metadb_handle_list_cref) override { SVArtistLibraryScheduleRebuild(m_owner); }
    void on_items_removed(metadb_handle_list_cref) override { SVArtistLibraryScheduleRebuild(m_owner); }
    void on_items_modified(metadb_handle_list_cref) override {
        if (library_callback::is_modified_from_hook()) return;  // display hooks cannot change artist names
        SVArtistLibraryScheduleRebuild(m_owner);
    }
private:
    __unsafe_unretained SVArtistLibrary *m_owner;  // singleton, never deallocated
};
}  // namespace

@implementation SVArtistLibrary {
    std::shared_ptr<const Snapshot> _snapshot;
    std::unique_ptr<SVLibraryListener> _listener;
    NSArray<NSString *> *_names;
    NSUInteger _generation;  // debounce token
    std::atomic<NSUInteger> _buildSerial;  // discards stale builds; read from the build queue
    dispatch_queue_t _buildQueue;
}

+ (instancetype)shared {
    static SVArtistLibrary *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[SVArtistLibrary alloc] init];
        [instance start];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _names = @[];
        _snapshot = std::make_shared<const Snapshot>();
        _buildQueue = dispatch_queue_create("foo_jl_shellvanced.artistindex", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)start {
    _listener = std::make_unique<SVLibraryListener>(self);
    [self rebuildNow];
}

- (NSArray<NSString *> *)artistNames { return _names; }

#pragma mark - Rebuild

- (void)scheduleRebuild {
    NSUInteger gen = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == self->_generation) [self rebuildNow];
    });
}

- (void)rebuildNow {
    metadb_handle_list all;
    try {
        library_manager::get()->get_all_items(all);
    } catch (...) {
        return;
    }
    const NSUInteger serial = ++_buildSerial;
    std::atomic<NSUInteger> *latest = &_buildSerial;  // singleton lives forever

    dispatch_async(_buildQueue, ^{
        if (latest->load() != serial) return;  // superseded while queued: skip the work
        auto snap = std::make_shared<Snapshot>();
        snap->handles = all;
        try {
            // \x01 separates fields (never occurs in tags).
            auto script = titleformat_compiler::get()->compile_force(
                "%album artist%$char(1)%artist%$char(1)%album%$char(1)%date%");
            std::vector<artistindex::TrackRow> rows;
            const size_t n = all.get_count();
            rows.reserve(n);
            snap->handleAlbums.reserve(n);
            snap->handleDates.reserve(n);
            pfc::string8 out;
            for (size_t i = 0; i < n; i++) {
                out.reset();
                all[i]->format_title(nullptr, out, script, nullptr);
                std::string parts[4];
                size_t field = 0;
                for (const char *p = out.c_str(); *p; p++) {
                    if (*p == '\x01') { if (++field > 3) break; }
                    else parts[field].push_back(*p);
                }
                rows.push_back({parts[0], parts[1], parts[2], parts[3], i});
                snap->handleAlbums.push_back(parts[2]);
                snap->handleDates.push_back(parts[3]);
            }
            snap->entries = artistindex::buildIndex(rows);
            snap->coArtists = artistindex::buildCoArtists(rows);
            for (size_t i = 0; i < snap->entries.size(); i++) snap->byKey[snap->entries[i].key] = i;
        } catch (...) {
            return;
        }

        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithCapacity:snap->entries.size()];
        for (const auto &e : snap->entries) [names addObject:NS(e.name)];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (serial != self->_buildSerial.load()) return;  // a newer build superseded this one
            self->_snapshot = snap;
            self->_names = names;
            [[NSNotificationCenter defaultCenter] postNotificationName:SVArtistLibraryDidChangeNotification
                                                                object:self];
        });
    });
}

#pragma mark - Queries

- (const artistindex::ArtistEntry *)entryForName:(NSString *)name {
    if (name.length == 0) return nullptr;
    auto key = artistnames::artistKey(std::string(name.UTF8String));
    auto it = _snapshot->byKey.find(key);
    return it == _snapshot->byKey.end() ? nullptr : &_snapshot->entries[it->second];
}

- (metadb_handle_list)handlesForArtist:(NSString *)name {
    metadb_handle_list out;
    const auto *e = [self entryForName:name];
    if (!e) return out;
    for (size_t idx : e->trackIndices) out.add_item(_snapshot->handles[idx]);
    try {
        static titleformat_object::ptr sorter;
        if (sorter.is_empty())
            titleformat_compiler::get()->compile_force(sorter, "%date%|%album%|%discnumber%|%tracknumber%");
        metadb_handle_list_helper::sort_by_format(out, sorter, nullptr);
    } catch (...) {}
    return out;
}

- (NSUInteger)albumCountForArtist:(NSString *)name {
    const auto *e = [self entryForName:name];
    return e ? e->ownedAlbums.size() + e->appearsOnAlbums.size() : 0;
}

- (NSUInteger)trackCountForArtist:(NSString *)name {
    const auto *e = [self entryForName:name];
    return e ? e->trackIndices.size() : 0;
}

- (NSArray<NSString *> *)albumTitlesForArtist:(NSString *)name {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    const auto *e = [self entryForName:name];
    if (!e) return titles;
    for (const auto &a : e->ownedAlbums) [titles addObject:NS(a)];
    for (const auto &a : e->appearsOnAlbums) [titles addObject:NS(a)];
    return titles;
}

- (NSArray<NSString *> *)userTitlesForArtist:(NSString *)name {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    const auto *e = [self entryForName:name];
    if (!e) return titles;
    for (const auto &a : e->ownedAlbums) [titles addObject:NS(a)];
    for (const auto &a : e->appearsOnAlbums) [titles addObject:NS(a)];
    try {
        auto script = titleformat_compiler::get()->compile_force("%title%");
        pfc::string8 out;
        for (size_t idx : e->trackIndices) {
            out.reset();
            _snapshot->handles[idx]->format_title(nullptr, out, script, nullptr);
            if (out.length()) [titles addObject:[NSString stringWithUTF8String:out.c_str()] ?: @""];
        }
    } catch (...) {}
    return titles;
}

- (NSArray<NSString *> *)coArtistKeysForArtist:(NSString *)name {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    const auto *e = [self entryForName:name];
    if (!e) return out;
    auto it = _snapshot->coArtists.find(e->key);
    if (it == _snapshot->coArtists.end()) return out;
    for (const auto &k : it->second.keys) [out addObject:NS(k)];
    return out;
}

- (NSArray<NSString *> *)collabStringsForArtist:(NSString *)name {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    const auto *e = [self entryForName:name];
    if (!e) return out;
    auto it = _snapshot->coArtists.find(e->key);
    if (it == _snapshot->coArtists.end()) return out;
    for (const auto &s : it->second.collabStrings) [out addObject:NS(s)];
    return out;
}

- (metadb_handle_list)coverProbeHandlesForArtist:(NSString *)name {
    metadb_handle_list out;
    const auto *e = [self entryForName:name];
    if (!e) return out;
    std::vector<artistindex::CoverProbeRow> rows;
    rows.reserve(e->trackIndices.size());
    for (size_t idx : e->trackIndices)
        rows.push_back({_snapshot->handleAlbums[idx], _snapshot->handleDates[idx], idx});
    for (size_t idx : artistindex::coverProbeOrder(rows, 6)) out.add_item(_snapshot->handles[idx]);
    return out;
}

- (metadb_handle_ptr)representativeHandleForArtist:(NSString *)name {
    const auto *e = [self entryForName:name];
    if (!e || e->newestAlbum.empty()) return metadb_handle_ptr();
    for (size_t idx : e->trackIndices)
        if (_snapshot->handleAlbums[idx] == e->newestAlbum) return _snapshot->handles[idx];
    return metadb_handle_ptr();
}

@end

static void SVArtistLibraryScheduleRebuild(SVArtistLibrary *lib) { [lib scheduleRebuild]; }
