#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface AlbumTrack : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *path;       // fb2k path (e.g. mac-volume://...)
@property (nonatomic, copy) NSString *duration;
@property (nonatomic, assign) NSInteger rating;
@property (nonatomic, assign) NSUInteger trackNumber;
@end

@interface AlbumItem : NSObject
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic, copy) NSString *year;
@property (nonatomic, copy) NSString *artPath;     // fb2k path of first track
@property (nonatomic, strong) NSMutableArray<AlbumTrack *> *tracks;
@property (nonatomic, assign) NSUInteger trackCount;
@property (nonatomic, assign) NSInteger rating;

@property (nonatomic, copy, readonly) NSString *groupKey;

- (NSArray<NSString *> *)allTrackPaths;
@end

NS_ASSUME_NONNULL_END
