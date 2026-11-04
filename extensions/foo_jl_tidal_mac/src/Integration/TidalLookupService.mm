//
//  TidalLookupService.mm
//  foo_jl_tidal_mac
//
//  jl_tidal_lookup implementation. Lookups queue on the main thread and run
//  one track at a time, so a consumer asking for a whole playlist never takes
//  more than one of the API's in-flight slots from browsing and playback.
//  Answers persist in the profile as tidal_lookup_cache.plist.
//

#include "../fb2k_sdk.h"
#import "../../../../shared/jl_tidal_api.h"
#import "TidalLookupService.h"
#import "../API/TidalAPI.h"
#import "../Services/TidalAuthService.h"
#import "../Core/TidalErrors.h"
#import "../Core/TidalLog.h"
#import "../Core/TrackMatcher.h"
#import "../Core/URLUtils.h"

#include <deque>
#include <memory>
#include <mutex>

namespace {

// "Not found" is re-asked after this long: the catalogue grows.
const NSTimeInterval kNotFoundLifetime = 30 * 24 * 60 * 60;
// Coalesces a burst of answers into one write.
const int64_t kSaveDelayNs = 10 * NSEC_PER_SEC;
const NSInteger kSearchLimit = 10;

NSString *str(const char *s) {
    return s ? [NSString stringWithUTF8String:s] : nil;
}

// What an item can be matched on, read from its path and stored tags.
struct Descriptor {
    NSString *trackID = nil;    // tidal:// entries
    NSString *isrc = nil;       // normalised, nil when absent or malformed
    NSString *artist = nil;     // first ARTIST value, for the search query
    NSArray<NSString *> *artists = @[];  // folded names, for matching
    NSString *title = nil;
    double length = 0;
    bool haveInfo = false;
    NSString *cacheKey = nil;   // nil: nothing to match on
};

Descriptor describe(const metadb_handle_ptr &item) {
    Descriptor d;
    const char *path = item->get_path();
    if (tidal::isPlayableTidalTrackURL(path)) {
        auto url = tidal::parseURL(path);
        if (url && url->isValid()) d.trackID = str(url->id.c_str());
    }
    metadb_info_container::ptr info;
    if (item->get_info_ref(info)) {
        d.haveInfo = true;
        const file_info &fi = info->info();
        d.isrc = [JLTidalTrackMatcher normalizedISRC:str(fi.meta_get("ISRC", 0))];
        NSMutableArray<NSString *> *values = [NSMutableArray array];
        for (t_size i = 0, n = fi.meta_get_count_by_name("ARTIST"); i < n; i++) {
            NSString *v = str(fi.meta_get("ARTIST", i));
            if (v.length) [values addObject:v];
        }
        d.artist = values.firstObject;
        d.artists = [JLTidalTrackMatcher artistNamesFromTagValues:values];
        d.title = str(fi.meta_get("TITLE", 0));
        d.length = fi.get_length();
    }
    d.cacheKey = [JLTidalTrackMatcher cacheKeyForTrackID:d.trackID isrc:d.isrc
                                                 artists:d.artists title:d.title length:d.length];
    return d;
}

jl_tidal_track_facts factsForTrack(JLTidalTrack *track, jl_tidal_match match) {
    jl_tidal_track_facts f;
    f.status = jl_tidal_status_found;
    f.match = match;
    f.bpm = (float)track.bpm;
    f.key = [JLTidalTrackMatcher keyNameForKey:track.key scale:track.keyScale].UTF8String;
    f.tidal_track_id = track.trackID.UTF8String;
    return f;
}

NSDictionary *recordFromFacts(const jl_tidal_track_facts &f) {
    return @{
        @"s": @((unsigned)f.status), @"m": @((unsigned)f.match), @"b": @(f.bpm),
        @"k": str(f.key.c_str()) ?: @"", @"id": str(f.tidal_track_id.c_str()) ?: @"",
        @"t": @([NSDate date].timeIntervalSince1970),
    };
}

// False for a malformed record and for an expired "not found".
bool factsFromRecord(NSDictionary *r, jl_tidal_track_facts &out) {
    if (![r isKindOfClass:[NSDictionary class]]) return false;
    uint32_t status = [r[@"s"] unsignedIntValue];
    if (status != jl_tidal_status_found && status != jl_tidal_status_not_found) return false;
    if (status == jl_tidal_status_not_found &&
        [NSDate date].timeIntervalSince1970 - [r[@"t"] doubleValue] > kNotFoundLifetime) {
        return false;
    }
    out = jl_tidal_track_facts();
    out.status = (jl_tidal_lookup_status)status;
    out.match = (jl_tidal_match)[r[@"m"] unsignedIntValue];
    out.bpm = [r[@"b"] floatValue];
    NSString *key = r[@"k"], *trackID = r[@"id"];
    if ([key isKindOfClass:[NSString class]]) out.key = key.UTF8String;
    if ([trackID isKindOfClass:[NSString class]]) out.tidal_track_id = trackID.UTF8String;
    return true;
}

typedef void (^ResolveDone)(jl_tidal_track_facts facts);

jl_tidal_track_facts factsWithStatus(jl_tidal_lookup_status status) {
    jl_tidal_track_facts f;
    f.status = status;
    return f;
}

void resolveBySearch(const Descriptor &d, ResolveDone done) {
    if (d.artist.length == 0 || d.title.length == 0 || d.length <= 0) {
        done(factsWithStatus(jl_tidal_status_not_found));
        return;
    }
    NSArray<NSString *> *artists = d.artists;
    NSString *title = d.title;
    double length = d.length;
    NSString *query = [JLTidalTrackMatcher searchQueryForArtist:d.artist title:d.title];
    [[JLTidalAPI shared] searchTracksWithQuery:query limit:kSearchLimit offset:0
                                    completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        if (error) {
            done(factsWithStatus(jl_tidal_status_unavailable));
            return;
        }
        JLTidalTrack *match = [JLTidalTrackMatcher bestMatchIn:tracks ?: @[] artists:artists
                                                         title:title length:length];
        if (!match) {
            done(factsWithStatus(jl_tidal_status_not_found));
            return;
        }
        if (match.bpm > 0 || match.key.length > 0) {
            done(factsForTrack(match, jl_tidal_match_search));
            return;
        }
        // A search item may leave fields out; the track itself is the
        // authority before "no tempo" is cached for good.
        [[JLTidalAPI shared] getTrackMetadataForTrackID:match.trackID
                                             completion:^(NSDictionary *json, NSError *metaError) {
            JLTidalTrack *full = (!metaError && json) ? [[JLTidalTrack alloc] initWithDictionary:json] : nil;
            done(full ? factsForTrack(full, jl_tidal_match_search)
                      : factsWithStatus(jl_tidal_status_unavailable));
        }];
    }];
}

