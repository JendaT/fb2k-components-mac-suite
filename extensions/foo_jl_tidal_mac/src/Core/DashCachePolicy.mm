//
//  DashCachePolicy.mm
//  foo_jl_tidal_mac
//

#import "DashCachePolicy.h"

@implementation JLTidalDashCachePolicy

+ (NSArray<NSString *> *)segmentURLsForTemplate:(NSString *)mediaTemplate
                                          count:(NSInteger)count {
    if (count <= 0 || ![mediaTemplate containsString:@"$Number$"]) {
        return @[];
    }
    NSMutableArray<NSString *> *urls = [NSMutableArray arrayWithCapacity:count];
    for (NSInteger i = 0; i < count; i++) {
        NSString *url = [mediaTemplate
            stringByReplacingOccurrencesOfString:@"$Number$"
                                      withString:[NSString stringWithFormat:@"%ld", (long)i]];
        [urls addObject:url];
    }
    return [urls copy];
}

+ (NSArray<NSString *> *)evictionKeysForOrder:(NSArray<NSString *> *)order
                                        sizes:(NSDictionary<NSString *, NSNumber *> *)sizes
                                     capBytes:(long long)capBytes {
    long long total = 0;
    for (NSString *key in order) {
        total += sizes[key].longLongValue;
    }

    NSMutableArray<NSString *> *evict = [NSMutableArray array];
    NSUInteger i = 0;
    // Evict from the oldest end until under cap, but always keep the newest
    // (last) entry so a single oversized blob is never dropped.
    while (total > capBytes && (order.count - evict.count) > 1 && i < order.count) {
        NSString *key = order[i];
        [evict addObject:key];
        total -= sizes[key].longLongValue;
        i++;
    }
    return [evict copy];
}

@end
