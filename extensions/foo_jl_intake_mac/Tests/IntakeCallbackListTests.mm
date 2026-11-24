//
//  IntakeCallbackListTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeCallbackList (the status provider's host callbacks,
//  B14): several callbacks, each once; null and repeats refused; removing
//  one that is not there; a round's order and count; an empty round; a
//  callback that removes a later one, removes itself, adds a new one or
//  starts a round of its own from inside its call (no deadlock: calls run
//  outside the lock); and a round on one thread while another adds and
//  removes (run under ASan with the other tests).
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeCallbackList.h"
#include "TestHarness.h"

#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <vector>

using namespace intake;

namespace {

struct FakeCallback {
    std::string name;
    int calls = 0;
    std::function<void()> onCall;  // runs inside the call, after counting
};

// One round that counts each call and runs the callback's own action.
size_t fireRound(CallbackList<FakeCallback> &list, std::vector<std::string> *order = nullptr) {
    return list.forEach([order](FakeCallback *cb) {
        cb->calls++;
        if (order) order->push_back(cb->name);
        if (cb->onCall) cb->onCall();
    });
}

} // anonymous namespace

static void testAddRemove() {
    g_context = "add-remove";
    CallbackList<FakeCallback> list;
    FakeCallback a{"a"}, b{"b"};
    CHECK(list.empty(), "empty at first");
    CHECK(!list.add(nullptr), "null refused");
    CHECK(list.add(&a), "a added");
    CHECK(!list.add(&a), "a again refused");
    CHECK(list.add(&b), "b added");
    CHECK_EQ(list.size(), 2, "two callbacks");
    CHECK(list.contains(&a) && list.contains(&b), "both there");
    FakeCallback stranger{"x"};
    CHECK(!list.remove(&stranger), "removing one never added: nothing");
    CHECK(!list.remove(nullptr), "removing null: nothing");
    CHECK_EQ(list.size(), 2, "still two");
    CHECK(list.remove(&a), "a removed");
    CHECK(!list.remove(&a), "a again: nothing");
    CHECK(!list.contains(&a) && list.contains(&b), "only b");
}

static void testRound() {
    g_context = "round";
    CallbackList<FakeCallback> list;
    CHECK_EQ(fireRound(list), 0, "empty: nobody called");
    FakeCallback a{"a"}, b{"b"}, c{"c"};
    list.add(&a);
    list.add(&b);
    list.add(&c);
    std::vector<std::string> order;
    CHECK_EQ(fireRound(list, &order), 3, "three called");
    CHECK(order == std::vector<std::string>({"a", "b", "c"}), "in registration order");
    CHECK(a.calls == 1 && b.calls == 1 && c.calls == 1, "each once per round");
    list.remove(&b);
    CHECK_EQ(fireRound(list), 2, "after remove: two");
    CHECK(b.calls == 1, "b not called after its removal");
}

static void testRemoveDuringRound() {
    g_context = "remove-during-round";
    CallbackList<FakeCallback> list;
    FakeCallback a{"a"}, b{"b"}, c{"c"};
    a.onCall = [&] { list.remove(&c); };  // an earlier callback removes a later one
    b.onCall = [&] { list.remove(&b); };  // a callback removes itself
    list.add(&a);
    list.add(&b);
    list.add(&c);
    std::vector<std::string> order;
    CHECK_EQ(fireRound(list, &order), 2, "c skipped: removed before its turn");
    CHECK(order == std::vector<std::string>({"a", "b"}), "a, then b");
    CHECK(c.calls == 0, "c never called");
    CHECK(b.calls == 1, "b called once, then removed itself");
    CHECK_EQ(list.size(), 1, "only a left");
    a.onCall = nullptr;
    CHECK_EQ(fireRound(list), 1, "next round: a only");
}

static void testAddDuringRound() {
    g_context = "add-during-round";
    CallbackList<FakeCallback> list;
    FakeCallback a{"a"}, late{"late"};
    a.onCall = [&] { list.add(&late); };
    list.add(&a);
    CHECK_EQ(fireRound(list), 1, "the one added during the round waits");
    CHECK(late.calls == 0, "late not called in that round");
    a.onCall = nullptr;
    CHECK_EQ(fireRound(list), 2, "next round: both");
    CHECK(late.calls == 1, "late called in the next round");
}

static void testReentrantRound() {
    g_context = "reentrant-round";
    CallbackList<FakeCallback> list;
    FakeCallback a{"a"}, b{"b"};
    int depth = 0;
    a.onCall = [&] {
        // A host that reads the provider from its callback, here even a
        // nested round: the lock is not held during calls.
        if (depth++ == 0) fireRound(list);
    };
    list.add(&a);
    list.add(&b);
    CHECK_EQ(fireRound(list), 2, "outer round: two");
    CHECK(a.calls == 2 && b.calls == 2, "the nested round called both once more");
}

static void testThreads() {
    g_context = "threads";
    CallbackList<FakeCallback> list;
    FakeCallback steady{"steady"};
    std::atomic<int> steadyCalls{0};
    std::atomic<int> comerCalls{0};
    FakeCallback comer{"comer"};
    list.add(&steady);
    const int rounds = 20000;
    std::thread firer([&] {
        for (int i = 0; i < rounds; i++) {
            list.forEach([&](FakeCallback *cb) {
                if (cb == &steady) steadyCalls++;
                if (cb == &comer) comerCalls++;
            });
        }
    });
    for (int i = 0; i < rounds; i++) {
        list.add(&comer);
        list.remove(&comer);
    }
    firer.join();
    CHECK_EQ(steadyCalls.load(), rounds, "the steady callback: once per round");
    CHECK(comerCalls.load() <= rounds, "the coming and going one: at most once per round");
    CHECK(!list.contains(&comer) && list.contains(&steady), "ends as it was left");
}

int main(void) {
    @autoreleasepool {
        testAddRemove();
        testRound();
        testRemoveDuringRound();
        testAddDuringRound();
        testReentrantRound();
        testThreads();
    }
    TEST_MAIN_END();
}
