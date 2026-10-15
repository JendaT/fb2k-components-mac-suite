#pragma once

//
// jl_tidal_api.h — suite-level TIDAL catalogue lookup service
//
// Provided by foo_jl_tidal. Any component may ask what TIDAL's catalogue
// knows about a track -- tempo and musical key -- for local files as well as
// tidal:// entries. A local file is matched by its ISRC tag when it has one,
// otherwise by searching its artist and title and accepting only a result
// whose length is within 2 seconds; the answer says which, so a caller can
// ignore the fuzzy matches.
//
// Header-only: the GUIDs are C++17 inline variables, so every component that
// includes it links its own copy and cross-component matching works by GUID
// value (same pattern as jl_decorator_api.h).
//
// Getting the service (absent when foo_jl_tidal is not installed):
//
//     jl_tidal_lookup::ptr tidal;
//     if (fb2k::std_api_try_get(tidal)) { ... }
//
// Receiving results:
//
//     class bpm_notify : public jl_tidal_lookup_notify {
//         void on_item(const metadb_handle_ptr &item,
//                      const jl_tidal_track_facts &facts) override { ... }
//         void on_done() override { ... }
//         bool is_cancelled() override { return m_cancelled; }
//     public:
//         bool m_cancelled = false;
//     };
//     tidal->lookup(items, fb2k::service_new<bpm_notify>());
//
// Threading contract:
// - get_cached() may be called from ANY thread. It never touches the network
//   and is cheap enough for row rendering.
// - lookup() is called on the main thread. Every notify method is called on
//   the main thread, never re-entrantly from inside lookup().
//
// Cost: lookups run one track at a time behind every other TIDAL request
// (browser, playback), costing 1-3 API requests per uncached track. Answers
// are cached on disk in the foobar2000 profile: found tracks permanently,
// "not found" for 30 days. "Unavailable" (signed out, offline, rate limited)
// is never cached, so asking again later retries.
//
// ABI / evolution:
// - jl_tidal_track_facts crosses the dylib boundary by value: its layout is
//   FROZEN for v1. Do not add, remove or reorder fields. Extensions require a
//   new service interface (jl_tidal_lookup_v2 with its own GUID). The two
//   enums are append-only.
//

#include <foobar2000/SDK/foobar2000.h>

#include <cstdint>

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

enum jl_tidal_lookup_status : uint32_t {
    // Not answered: signed out of TIDAL, offline, rate limited, or the item's
    // tags have not been read yet. Not cached; ask again later.
    jl_tidal_status_unavailable = 0,
    // TIDAL has the track. bpm and key may still be empty: not every track in
    // the catalogue carries them.
    jl_tidal_status_found,
    // TIDAL has no matching track, or the item has nothing to match on (no
    // ISRC and no artist + title).
    jl_tidal_status_not_found,
};

enum jl_tidal_match : uint32_t {
    jl_tidal_match_none = 0,
    jl_tidal_match_track_id,   // the item is a tidal:// entry
    jl_tidal_match_isrc,       // exact ISRC match
    jl_tidal_match_search,     // artist + title search, length within 2 s
};

struct jl_tidal_track_facts {
    jl_tidal_lookup_status status = jl_tidal_status_unavailable;
    jl_tidal_match match = jl_tidal_match_none;
    float bpm = 0;                 // Beats per minute; 0 = TIDAL has none
    pfc::string8 key;              // "C", "F#m", "Eb", "D Dorian"; empty = none
    pfc::string8 tidal_track_id;   // The matched TIDAL track; empty unless found
};

// ---------------------------------------------------------------------------
// Result receiver (caller-implemented, reference counted)
// ---------------------------------------------------------------------------

class NOVTABLE jl_tidal_lookup_notify : public service_base {
public:
    // One item answered, in no particular order. Cached items are answered
    // first, the rest as TIDAL replies. Not called for items dropped by
    // cancellation.
    virtual void on_item(const metadb_handle_ptr &item, const jl_tidal_track_facts &facts) = 0;

    // Every item of this lookup() answered, or the lookup was cancelled.
    // Called exactly once, unless foobar2000 is shutting down.
    virtual void on_done() = 0;

    // Polled before each uncached item and before each answer. Returning
    // true drops the items not yet answered; on_done() still follows.
    virtual bool is_cancelled() = 0;

    FB2K_MAKE_SERVICE_INTERFACE(jl_tidal_lookup_notify, service_base);
};

// ---------------------------------------------------------------------------
// Provider service (implemented by foo_jl_tidal)
// ---------------------------------------------------------------------------

class NOVTABLE jl_tidal_lookup : public service_base {
public:
    // Answer from the cache only. Returns false when the item has not been
    // looked up yet (or its last attempt was unavailable). Any thread.
    virtual bool get_cached(const metadb_handle_ptr &item, jl_tidal_track_facts &out) = 0;

    // Look the items up, answering each through `notify`. Main thread.
    virtual void lookup(metadb_handle_list_cref items, jl_tidal_lookup_notify::ptr notify) = 0;

    FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(jl_tidal_lookup);
};

// {8BEF8639-95F0-46DA-8E87-FBF177FEA7B9}
inline const GUID jl_tidal_lookup::class_guid =
    { 0x8bef8639, 0x95f0, 0x46da, { 0x8e, 0x87, 0xfb, 0xf1, 0x77, 0xfe, 0xa7, 0xb9 } };

// {5E4DEFE0-ACC3-4692-ADE1-628DED7125FE}
inline const GUID jl_tidal_lookup_notify::class_guid =
    { 0x5e4defe0, 0xacc3, 0x4692, { 0xad, 0xe1, 0x62, 0x8d, 0xed, 0x71, 0x25, 0xfe } };
