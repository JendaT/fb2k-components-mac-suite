#pragma once

//
// jl_beatgrid_api.h — suite-level beat grid service
//
// Provided by foo_jl_bpm (BPM Analyzer). It analyses tracks for a constant
// master beat grid and serves it, with statistics per bar, to components
// that draw it: Waveform Seekbar's phrase markers, later SimPlaylist. Grids
// are stored per track by the provider (metadb_index), never in tags.
// The values and the shared phrase-marker rules are in jl_beatgrid_types.h.
//
// Header-only: the GUIDs are C++17 inline variables, so every component that
// includes it links its own copy and cross-component matching works by GUID
// value (same pattern as jl_decorator_api.h and jl_tidal_api.h).
//
// Getting the service (absent when foo_jl_bpm is not installed, or is a
// build from before this GUID):
//
//     jl_beatgrid::ptr grids;
//     if (fb2k::std_api_try_get(grids)) { ... }
//
// Reading a grid:
//
//     jl_beatgrid_summary summary;
//     pfc::array_t<jl_beat_region> regions;
//     pfc::array_t<jl_bar_stat> bars;
//     if (grids->get_status(track) == jl_beatgrid::ready &&
//         grids->get(track, summary, regions, bars)) { ... }
//     else grids->request(track, true);   // the playing track: urgent
//
// Following the grid where it changes (a tempo change, an edit), section by
// section; a track on one grid throughout returns one section, the master:
//
//     pfc::array_t<jl_grid_section> sections;
//     pfc::array_t<jl_bar_stat> sectionBars;
//     if (grids->get_sections(track, sections, sectionBars)) { ... }
//
// Hearing about new grids:
//
//     class seekbar_notify : public jl_beatgrid_notify {
//         void on_ready(const metadb_handle_ptr &item) override { ... }
//     };
//     grids->add_notify(fb2k::service_new<seekbar_notify>());
//
// Threading contract:
// - get_status(), get() and get_sections() may be called from ANY thread. They never do
//   I/O beyond the provider's in-memory index and are cheap enough to call
//   while drawing.
// - request(), add_notify() and remove_notify() are called on the main
//   thread. on_ready() is called on the main thread, never re-entrantly from
//   inside request().
//
// Statuses:
// - not_analysed: no grid stored (or one stored by an incompatible version).
// - queued / analysing: a request is pending or running.
// - ready: get() returns the grid.
// - unavailable: analysis failed, or the track has no pulse anywhere
//   (ambient, spoken word). Consumers treat it like a missing grid.
//
// Cost: the provider decodes the track itself, at low priority, one track at
// a time; request(item, true) puts the item at the front of the queue and
// duplicate requests collapse. Consumers that analyse audio themselves
// should request only after their own pass over the track has finished, so
// the two decodes don't compete.
//
// ABI / evolution:
// - The structs in jl_beatgrid_types.h cross the dylib boundary inside
//   pfc::array_t and by reference; their layouts are FROZEN for this GUID.
//   Any layout change takes a new jl_beatgrid GUID (and interface name), so
//   an old provider reads as missing instead of misbehaving. The status enum
//   is append-only.
//

#include <foobar2000/SDK/foobar2000.h>

#include "jl_beatgrid_types.h"

// ---------------------------------------------------------------------------
// Ready receiver (consumer-implemented, reference counted)
// ---------------------------------------------------------------------------

class NOVTABLE jl_beatgrid_notify : public service_base {
public:
    // A grid was stored for `item` (status ready or unavailable). Main thread.
    virtual void on_ready(const metadb_handle_ptr &item) = 0;

    FB2K_MAKE_SERVICE_INTERFACE(jl_beatgrid_notify, service_base);
};

// ---------------------------------------------------------------------------
// Provider service (implemented by foo_jl_bpm)
// ---------------------------------------------------------------------------

class NOVTABLE jl_beatgrid : public service_base {
public:
    enum status_t : uint32_t { not_analysed = 0, queued, analysing, ready, unavailable };

    // Any thread, no I/O.
    virtual status_t get_status(const metadb_handle_ptr &item) = 0;

    // The stored grid: false unless the status is ready. `regions` and
    // `bars` are resized to fit. Any thread, no I/O.
    virtual bool get(const metadb_handle_ptr &item, jl_beatgrid_summary &out,
                     pfc::array_t<jl_beat_region> &regions, pfc::array_t<jl_bar_stat> &bars) = 0;

    // The stored grid section by section (jl_grid_section): false unless the
    // status is ready, else at least one section. `bars` holds the bar
    // statistics of every section, each section's from its first_bar. Any
    // thread, no I/O.
    virtual bool get_sections(const metadb_handle_ptr &item, pfc::array_t<jl_grid_section> &sections,
                              pfc::array_t<jl_bar_stat> &bars) = 0;

    // Analyse `item` unless it has a grid or is already queued. `urgent`
    // puts it at the front (the playing track). Main thread.
    virtual void request(const metadb_handle_ptr &item, bool urgent) = 0;

    // Main thread. A notify stays registered until removed.
    virtual void add_notify(jl_beatgrid_notify::ptr notify) = 0;
    virtual void remove_notify(jl_beatgrid_notify::ptr notify) = 0;

    FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(jl_beatgrid);
};

// Layout 2: get_sections(). Layout 1 ({08011599-E5C9-49CE-AE1B-BBD56D1EA271})
// was never released.
// {1B84E3AD-93C9-47DE-8A71-8583CDD3DD1B}
inline const GUID jl_beatgrid::class_guid =
    { 0x1b84e3ad, 0x93c9, 0x47de, { 0x8a, 0x71, 0x85, 0x83, 0xcd, 0xd3, 0xdd, 0x1b } };

// {B8EA142D-CC4A-4CC7-9C3B-840E6C15197D}
inline const GUID jl_beatgrid_notify::class_guid =
    { 0xb8ea142d, 0xcc4a, 0x4cc7, { 0x9c, 0x3b, 0x84, 0x0e, 0x6c, 0x15, 0x19, 0x7d } };
