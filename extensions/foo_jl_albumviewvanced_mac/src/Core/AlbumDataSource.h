#pragma once

#import <Cocoa/Cocoa.h>

@class AlbumItem;

NS_ASSUME_NONNULL_BEGIN

@protocol AlbumDataSourceDelegate <NSObject>
- (void)albumDataSourceDidBeginUpdate;
- (void)albumDataSourceDidUpdate;
@end

@interface AlbumDataSource : NSObject

@property (nonatomic, weak) id<AlbumDataSourceDelegate> delegate;
@property (nonatomic, readonly) NSArray<AlbumItem *> *albums;
@property (nonatomic, readonly) NSUInteger totalTrackCount;

- (void)rebuildWithFilter:(nullable NSString *)filterQuery;

@end

NS_ASSUME_NONNULL_END
