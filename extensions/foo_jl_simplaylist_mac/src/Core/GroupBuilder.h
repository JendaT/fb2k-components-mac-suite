//
//  GroupBuilder.h
//  foo_simplaylist_mac
//
//  The group/subgroup detection loop, shared by all four detection code paths
//  in SimPlaylistController (sync partial scan, background continuation, full
//  background scan, background cache validation). Previously quadruplicated
//  with drift risk; SDK-free (callback-fed) so it is unit-testable standalone.
//

#pragma once

#import <Foundation/Foundation.h>

#include <functional>
#include <string>

#include "SubgroupDetector.h"

namespace simplaylist {

struct GroupBuildCallbacks {
    // Return the formatted header / subgroup / album-art key for track i.
    // Returned pointers only need to stay valid until the next callback
    // invocation (callers typically return .c_str() of one reused buffer).
    std::function<const char *(size_t index)> formatHeader;
    // Optional boundary-detection key. When set, group breaks are detected on
    // this key instead of the header text (a multi-artist album keeps one
    // group even though per-track headers differ) and formatHeader is only
    // invoked for the first track of each group.
    std::function<const char *(size_t index)> formatGroupKey;
    std::function<const char *(size_t index)> formatSubgroup;  // required iff hasSubgroups
    std::function<const char *(size_t index)> artKey;
    // Optional cooperative cancellation, checked once per track before any
    // formatting. When it returns true the build aborts and buildGroups
    // returns false (partial output must be discarded by the caller).
    std::function<bool()> isCancelled;
};

// Appends groups/subgroups detected for tracks [begin, end) to the output
// arrays. `currentKey` and `detector` carry state across chunked
// invocations (the background continuation passes the sync scan's final
// values); it holds the last group's boundary key — the header text unless
// formatGroupKey is set. `forceFirstNewGroup` reproduces the "index 0 always
// starts a group" rule of from-scratch scans — even when its key equals the
// seeded currentKey — and must be false for continuations.
// Returns false if cancelled.
inline bool buildGroups(size_t begin, size_t end,
                        bool hasSubgroups,
                        bool forceFirstNewGroup,
                        std::string &currentKey,
                        SubgroupDetector &detector,
                        const GroupBuildCallbacks &cb,
                        NSMutableArray<NSNumber *> *groupStarts,
                        NSMutableArray<NSString *> *groupHeaders,
                        NSMutableArray<NSString *> *groupArtKeys,
                        NSMutableArray<NSNumber *> *subgroupStarts,
                        NSMutableArray<NSString *> *subgroupHeaders) {
    for (size_t i = begin; i < end; i++) { @autoreleasepool {
        if (cb.isCancelled && cb.isCancelled()) return false;

        const char *key = cb.formatGroupKey ? cb.formatGroupKey(i) : cb.formatHeader(i);
        bool isNewGroup = (forceFirstNewGroup && i == begin) || (currentKey != key);

        if (isNewGroup) {
            currentKey = key;  // copy before formatHeader may reuse the key's buffer
            const char *header = cb.formatGroupKey ? cb.formatHeader(i) : currentKey.c_str();
            // stringWithUTF8String: returns nil on invalid UTF-8 in tags;
            // addObject:nil would throw on a background thread. A NULL is worse
            // still - stringWithUTF8String:NULL is undefined, and the SDK's
            // get_path() behind artKey has no non-NULL guarantee.
            const char *art = cb.artKey(i);
            [groupStarts addObject:@(i)];
            [groupHeaders addObject:([NSString stringWithUTF8String:header] ?: @"")];
            [groupArtKeys addObject:(art ? ([NSString stringWithUTF8String:art] ?: @"") : @"")];
            detector.enterNewGroup();
        }

        if (hasSubgroups) {
            detector.shouldAddSubgroup(cb.formatSubgroup(i), isNewGroup,
                                       subgroupStarts, subgroupHeaders, i);
        }
    }}
    return true;
}

}  // namespace simplaylist
