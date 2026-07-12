//
//  DecorationCoordinator.mm
//  foo_simplaylist_mac
//
//  See DecorationCoordinator.h. Threading model: all public methods and all
//  store mutations happen on the main thread; provider decorate()/
//  decorate_group() calls happen on a background queue per the API contract;
//  provider invalidate callbacks may arrive on any thread and are marshaled
//  to main here.
//

#import "DecorationCoordinator.h"

#import "../../../../shared/jl_decorator_api.h"

#include <exception>
#include <unordered_map>
#include <unordered_set>
#include <vector>

// Handle-cache safety valve: decorations for at most this many distinct
// handles are kept; beyond it the cache resets (next draw re-warms the
// visible screen). Prevents unbounded growth across huge playlists.
static const NSUInteger kMaxHandleEntries = 20000;

@interface DecorationCoordinator ()
- (void)providerInvalidatedHandles:(const metadb_handle_list &)affected;
@end

namespace {

// Provider -> host invalidation bridge. May be called on any thread.
class InvalidateAdapter : public jl_decoration_invalidate_callback {
public:
    __weak DecorationCoordinator *owner = nil;

    void on_decorations_invalidated(metadb_handle_list_cref affected) override {
        metadb_handle_list copied(affected);
        DecorationCoordinator *coordinator = owner;
        if (!coordinator) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [coordinator providerInvalidatedHandles:copied];
        });
    }
};

// Converts one provider decoration to the view-layer value object.
RowDecoration *rowDecorationFromApi(const jl_row_decoration &src) {
    RowDecoration *dec = [[RowDecoration alloc] init];
    dec.tintRGBA = src.bg_tint;
    dec.iconId = src.icon;
    dec.iconRGBA = src.icon_color;
    dec.strikethrough = src.strikethrough;
    if (!src.tooltip.is_empty()) {
        dec.tooltip = [NSString stringWithUTF8String:src.tooltip.c_str()];
    }
    return dec;
}

bool apiDecorationIsEmpty(const jl_row_decoration &d) {
    return d.bg_tint == 0 && d.icon == jl_icon_none && !d.strikethrough &&
           d.tooltip.is_empty();
}

}  // namespace

@implementation DecorationCoordinator {
    std::vector<jl_row_decorator_provider::ptr> _providers;
    std::unique_ptr<InvalidateAdapter> _invalidateAdapter;
    void (^_invalidationHandler)(void);
    dispatch_queue_t _queryQueue;

    // Handles are cache keys by raw pointer; retain them so pointer identity
    // stays valid for the cache lifetime.
    std::unordered_map<uintptr_t, metadb_handle_ptr> _retainedHandles;
    std::unordered_set<uintptr_t> _inflightHandles;
    std::unordered_set<NSInteger> _inflightGroups;

    // Selection retained while a provider context menu is open.
    metadb_handle_list _menuHandles;
}

+ (instancetype)coordinatorWithInvalidationHandler:(void (^)(void))invalidationHandler {
    std::vector<jl_row_decorator_provider::ptr> providers;
    for (auto provider : jl_row_decorator_provider::enumerate()) {
        providers.push_back(provider);
    }
    if (providers.empty()) return nil;  // Zero-provider guard

    DecorationCoordinator *coordinator = [[DecorationCoordinator alloc] init];
    if (coordinator) {
        coordinator->_providers = std::move(providers);
        coordinator->_invalidationHandler = [invalidationHandler copy];
        coordinator->_store = [[DecorationStore alloc] init];
        coordinator->_queryQueue = dispatch_queue_create(
            "com.foobar2000.simplaylist.decorations", DISPATCH_QUEUE_SERIAL);
        coordinator->_invalidateAdapter = std::make_unique<InvalidateAdapter>();
        coordinator->_invalidateAdapter->owner = coordinator;
        for (auto &provider : coordinator->_providers) {
            provider->register_invalidate_callback(coordinator->_invalidateAdapter.get());
        }
        FB2K_console_formatter() << "[SimPlaylist] " << (unsigned)coordinator->_providers.size()
                                 << " row decorator provider(s) registered";
    }
    return coordinator;
}

- (void)shutdown {
    if (_invalidateAdapter) {
        for (auto &provider : _providers) {
            provider->unregister_invalidate_callback(_invalidateAdapter.get());
        }
        _invalidateAdapter.reset();
    }
    _providers.clear();
}

#pragma mark - Prepare (visible range + overscan)

