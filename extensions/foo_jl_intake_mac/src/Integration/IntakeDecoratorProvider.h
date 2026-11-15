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

} // namespace intake