void resolve(const Descriptor &d, ResolveDone done) {
    if (d.trackID.length) {
        [[JLTidalAPI shared] getTrackMetadataForTrackID:d.trackID
                                             completion:^(NSDictionary *json, NSError *error) {
            JLTidalTrack *track = (!error && json) ? [[JLTidalTrack alloc] initWithDictionary:json] : nil;
            if (track) {
                done(factsForTrack(track, jl_tidal_match_track_id));
            } else if ([error.domain isEqualToString:JLTidalErrorDomain] &&
                       error.code == JLTidalErrorTrackNotFound) {
                done(factsWithStatus(jl_tidal_status_not_found));
            } else {
                done(factsWithStatus(jl_tidal_status_unavailable));
            }
        }];
        return;
    }
    if (d.isrc.length) {
        Descriptor copy = d;
        [[JLTidalAPI shared] getTrackByISRC:d.isrc
                                 completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
            if (error) {
                done(factsWithStatus(jl_tidal_status_unavailable));
            } else if (tracks.count > 0) {
                done(factsForTrack(tracks.firstObject, jl_tidal_match_isrc));
            } else {
                resolveBySearch(copy, done);  // tagged, but not under that ISRC
            }
        }];
        return;
    }
    resolveBySearch(d, done);
}

const char *statusName(jl_tidal_lookup_status s) {
    switch (s) {
    case jl_tidal_status_found: return "found";
    case jl_tidal_status_not_found: return "not found";
    default: return "unavailable";
    }
}