- (void)prepareTrackIndices:(NSIndexSet *)indices inPlaylist:(t_size)playlist {
    if (_providers.empty() || indices.count == 0) return;

    // Safety valve before growing the cache further
    if (_store.handleEntryCount > kMaxHandleEntries) {
        [_store invalidateAllHandles];
        [_store clearIndexBindings];
        _retainedHandles.clear();
    }

    auto pm = playlist_manager::get();
    t_size playlistItemCount = pm->playlist_get_item_count(playlist);

    __block metadb_handle_list batch;
    __block std::vector<uintptr_t> batchKeys;

    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= playlistItemCount) return;

        uintptr_t key = 0;
        if (![self->_store getHandleKey:&key forIndex:(NSInteger)idx]) {
            metadb_handle_ptr handle;
            if (!pm->playlist_get_item_handle(handle, playlist, (t_size)idx)) return;
            key = (uintptr_t)handle.get_ptr();
            self->_retainedHandles[key] = handle;
            [self->_store bindIndex:(NSInteger)idx toHandleKey:key];
        }

        if (![self->_store hasEntryForHandleKey:key] && !self->_inflightHandles.count(key)) {
            auto retained = self->_retainedHandles.find(key);
            if (retained == self->_retainedHandles.end()) return;
            self->_inflightHandles.insert(key);
            batch.add_item(retained->second);
            batchKeys.push_back(key);
        }
    }];

    if (batchKeys.empty()) return;

    auto providers = _providers;
    std::vector<uintptr_t> keys = std::move(batchKeys);
    metadb_handle_list items = std::move(batch);
    __weak DecorationCoordinator *weakSelf = self;

    dispatch_async(_queryQueue, ^{
        const t_size count = items.get_count();
        NSMutableArray<RowDecoration *> *resolved = [NSMutableArray arrayWithCapacity:count];
        std::vector<bool> taken(count, false);
        std::vector<jl_row_decoration> merged(count);

        for (auto &provider : providers) {
            pfc::list_t<jl_row_decoration> out;
            try {
                provider->decorate(items, out);
            } catch (const std::exception &e) {
                FB2K_console_formatter()
                    << "[SimPlaylist] decorator provider threw in decorate(): " << e.what();
                continue;
            } catch (...) {
                console::error("[SimPlaylist] decorator provider threw in decorate()");
                continue;
            }
            if (out.get_count() != count) {  // Contract violation; skip
                FB2K_console_formatter()
                    << "[SimPlaylist] decorator provider returned " << (unsigned)out.get_count()
                    << " decorations for " << (unsigned)count << " items; batch skipped";
                continue;
            }
            for (t_size i = 0; i < count; i++) {
                // First provider with a non-empty, non-pending answer wins
                if (!taken[i] && !out[i].pending && !apiDecorationIsEmpty(out[i])) {
                    merged[i] = out[i];
                    taken[i] = true;
                }
            }
        }

        for (t_size i = 0; i < count; i++) {
            [resolved addObject:rowDecorationFromApi(merged[i])];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            DecorationCoordinator *strongSelf = weakSelf;
            if (!strongSelf) return;
            for (size_t i = 0; i < keys.size(); i++) {
                [strongSelf->_store setDecoration:resolved[i] forHandleKey:keys[i]];
                strongSelf->_inflightHandles.erase(keys[i]);
            }
            if (strongSelf->_invalidationHandler) strongSelf->_invalidationHandler();
        });
    });
}

- (void)prepareGroup:(NSInteger)groupIndex
              header:(NSString *)header
          indexRange:(NSRange)indexRange
          inPlaylist:(t_size)playlist {
    if (_providers.empty()) return;
    if ([_store isGroupResolved:groupIndex] || _inflightGroups.count(groupIndex)) return;

    auto pm = playlist_manager::get();
    t_size playlistItemCount = pm->playlist_get_item_count(playlist);

    metadb_handle_list members;
    for (NSUInteger idx = indexRange.location; idx < NSMaxRange(indexRange); idx++) {
        if (idx >= playlistItemCount) break;
        metadb_handle_ptr handle;
        if (pm->playlist_get_item_handle(handle, playlist, (t_size)idx)) {
            members.add_item(handle);
        }
    }
    if (members.get_count() == 0) return;

    _inflightGroups.insert(groupIndex);

    auto providers = _providers;
    pfc::string8 headerText([header UTF8String] ?: "");
    __weak DecorationCoordinator *weakSelf = self;

    dispatch_async(_queryQueue, ^{
        jl_group_key key;
        key.header_text = headerText;
        key.first_member = members[0];

        GroupDecoration *result = nil;
        for (auto &provider : providers) {
            jl_group_decoration out;
            bool decorated = false;
            try {
                decorated = provider->decorate_group(key, members, out);
            } catch (const std::exception &e) {
                FB2K_console_formatter()
                    << "[SimPlaylist] decorator provider threw in decorate_group(): " << e.what();
                continue;
            } catch (...) {
                console::error("[SimPlaylist] decorator provider threw in decorate_group()");
                continue;
            }
            if (decorated) {
                result = [[GroupDecoration alloc] init];
                if (!out.badge_text.is_empty()) {
                    result.badgeText = [NSString stringWithUTF8String:out.badge_text.c_str()];
                }
                result.badgeRGBA = out.badge_color;
                result.iconId = out.icon;
                break;  // First provider with a group decoration wins
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            DecorationCoordinator *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_inflightGroups.erase(groupIndex);
            [strongSelf->_store setGroupDecoration:result forGroupIndex:groupIndex];
            if (result && strongSelf->_invalidationHandler) strongSelf->_invalidationHandler();
        });
    });
}

