//
//  QueueDropParser.mm
//  foo_jl_queue_manager
//
//  SimPlaylist drag payload decoding — see QueueDropParser.h.
//  Behavior moved from QueueManagerController; unchanged.
//

#import "QueueDropParser.h"

@implementation QueueDropRequest

+ (nullable instancetype)requestFromDragData:(nullable NSData*)data {
    if (!data) return nil;

    NSSet* classes = [NSSet setWithObjects:[NSDictionary class], [NSArray class],
                      [NSNumber class], [NSString class], nil];
    NSError* error = nil;
    id decoded = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                     fromData:data
                                                        error:&error];
    if (!decoded || ![decoded isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary* dragData = decoded;

    id indices = dragData[@"indices"];
    if (![indices isKindOfClass:[NSArray class]] || [indices count] == 0) {
        return nil;
    }
    for (id entry in (NSArray*)indices) {
        if (![entry isKindOfClass:[NSNumber class]]) {
            return nil;
        }
    }

    QueueDropRequest* request = [[QueueDropRequest alloc] init];
    request->_indices = [indices copy];

    id sourcePlaylist = dragData[@"sourcePlaylist"];
    if ([sourcePlaylist isKindOfClass:[NSNumber class]]) {
        request->_hasSourcePlaylist = YES;
        request->_sourcePlaylist = [sourcePlaylist unsignedLongValue];
    }

    return request;
}

- (NSArray<NSNumber*>*)indicesBelowItemCount:(NSUInteger)itemCount {
    NSMutableArray<NSNumber*>* valid = [NSMutableArray arrayWithCapacity:_indices.count];
    for (NSNumber* rowNum in _indices) {
        if ([rowNum unsignedLongValue] < itemCount) {
            [valid addObject:rowNum];
        }
    }
    return valid;
}

@end