const char *matchName(jl_tidal_match m) {
    switch (m) {
    case jl_tidal_match_track_id: return "track id";
    case jl_tidal_match_isrc: return "ISRC";
    case jl_tidal_match_search: return "search";
    default: return "-";
    }
}

class LookupEngine {
public:
    static LookupEngine &get() {
        // Never destroyed: a static destructor would run after fb2k teardown.
        static LookupEngine *engine = new LookupEngine();
        return *engine;
    }

    // Any thread.
    bool cached(NSString *key, jl_tidal_track_facts &out) {
        std::lock_guard<std::mutex> guard(m_lock);
        ensureLoaded();
        return factsFromRecord(m_cache[key], out);
    }

    // Main thread.
    void lookup(metadb_handle_list_cref items, jl_tidal_lookup_notify::ptr notify) {
        if (m_shutdown || notify.is_empty()) return;
        auto request = std::make_shared<Request>();
        request->notify = notify;
        request->remaining = items.get_count();

        // Cached answers go out first, but never from inside this call.
        auto hits = std::make_shared<std::vector<std::pair<metadb_handle_ptr, jl_tidal_track_facts>>>();
        for (t_size i = 0; i < items.get_count(); i++) {
            Descriptor d = describe(items[i]);
            jl_tidal_track_facts facts;
            if (d.cacheKey && cached(d.cacheKey, facts)) {
                hits->emplace_back(items[i], facts);
            } else {
                m_queue.push_back(Job{items[i], request});
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (auto &hit : *hits) deliver(request, hit.first, hit.second);
            if (request->remaining == 0) finish(request);  // empty lookup
            pump();
        });
    }

    // Main thread.
    void shutdown() {
        m_shutdown = true;
        m_queue.clear();
        save(true);
    }

private:
    struct Request {
        jl_tidal_lookup_notify::ptr notify;
        size_t remaining = 0;
        bool finished = false;
    };
    struct Job {
        metadb_handle_ptr item;
        std::shared_ptr<Request> request;
    };

    void finish(const std::shared_ptr<Request> &request) {
        if (request->finished) return;
        request->finished = true;
        request->notify->on_done();
    }

    // Drops the request's queued jobs; pending answers then find it finished.
    void cancel(const std::shared_ptr<Request> &request) {
        for (auto it = m_queue.begin(); it != m_queue.end();) {
            it = (it->request == request) ? m_queue.erase(it) : it + 1;
        }
        finish(request);
    }

    void deliver(const std::shared_ptr<Request> &request, const metadb_handle_ptr &item,
                 const jl_tidal_track_facts &facts) {
        if (request->finished || m_shutdown) return;
        if (request->notify->is_cancelled()) {
            cancel(request);
            return;
        }
        request->notify->on_item(item, facts);
        if (--request->remaining == 0) finish(request);
    }