#pragma mark - Invalidation

- (void)noteIndexMappingChanged {
    [_store clearIndexBindings];
    [_store invalidateAllHandles];
    _retainedHandles.clear();
    _inflightGroups.clear();
    // In-flight batches commit against stale keys; harmless (unreferenced
    // entries, reset by the safety valve at worst).
}

- (void)handleMetadbChanged:(metadb_handle_list_cref)changed {
    if (changed.get_count() == 0) return;
    std::vector<uintptr_t> keys;
    keys.reserve(changed.get_count());
    for (t_size i = 0; i < changed.get_count(); i++) {
        keys.push_back((uintptr_t)changed[i].get_ptr());
    }
    [_store invalidateHandleKeys:keys.data() count:keys.size()];
    [_store clearGroupDecorations];
    if (_invalidationHandler) _invalidationHandler();
}

- (void)providerInvalidatedHandles:(const metadb_handle_list &)affected {
    if (affected.get_count() == 0) {
        [_store invalidateAllHandles];
    } else {
        std::vector<uintptr_t> keys;
        keys.reserve(affected.get_count());
        for (t_size i = 0; i < affected.get_count(); i++) {
            keys.push_back((uintptr_t)affected[i].get_ptr());
        }
        [_store invalidateHandleKeys:keys.data() count:keys.size()];
    }
    [_store clearGroupDecorations];
    if (_invalidationHandler) _invalidationHandler();
}

#pragma mark - Context actions

- (BOOL)appendContextActionsToMenu:(NSMenu *)menu forHandles:(metadb_handle_list_cref)handles {
    if (_providers.empty() || handles.get_count() == 0) return NO;

    BOOL added = NO;
    for (size_t p = 0; p < _providers.size(); p++) {
        pfc::list_t<jl_context_action> actions;
        try {
            _providers[p]->context_actions(handles, actions);
        } catch (const std::exception &e) {
            FB2K_console_formatter()
                << "[SimPlaylist] decorator provider " << (unsigned)p
                << " threw in context_actions(): " << e.what();
            continue;
        } catch (...) {
            console::error("[SimPlaylist] decorator provider threw in context_actions()");
            continue;
        }
        for (t_size a = 0; a < actions.get_count(); a++) {
            const jl_context_action &action = actions[a];
            // nil on invalid UTF-8; NSMenuItem throws on a nil title
            NSString *title = action.title.is_empty()
                ? nil
                : [NSString stringWithUTF8String:action.title.c_str()];
            if (title.length == 0) continue;
            if (!added) {
                [menu addItem:[NSMenuItem separatorItem]];
                _menuHandles = handles;  // Retain selection for invocation
                added = YES;
            }
            NSMenuItem *item = [[NSMenuItem alloc]
                initWithTitle:title
                       action:@selector(decorationActionInvoked:)
                keyEquivalent:@""];
            item.target = self;
            item.enabled = action.enabled;  // Host menus disable auto-enablement
            item.representedObject = @[@(p), @(action.action_id), @(action.enabled)];
            [menu addItem:item];
        }
    }
    return added;
}

// NSMenu auto-enablement path: honor the provider's enabled flag.
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(decorationActionInvoked:)) {
        NSArray *context = item.representedObject;
        if (![context isKindOfClass:[NSArray class]]) return YES;
        return context.count < 3 || [context[2] boolValue];
    }
    return YES;
}

- (void)decorationActionInvoked:(NSMenuItem *)item {
    NSArray *context = item.representedObject;
    if (![context isKindOfClass:[NSArray class]] || context.count != 3) return;
    size_t providerIndex = [context[0] unsignedLongValue];
    uint32_t actionId = [context[1] unsignedIntValue];
    if (providerIndex >= _providers.size()) return;
    try {
        _providers[providerIndex]->execute_context_action(actionId, _menuHandles);
    } catch (const std::exception &e) {
        FB2K_console_formatter()
            << "[SimPlaylist] decorator provider threw in execute_context_action(): " << e.what();
    } catch (...) {
        console::error("[SimPlaylist] decorator provider threw in execute_context_action()");
    }
}

@end
