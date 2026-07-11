//
//  DecorationStore.mm
//  foo_simplaylist_mac
//
//  Pure cache/index model for row decorator providers — see DecorationStore.h.
//

#import "DecorationStore.h"

#include <unordered_map>

@implementation RowDecoration

- (BOOL)isEmpty {
    return _tintRGBA == 0 && _iconId == 0 && !_strikethrough && _tooltip.length == 0;
}

@end

@implementation GroupDecoration
@end

@implementation DecorationStore {
    std::unordered_map<uintptr_t, RowDecoration *> _byHandle;
    std::unordered_map<NSInteger, uintptr_t> _indexToHandle;
    std::unordered_map<NSInteger, GroupDecoration *> _byGroup;  // nil-valued = resolved empty
}

#pragma mark - Per-handle cache

- (void)setDecoration:(RowDecoration *)decoration forHandleKey:(uintptr_t)key {
    _byHandle[key] = decoration;
}

- (BOOL)hasEntryForHandleKey:(uintptr_t)key {
    return _byHandle.find(key) != _byHandle.end();
}

#pragma mark - Index bindings

- (void)bindIndex:(NSInteger)index toHandleKey:(uintptr_t)key {
    _indexToHandle[index] = key;
}

- (BOOL)isIndexBound:(NSInteger)index {
    return _indexToHandle.find(index) != _indexToHandle.end();
}

- (BOOL)getHandleKey:(uintptr_t *)outKey forIndex:(NSInteger)index {
    auto it = _indexToHandle.find(index);
    if (it == _indexToHandle.end()) return NO;
    *outKey = it->second;
    return YES;
}

- (RowDecoration *)decorationForIndex:(NSInteger)index {
    auto bound = _indexToHandle.find(index);
    if (bound == _indexToHandle.end()) return nil;
    auto entry = _byHandle.find(bound->second);
    if (entry == _byHandle.end()) return nil;
    RowDecoration *dec = entry->second;
    return dec.isEmpty ? nil : dec;
}

#pragma mark - Group cache

- (void)setGroupDecoration:(GroupDecoration *)decoration forGroupIndex:(NSInteger)groupIndex {
    _byGroup[groupIndex] = decoration;
}

- (BOOL)isGroupResolved:(NSInteger)groupIndex {
    return _byGroup.find(groupIndex) != _byGroup.end();
}

- (GroupDecoration *)groupDecorationForGroupIndex:(NSInteger)groupIndex {
    auto it = _byGroup.find(groupIndex);
    return (it == _byGroup.end()) ? nil : it->second;
}

#pragma mark - Invalidation

- (void)clearIndexBindings {
    _indexToHandle.clear();
    _byGroup.clear();
}

- (void)invalidateHandleKeys:(const uintptr_t *)keys count:(NSUInteger)count {
    for (NSUInteger i = 0; i < count; i++) {
        _byHandle.erase(keys[i]);
    }
}

- (void)invalidateAllHandles {
    _byHandle.clear();
}

- (void)clearGroupDecorations {
    _byGroup.clear();
}

#pragma mark - Introspection

- (NSUInteger)handleEntryCount {
    return _byHandle.size();
}

- (NSUInteger)bindingCount {
    return _indexToHandle.size();
}

@end