    void pump() {
        while (!m_busy && !m_shutdown && !m_queue.empty()) {
            Job job = m_queue.front();
            m_queue.pop_front();
            if (job.request->finished) continue;
            if (job.request->notify->is_cancelled()) {
                cancel(job.request);
                continue;
            }

            Descriptor d = describe(job.item);
            jl_tidal_track_facts facts;
            if (!d.cacheKey) {
                // Tags not read yet is worth asking again; tags without
                // anything to match on is not.
                deliver(job.request, job.item,
                        factsWithStatus(d.haveInfo ? jl_tidal_status_not_found : jl_tidal_status_unavailable));
                continue;
            }
            if (cached(d.cacheKey, facts)) {  // answered while this job waited
                deliver(job.request, job.item, facts);
                continue;
            }
            if (![[JLTidalAuthService shared] isAuthenticated]) {
                deliver(job.request, job.item, factsWithStatus(jl_tidal_status_unavailable));
                continue;
            }

            m_busy = true;
            NSString *key = d.cacheKey;
            resolve(d, ^(jl_tidal_track_facts result) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    m_busy = false;
                    if (m_shutdown) return;
                    if (tidal::isDebugLoggingCached()) {
                        tidal::logDebug([[NSString stringWithFormat:@"Lookup %@: %s via %s, bpm %.1f, key '%s'",
                            key, statusName(result.status), matchName(result.match), result.bpm,
                            result.key.c_str()] UTF8String]);
                    }
                    if (result.status != jl_tidal_status_unavailable) store(key, result);
                    deliver(job.request, job.item, result);
                    pump();
                });
            });
        }
    }

    void store(NSString *key, const jl_tidal_track_facts &facts) {
        {
            std::lock_guard<std::mutex> guard(m_lock);
            ensureLoaded();
            m_cache[key] = recordFromFacts(facts);
            m_dirty = true;
        }
        if (m_saveScheduled) return;
        m_saveScheduled = true;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kSaveDelayNs), dispatch_get_main_queue(), ^{
            m_saveScheduled = false;
            if (!m_shutdown) save(false);
        });
    }

    // Caller holds m_lock.
    void ensureLoaded() {
        if (m_cache) return;
        m_cache = [NSMutableDictionary dictionary];
        try {
            m_path = str(filesystem::g_get_native_path(core_api::pathInProfile("tidal_lookup_cache.plist")).c_str());
        } catch (const std::exception &e) {
            tidal::logError((std::string("Lookup cache path unavailable: ") + e.what()).c_str());
        }
        NSData *data = m_path ? [NSData dataWithContentsOfFile:m_path] : nil;
        if (!data) return;
        id stored = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
        if (![stored isKindOfClass:[NSDictionary class]]) return;
        jl_tidal_track_facts scratch;
        for (NSString *key in (NSDictionary *)stored) {
            NSDictionary *record = ((NSDictionary *)stored)[key];
            if (factsFromRecord(record, scratch)) m_cache[key] = record;  // expired ones dropped
        }
    }

    void save(bool synchronous) {
        NSDictionary *snapshot;
        NSString *path;
        {
            std::lock_guard<std::mutex> guard(m_lock);
            if (!m_dirty || !m_cache || !m_path) return;
            snapshot = [m_cache copy];
            path = m_path;
            m_dirty = false;
        }
        void (^write)(void) = ^{
            NSError *error = nil;
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:snapshot
                                                                      format:NSPropertyListBinaryFormat_v1_0
                                                                     options:0 error:&error];
            if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
                tidal::logError([[NSString stringWithFormat:@"Lookup cache not saved: %@",
                                  error.localizedDescription ?: @"unknown error"] UTF8String]);
            }
        };
        if (synchronous) {
            write();
        } else {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), write);
        }
    }

    std::mutex m_lock;  // guards m_cache, m_path, m_dirty
    __strong NSMutableDictionary<NSString *, NSDictionary *> *m_cache = nil;
    __strong NSString *m_path = nil;
    bool m_dirty = false;

    // Main thread only.
    std::deque<Job> m_queue;
    bool m_busy = false;
    bool m_saveScheduled = false;
    bool m_shutdown = false;
};

class tidal_lookup_impl : public jl_tidal_lookup {
public:
    bool get_cached(const metadb_handle_ptr &item, jl_tidal_track_facts &out) override {
        if (item.is_empty()) return false;
        @autoreleasepool {
            Descriptor d = describe(item);
            return d.cacheKey && LookupEngine::get().cached(d.cacheKey, out);
        }
    }

    void lookup(metadb_handle_list_cref items, jl_tidal_lookup_notify::ptr notify) override {
        if (core_api::is_main_thread()) {
            @autoreleasepool { LookupEngine::get().lookup(items, notify); }
            return;
        }
        // Off-contract caller: marshal rather than race the queue.
        metadb_handle_list copy;
        copy.add_items(items);
        fb2k::inMainThread([copy, notify] {
            @autoreleasepool { LookupEngine::get().lookup(copy, notify); }
        });
    }
};

FB2K_SERVICE_FACTORY(tidal_lookup_impl);

} // namespace

namespace tidal {

void shutdownLookupService() {
    @autoreleasepool { LookupEngine::get().shutdown(); }
}

} // namespace tidal
