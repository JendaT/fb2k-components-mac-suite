//
//  BiographySource.h
//  foo_jl_biography_mac
//
//  Source enum shared by biography and gallery models.
//  Foundation-only so SDK-free Core code can use it without pulling in AppKit.
//

#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, BiographySource) {
    BiographySourceUnknown = 0,
    BiographySourceLastFm,
    BiographySourceWikipedia,
    BiographySourceAudioDb,
    BiographySourceFanartTv,
    BiographySourceDeezer,
    BiographySourceCache
};
