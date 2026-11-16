//
//  IntakeDecoratorProvider.h
//  foo_jl_intake
//
//  The entry points IntakeService uses to drive the provider
//  (IntakeDecoratorProvider.mm). The provider's state lives in one leaked
//  heap object, so it needs no SDK work at static-init time and still
//  accepts callback registration (and the host's unregister) after on_quit.
//

#pragma once

#import "../fb2k_sdk.h"

#include "../../../../shared/jl_decorator_api.h"

#include <memory>

namespace intake {

class IntakeView;

// Any thread (the loader queue). Swaps the view decorate() reads under a
// short lock; with `invalidateAll`, then fires every registered host
// callback once with an empty list ("everything changed"), from a copy of
// the list, outside the lock. `countAsLoad` feeds the decor_stats "loads"
// counter.
void providerPublish(std::shared_ptr<const IntakeView> view, bool invalidateAll, bool countAsLoad);

// Any thread, never from decorate(): fires every registered host callback
// once with an empty list, keeping the view. For a change the view does not
// carry (the slow mac-volume guard was reset).
void providerInvalidateAll();

// Main thread (on_init, later the preferences page): turns the hidden
// decor_stats per-batch counters and log line on or off.
void providerSetStatsEnabled(bool enabled);

// Any thread: the view decorate() reads now (null before the first
// publish). B6: the context menu maps its selection through it.
std::shared_ptr<const IntakeView> providerCurrentView();

// Any thread (the host's decorate queues; the main thread for the temporary
// test_actions `badge` step): the provider's whole decorate_group answer
// for `members` from the current view. False, with `out` untouched, when
// there is no badge: no view, an inert view, members of two roots, or a
// root that is not proposed or approved. No I/O beyond IntakeNativePath.
// `amber`, when given, receives the badge's amber state (IntakeBadge::amber)
// on true: the colour alone cannot tell, as tint_review sets it (0 when off).
bool providerDecorateGroup(metadb_handle_list_cref members, jl_group_decoration &out, bool *amber = nullptr);

} // namespace intake
