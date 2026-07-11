//
//  DecorationStore.h
//  foo_simplaylist_mac
//
//  Pure cache/index model for row decorator providers (intake doc 04 Part A).
//
//  Contains NO foobar2000 SDK dependency and NO drawing code, following the
//  PlaylistLayoutModel pattern so it can be unit-tested and benchmarked
//  standalone. Handles are opaque uintptr_t keys (the SDK layer passes
//  metadb_handle pointers); playlist indices are bound to handle keys by the
//  SDK layer during the prepare pass.
//
//  Threading: main thread only. The coordinator queries providers on a
//  background queue but commits results to the store on the main thread.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Value object mirroring jl_row_decoration with AppKit-free types.
// All-default values mean "provider answered: no decoration".
@interface RowDecoration : NSObject
@property (nonatomic, assign) uint32_t tintRGBA;       // 0xRRGGBBAA, 0 = none
@property (nonatomic, assign) uint32_t iconId;         // jl_icon_id, 0 = none
@property (nonatomic, assign) uint32_t iconRGBA;       // 0 = default color
@property (nonatomic, copy, nullable) NSString *tooltip;
@property (nonatomic, assign) BOOL strikethrough;
@property (nonatomic, readonly) BOOL isEmpty;          // No visible effect
@end

// Value object mirroring jl_group_decoration.
@interface GroupDecoration : NSObject
@property (nonatomic, copy, nullable) NSString *badgeText;
@property (nonatomic, assign) uint32_t badgeRGBA;      // 0 = default color
@property (nonatomic, assign) uint32_t iconId;
@end

@interface DecorationStore : NSObject

// --- Per-handle decoration cache (source of truth) ---
// Entries are stored even when empty so the coordinator does not re-query
// resolved handles; use hasEntryForHandleKey: to decide what to batch.
- (void)setDecoration:(RowDecoration *)decoration forHandleKey:(uintptr_t)key;
- (BOOL)hasEntryForHandleKey:(uintptr_t)key;

// --- Playlist index -> handle key bindings (fast per-row lookup layer) ---
- (void)bindIndex:(NSInteger)index toHandleKey:(uintptr_t)key;
- (BOOL)isIndexBound:(NSInteger)index;
// Returns NO when unbound; otherwise writes the bound key to outKey.
- (BOOL)getHandleKey:(uintptr_t *)outKey forIndex:(NSInteger)index;

// HOT PATH: called per visible row per frame by the draw code. Returns nil
// for unbound indices, unresolved handles, and resolved-empty decorations.
- (nullable RowDecoration *)decorationForIndex:(NSInteger)index;

// --- Group header decoration cache (keyed by group index) ---
// Pass nil decoration to mark a group as resolved-with-nothing.
- (void)setGroupDecoration:(nullable GroupDecoration *)decoration
             forGroupIndex:(NSInteger)groupIndex;
- (BOOL)isGroupResolved:(NSInteger)groupIndex;
- (nullable GroupDecoration *)groupDecorationForGroupIndex:(NSInteger)groupIndex;

// --- Invalidation ---
// Playlist content/order changed: bindings and group cache are stale, the
// per-handle cache is not (metadata identity is per handle).
- (void)clearIndexBindings;
// Provider or metadb invalidation for specific handles: drops their cache
// entries (bindings stay; unresolved lookups return nil until re-prepared).
- (void)invalidateHandleKeys:(const uintptr_t *)keys count:(NSUInteger)count;
// Provider fired a global invalidate: drop the whole per-handle cache.
- (void)invalidateAllHandles;
- (void)clearGroupDecorations;

// --- Introspection (tests/eviction) ---
@property (nonatomic, readonly) NSUInteger handleEntryCount;
@property (nonatomic, readonly) NSUInteger bindingCount;

@end

NS_ASSUME_NONNULL_END
