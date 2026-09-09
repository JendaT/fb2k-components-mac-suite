#pragma once

//
// jl_decorator_api.h — suite-level SimPlaylist row/group decorator provider API
//
// Generic extension point (intake system doc 04, Part A): any component may
// register a jl_row_decorator_provider service and SimPlaylist will render its
// row tints, gutter icons, group header badges and context actions. SimPlaylist
// stays agnostic of what the decorations mean.
//
// Header-only: the service GUID is defined as a C++17 inline variable, so
// every component that includes it links its own copy and cross-component
// matching works by GUID value. Includes the SDK itself (all suite components
// have the SDK root on their header search path).
//
// Deviations from the doc 04 sketch (to be reflected in the doc via PR):
// - COLORREF + float tint_alpha  ->  jl_rgba_t (packed 0xRRGGBBAA, one field)
// - const char* tooltip          ->  pfc::string8 (owned, no lifetime issues)
// - set_invalidate_cb(cb)        ->  register/unregister_invalidate_callback
//   (multiple SimPlaylist panel instances must each observe invalidation)
// - added execute_context_action() — the sketch listed actions but had no
//   invocation path
//
// Threading contract:
// - decorate() / decorate_group() are called OFF the main thread and must be
//   fast: answer from the provider's own cache or return pending=true; never
//   block on I/O or subprocesses. Pending rows are re-requested after the
//   provider fires its invalidate callback. Each host panel runs its own
//   query queue, so these calls may arrive CONCURRENTLY from multiple
//   threads (one per open panel); implementations must be thread-safe.
// - context_actions() / execute_context_action() are called on the main
//   thread (menu construction); keep context_actions() fast.
// - register/unregister_invalidate_callback are called on the main thread.
//   Providers may fire callbacks from ANY thread; hosts marshal to main.
// - Callback lifetime: unregister_invalidate_callback() does NOT synchronize
//   with in-flight invocations -- a callback may still be executing (or about
//   to execute from a snapshot the provider already took) when unregister
//   returns. The HOST must therefore keep the callback object valid after
//   unregistering (SimPlaylist intentionally never frees its adapter);
//   providers should stop invoking promptly after unregistration but need
//   not block on in-flight deliveries.
//
// Multiple providers:
// - The host merges per row/group with first-registered-provider-wins, taking
//   the whole decoration from the winning provider (no field-wise merging;
//   pending or default-constructed answers do not win). Provider precedence
//   follows service enumeration order, which is unspecified. v1 of this API
//   targets a single active provider.
//
// ABI / evolution:
// - The structs below cross the dylib boundary by value: their layouts are
//   FROZEN for v1. Do not add, remove or reorder fields. Extensions require a
//   new service interface (jl_row_decorator_provider_v2 with its own GUID)
//   carrying new struct types. jl_icon_id is the one append-only exception.
//

#include <foobar2000/SDK/foobar2000.h>

#include <cstdint>

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

// Packed RGBA color, 0xRRGGBBAA. 0 (alpha 0) means "none" / "use default".
typedef uint32_t jl_rgba_t;

inline constexpr jl_rgba_t jl_rgba(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    return ((jl_rgba_t)r << 24) | ((jl_rgba_t)g << 16) | ((jl_rgba_t)b << 8) | a;
}
inline constexpr uint8_t jl_rgba_r(jl_rgba_t c) { return (uint8_t)(c >> 24); }
inline constexpr uint8_t jl_rgba_g(jl_rgba_t c) { return (uint8_t)(c >> 16); }
inline constexpr uint8_t jl_rgba_b(jl_rgba_t c) { return (uint8_t)(c >> 8); }
inline constexpr uint8_t jl_rgba_a(jl_rgba_t c) { return (uint8_t)c; }

// Generic status icon set, rendered by the host as text glyphs in the leading
// gutter column. Values are stable ABI — append only.
enum jl_icon_id : uint32_t {
    jl_icon_none = 0,
    jl_icon_circle_open,        // U+25CB
    jl_icon_circle_left_half,   // U+25D0
    jl_icon_circle_right_half,  // U+25D1
    jl_icon_circle_filled,      // U+25CF
    jl_icon_warning,            // U+26A0
    jl_icon_cross,              // U+2715
    jl_icon_check,              // U+2713
    jl_icon_arrow_right,        // U+2192
};

