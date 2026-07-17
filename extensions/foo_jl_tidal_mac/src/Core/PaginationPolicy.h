//
//  PaginationPolicy.h
//  foo_jl_tidal_mac
//
//  Pure decision logic for paging through Tidal collection endpoints.
//  Foundation-only — no SDK, no network — unit-tested standalone
//  (Tests/PaginationPolicyTests.mm). JLTidalAPI owns the request loop.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, JLTidalPageAction) {
    JLTidalPageActionDone,         // Short page: collection is complete
    JLTidalPageActionContinue,     // Full page: fetch next page at offset == accumulated
    JLTidalPageActionFailCeiling,  // Too many items: fail the whole fetch
};

@interface JLTidalPaginationPolicy : NSObject

/// Decide what to do after receiving one page. `accumulated` includes the
/// page just received. A short page (pageCount < limit) completes the
/// collection. A full page with accumulated >= ceiling fails the entire
/// fetch: a truncated list must never be returned as if complete, because
/// the sync engine would plan destructive changes against the missing tail.
+ (JLTidalPageAction)actionAfterPageCount:(NSInteger)pageCount
                              accumulated:(NSInteger)accumulated
                                    limit:(NSInteger)limit
                                  ceiling:(NSInteger)ceiling;

@end

NS_ASSUME_NONNULL_END
