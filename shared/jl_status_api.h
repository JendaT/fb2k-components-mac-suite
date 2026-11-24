#pragma once

//
// jl_status_api.h — suite-level status provider API
//
// Generic extension point: any component may register a jl_status_provider
// service to report what it is doing (operations running, queued, or just
// ended), and a host such as SimPlaylist shows it: one compact line, and a
// list on demand. The host stays agnostic of what the operations mean.
// First provider: foo_jl_intake (B14); first host: SimPlaylist 2.0 (a pill at
// the bottom right of the panel showing the active playlist).
//
// Header-only: the service GUID is defined as a C++17 inline variable, so
// every component that includes it links its own copy and cross-component
// matching works by GUID value. Includes the SDK itself (all suite components
// have the SDK root on their header search path).
//
// Threading contract:
// - status_line() and status_items() are called on the MAIN thread. They must
//   be cheap and must never block: no I/O, no subprocesses, no metadb
//   queries, no locks held across the call. status_line() is O(1): answer
//   from a value the provider keeps current.
// - status_items() is called only while the host's list is open.
// - register/unregister_status_callback are called on the main thread.
//   Providers may fire callbacks from ANY thread, at any rate; hosts marshal
//   to main and coalesce (SimPlaylist: about 4 per second).
// - The host has NO timer of its own: it re-reads status_line() only after a
//   callback or a panel change. A provider must therefore always return the
//   current truth, and must fire its callback whenever the answer changes,
//   including when it changes with time (for example a result line that
//   expires after a few seconds).
// - Callback lifetime: unregister_status_callback() does NOT synchronize with
//   in-flight invocations -- a callback may still be executing (or about to
//   execute from a snapshot the provider already took) when unregister
//   returns. The HOST must therefore keep the callback object valid after
//   unregistering; providers should stop invoking promptly after
//   unregistration but need not block on in-flight deliveries.
//
// Multiple providers:
// - The host shows the first provider whose status_line() returns true, in
//   service enumeration order (unspecified). v1 targets a single active
//   provider.
//
// ABI / evolution:
// - The structs below cross the dylib boundary by value: their layouts are
//   FROZEN for v1. Do not add, remove or reorder fields. Extensions require a
//   new service interface (jl_status_provider_v2 with its own GUID) carrying
//   new struct types. jl_status_state is append-only; a host shows a value it
//   does not know as running. jl_icon_id comes from jl_decorator_api.h.
//

#include <foobar2000/SDK/foobar2000.h>

#include <cstdint>

#include "jl_decorator_api.h"  // jl_icon_id

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

// State of an operation, or of the line as a whole. Values are stable ABI --
// append only. A host shows a value it does not know as running.
enum jl_status_state : uint32_t {
    jl_status_queued = 0,
    jl_status_running = 1,
    jl_status_succeeded = 2,
    jl_status_failed = 3,
};

// The one line for a host's status area.
// - text: complete and pre-formatted; it already contains any "12/40".
//   One line of UTF-8: the host turns newlines into spaces and cuts the tail
//   to fit, so keep it short.
// - done/total: progress for an optional bar; 0/0 means no bar.
// - icon: optional (jl_icon_check, jl_icon_cross and jl_icon_warning suit
//   results).
// - state: lets the host colour the line, e.g. a failed result shown for a
//   few seconds after an operation ended.
struct jl_status_line {
    pfc::string8 text;
    uint32_t done = 0;
    uint32_t total = 0;
    jl_icon_id icon = jl_icon_none;
    jl_status_state state = jl_status_running;
};

// One entry of the full list.
struct jl_status_item {
    uint64_t id = 0;         // stable while the item exists
    pfc::string8 title;      // e.g. "Placing 12/40"
    pfc::string8 detail;     // e.g. the album, or the error text
    jl_status_state state = jl_status_running;
    uint32_t done = 0;       // 0/0: no progress
    uint32_t total = 0;
    int64_t started_ms = 0;  // Unix epoch milliseconds; 0 = not started (queued)
    int64_t ended_ms = 0;    // Unix epoch milliseconds; 0 = not ended
};

// ---------------------------------------------------------------------------
// Change callback (host-implemented, plain interface like the SDK's
// *_callback_dynamic classes; not a service)
// ---------------------------------------------------------------------------

class NOVTABLE jl_status_callback {
public:
    // May be called from ANY thread, at any rate. Hosts marshal to main and
    // coalesce, then re-read status_line() (and status_items() if the list
    // is open).
    virtual void on_status_changed() = 0;

protected:
    ~jl_status_callback() {}
};

// ---------------------------------------------------------------------------
// The service
// ---------------------------------------------------------------------------

class NOVTABLE jl_status_provider : public service_base {
public:
    // Main thread, O(1), never blocks. True: show `out`, which the provider
    // fills (replacing its contents). False: show nothing; the host ignores
    // `out`.
    virtual bool status_line(jl_status_line &out) = 0;

    // Main thread, only while the host's list is open. Replaces the contents
    // of `out`: running and queued items first, then ended ones, newest
    // first.
    virtual void status_items(pfc::list_t<jl_status_item> &out) = 0;

    // Callback registration (main thread). Providers must support multiple
    // concurrent callbacks (one per host panel instance) and tolerate
    // unregistration of a callback that was never registered.
    virtual void register_status_callback(jl_status_callback *cb) = 0;
    virtual void unregister_status_callback(jl_status_callback *cb) = 0;

    FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(jl_status_provider);
};

// {4693720A-18B1-4A68-88C6-BEF1DAA2FCB8}
inline const GUID jl_status_provider::class_guid =
    { 0x4693720a, 0x18b1, 0x4a68, { 0x88, 0xc6, 0xbe, 0xf1, 0xda, 0xa2, 0xfc, 0xb8 } };