// Per-row decoration. Default-constructed value = "no decoration".
struct jl_row_decoration {
    jl_rgba_t bg_tint = 0;        // Row background tint, drawn under selection
    jl_icon_id icon = jl_icon_none;
    jl_rgba_t icon_color = 0;     // 0 = host default label color
    pfc::string8 tooltip;         // Empty = none
    bool strikethrough = false;   // Strike track text (e.g. rejected items)
    bool pending = false;         // Provider will answer later; host renders the
                                  // row undecorated and re-queries after the
                                  // provider's invalidate callback fires
};

// Group header decoration.
struct jl_group_decoration {
    pfc::string8 badge_text;      // Appended to the group header; empty = none
    jl_rgba_t badge_color = 0;    // 0 = host default secondary color
    jl_icon_id icon = jl_icon_none;
};

// Identifies a group to decorate_group(). The member list is passed alongside;
// the key carries the display identity.
struct jl_group_key {
    pfc::string8 header_text;         // Header as displayed by the host
    metadb_handle_ptr first_member;   // Representative item (may be null)
};

// A context menu contribution for the current selection.
struct jl_context_action {
    pfc::string8 title;           // Menu item title
    uint32_t action_id = 0;       // Provider-scoped id, passed back on invoke
    bool enabled = true;
};

// ---------------------------------------------------------------------------
// Invalidation callback (host-implemented, plain interface like the SDK's
// *_callback_dynamic classes; not a service)
// ---------------------------------------------------------------------------

class NOVTABLE jl_decoration_invalidate_callback {
public:
    // Decorations for the given items changed (async state transition). An
    // EMPTY list means "everything from this provider changed". May be called
    // from any thread; the host marshals to the main thread itself.
    virtual void on_decorations_invalidated(metadb_handle_list_cref affected) = 0;

protected:
    ~jl_decoration_invalidate_callback() {}
};

// ---------------------------------------------------------------------------
// Provider service
// ---------------------------------------------------------------------------

class NOVTABLE jl_row_decorator_provider : public service_base {
public:
    // Batched row decoration for items entering the host's visible range +
    // overscan. Called off-main-thread. Must resize `out` to items.get_count()
    // entries (index-aligned with `items`); default-constructed entries mean
    // "no decoration".
    virtual void decorate(metadb_handle_list_cref items,
                          pfc::list_t<jl_row_decoration> &out) = 0;

    // Group-level decoration for a group header. Called off-main-thread.
    // Returns false when this provider has nothing for the group. Hosts may
    // truncate `members` for very large groups (SimPlaylist passes at most
    // the first 64); key.first_member is always members[0].
    virtual bool decorate_group(const jl_group_key &key,
                                metadb_handle_list_cref members,
                                jl_group_decoration &out) = 0;

    // Context menu contributions for the current selection (main thread).
    virtual void context_actions(metadb_handle_list_cref sel,
                                 pfc::list_t<jl_context_action> &out) = 0;

    // Invoke an action previously returned by context_actions() (main thread).
    virtual void execute_context_action(uint32_t action_id,
                                        metadb_handle_list_cref sel) = 0;

    // Invalidation callback registration (main thread). Providers must support
    // multiple concurrent callbacks (one per host panel instance) and tolerate
    // unregistration of a callback that was never registered.
    virtual void register_invalidate_callback(jl_decoration_invalidate_callback *cb) = 0;
    virtual void unregister_invalidate_callback(jl_decoration_invalidate_callback *cb) = 0;

    FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(jl_row_decorator_provider);
};

// {26655126-2913-4846-96C6-30AEE51ACB2B}
inline const GUID jl_row_decorator_provider::class_guid =
    { 0x26655126, 0x2913, 0x4846, { 0x96, 0xc6, 0x30, 0xae, 0xe5, 0x1a, 0xcb, 0x2b } };
