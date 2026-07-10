//
//  QueueDropParserTests.mm
//  foo_jl_queue_manager
//
//  Unit tests for QueueDropParser (SimPlaylist drag payload decoding).
//  Payloads are built with NSKeyedArchiver exactly as SimPlaylist sends
//  them. Foundation-only, compiled standalone; run as a gating phase by
//  Scripts/build.sh.
//

#import "../src/Core/QueueDropParser.h"

#import <Foundation/Foundation.h>
#include <cstdio>

static int g_failures = 0;
static int g_checks = 0;

static void check(bool condition, const char* name, NSString* detail) {
    g_checks++;
    if (!condition) {
        g_failures++;
        printf("FAIL [%s] %s\n", name, detail.UTF8String ?: "");
    }
}

static NSData* archive(id object) {
    return [NSKeyedArchiver archivedDataWithRootObject:object
                                 requiringSecureCoding:YES
                                                 error:nil];
}

int main() {
    @autoreleasepool {
        // Full payload: sourcePlaylist + indices (+ optional paths)
        {
            NSData* data = archive(@{@"sourcePlaylist": @3,
                                     @"indices": @[@0, @5, @12],
                                     @"paths": @[@"/a.flac", @"/b.flac", @"/c.flac"]});
            QueueDropRequest* req = [QueueDropRequest requestFromDragData:data];
            check(req != nil, "full-payload-decodes", @"request is nil");
            check(req.hasSourcePlaylist, "full-payload-has-playlist", @"");
            check(req.sourcePlaylist == 3, "full-payload-playlist-value",
                  [NSString stringWithFormat:@"got %lu", (unsigned long)req.sourcePlaylist]);
            NSArray* want = @[@0, @5, @12];
            check([req.indices isEqualToArray:want], "full-payload-indices",
                  [NSString stringWithFormat:@"got %@", req.indices]);
        }

        // Payload without sourcePlaylist: caller falls back to active playlist
        {
            NSData* data = archive(@{@"indices": @[@1, @2]});
            QueueDropRequest* req = [QueueDropRequest requestFromDragData:data];
            check(req != nil, "no-playlist-decodes", @"request is nil");
            check(!req.hasSourcePlaylist, "no-playlist-flag", @"hasSourcePlaylist should be NO");
        }

        // Stale rows past the playlist end are filtered, order preserved
        {
            NSData* data = archive(@{@"sourcePlaylist": @0,
                                     @"indices": @[@9, @2, @10, @0]});
            QueueDropRequest* req = [QueueDropRequest requestFromDragData:data];
            NSArray* valid = [req indicesBelowItemCount:10];
            NSArray* want = @[@9, @2, @0];
            check([valid isEqualToArray:want], "filter-stale-rows",
                  [NSString stringWithFormat:@"got %@", valid]);
            check([req indicesBelowItemCount:0].count == 0, "filter-empty-playlist", @"");
            check([[req indicesBelowItemCount:11] isEqualToArray:req.indices],
                  "filter-all-valid", @"");
        }

        // Invalid payloads are rejected
        {
            check([QueueDropRequest requestFromDragData:nil] == nil,
                  "reject-nil-data", @"");
            check([QueueDropRequest requestFromDragData:[NSData data]] == nil,
                  "reject-empty-data", @"");
            check([QueueDropRequest requestFromDragData:
                   [@"garbage" dataUsingEncoding:NSUTF8StringEncoding]] == nil,
                  "reject-garbage-data", @"");
            check([QueueDropRequest requestFromDragData:archive(@[@1, @2])] == nil,
                  "reject-non-dictionary", @"");
            check([QueueDropRequest requestFromDragData:archive(@{@"sourcePlaylist": @1})] == nil,
                  "reject-missing-indices", @"");
            check([QueueDropRequest requestFromDragData:archive(@{@"indices": @[]})] == nil,
                  "reject-empty-indices", @"");
            check([QueueDropRequest requestFromDragData:
                   archive(@{@"indices": @"not-an-array"})] == nil,
                  "reject-indices-wrong-type", @"");
            check([QueueDropRequest requestFromDragData:
                   archive(@{@"indices": @[@1, @"two"]})] == nil,
                  "reject-non-numeric-index", @"");
        }

        // Negative indices wrap to huge unsigned values and must be filtered
        // by the item-count bound (load-bearing for hostile/buggy payloads)
        {
            NSData* data = archive(@{@"indices": @[@(-1), @2]});
            QueueDropRequest* req = [QueueDropRequest requestFromDragData:data];
            check(req != nil, "negative-index-decodes", @"request is nil");
            NSArray* valid = [req indicesBelowItemCount:10];
            check([valid isEqualToArray:@[@2]], "negative-index-filtered",
                  [NSString stringWithFormat:@"got %@", valid]);
        }

        // Duplicate indices pass through unchanged (caller adds twice)
        {
            NSData* data = archive(@{@"indices": @[@3, @3]});
            QueueDropRequest* req = [QueueDropRequest requestFromDragData:data];
            check([[req indicesBelowItemCount:10] isEqualToArray:@[@3, @3]],
                  "duplicate-indices-preserved", @"");
        }

        // Non-numeric sourcePlaylist degrades to the fallback, not a crash
        {
            NSData* data = archive(@{@"sourcePlaylist": @"three",
                                     @"indices": @[@1]});
            QueueDropRequest* req = [QueueDropRequest requestFromDragData:data];
            check(req != nil, "string-playlist-decodes", @"request is nil");
            check(!req.hasSourcePlaylist, "string-playlist-ignored", @"");
        }
    }

    if (g_failures) {
        printf("QueueDropParserTests: %d/%d checks FAILED\n", g_failures, g_checks);
        return 1;
    }
    printf("QueueDropParserTests: all %d checks passed\n", g_checks);
    return 0;
}
