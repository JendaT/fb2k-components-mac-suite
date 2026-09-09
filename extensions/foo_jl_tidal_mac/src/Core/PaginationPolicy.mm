//
//  PaginationPolicy.mm
//  foo_jl_tidal_mac
//

#import "PaginationPolicy.h"

@implementation JLTidalPaginationPolicy

+ (JLTidalPageAction)actionAfterPageCount:(NSInteger)pageCount
                              accumulated:(NSInteger)accumulated
                                    limit:(NSInteger)limit
                                  ceiling:(NSInteger)ceiling {
    // Defensive: a non-positive limit cannot page; treat the single
    // response as the whole collection.
    if (limit <= 0) return JLTidalPageActionDone;
    if (pageCount < limit) return JLTidalPageActionDone;
    if (accumulated >= ceiling) return JLTidalPageActionFailCeiling;
    return JLTidalPageActionContinue;
}

@end
