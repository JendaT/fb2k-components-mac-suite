//
//  QueueDropParser.h
//  foo_jl_queue_manager
//
//  Decoding and validation of the SimPlaylist drag payload.
//
//  Foundation-only (no foobar2000 SDK, no AppKit) so it can be
//  unit-tested standalone. Extracted from QueueManagerController's
//  handleSimPlaylistDropFromPasteboard:. The payload is a keyed-archived
//  NSDictionary with @"sourcePlaylist" (NSNumber, optional), @"indices"
//  (NSArray of NSNumber, required) and optionally @"paths".
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QueueDropRequest : NSObject

// YES when the payload named its source playlist. When NO, the caller
// falls back to the active playlist.
@property (nonatomic, readonly) BOOL hasSourcePlaylist;
@property (nonatomic, readonly) NSUInteger sourcePlaylist;  // valid only if hasSourcePlaylist

// Row indices into the source playlist, as sent. Never empty.
@property (nonatomic, readonly) NSArray<NSNumber*>* indices;

// Decode a drag payload. Returns nil if the data is missing, is not a
// keyed-archived NSDictionary, or carries no indices.
+ (nullable instancetype)requestFromDragData:(nullable NSData*)data;

// The subset of indices that fall inside a playlist of itemCount items,
// in original order. Stale rows past the end are dropped.
- (NSArray<NSNumber*>*)indicesBelowItemCount:(NSUInteger)itemCount;

@end

NS_ASSUME_NONNULL_END
