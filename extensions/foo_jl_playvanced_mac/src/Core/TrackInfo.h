#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TrackInfo : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy) NSString *albumArtist;
@property (nonatomic, copy) NSString *date;
@property (nonatomic, copy) NSString *genre;
@property (nonatomic, copy) NSString *trackNumber;
@property (nonatomic, copy) NSString *discNumber;
@property (nonatomic, copy) NSString *codec;
@property (nonatomic, copy) NSString *bitrate;
@property (nonatomic, copy) NSString *sampleRate;
@property (nonatomic, copy) NSString *channels;
@property (nonatomic, copy) NSString *duration;
@property (nonatomic, copy) NSString *rating;
@property (nonatomic, copy) NSString *path;

@end

NS_ASSUME_NONNULL_END
