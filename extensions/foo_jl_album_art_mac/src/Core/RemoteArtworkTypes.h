//
//  RemoteArtworkTypes.h
//  foo_jl_album_art_mac
//
//  Type definitions for remote artwork fetching
//  Separated from local ArtworkType to avoid conflicts
//
//  Foundation-only: keep free of SDK imports so the remote-search Core
//  compiles standalone for unit tests. The SDK mapping lives in
//  ArtworkEmbedController.mm.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Remote Artwork Type Enum

/// Artwork types returned from remote sources
/// Named "Remote" to distinguish from albumart_config::ArtworkType
typedef NS_ENUM(NSInteger, RemoteArtworkType) {
    RemoteArtworkTypeFront = 0,
    RemoteArtworkTypeBack,
    RemoteArtworkTypeDisc,
    RemoteArtworkTypeIcon,
    RemoteArtworkTypeArtist,
    RemoteArtworkTypeBooklet,   // Extended - not in local SDK enum
    RemoteArtworkTypeOther
};

/// Get short name for remote artwork type (for filter buttons)
static inline NSString *RemoteArtworkTypeName(RemoteArtworkType type) {
    switch (type) {
        case RemoteArtworkTypeFront:   return @"Front";
        case RemoteArtworkTypeBack:    return @"Back";
        case RemoteArtworkTypeDisc:    return @"Disc";
        case RemoteArtworkTypeIcon:    return @"Icon";
        case RemoteArtworkTypeArtist:  return @"Artist";
        case RemoteArtworkTypeBooklet: return @"Booklet";
        case RemoteArtworkTypeOther:   return @"Other";
    }
}

/// Get display name for remote artwork type (full name for info labels)
static inline NSString *RemoteArtworkTypeDisplayName(RemoteArtworkType type) {
    switch (type) {
        case RemoteArtworkTypeFront:   return @"Front Cover";
        case RemoteArtworkTypeBack:    return @"Back Cover";
        case RemoteArtworkTypeDisc:    return @"Disc";
        case RemoteArtworkTypeIcon:    return @"Icon";
        case RemoteArtworkTypeArtist:  return @"Artist";
        case RemoteArtworkTypeBooklet: return @"Booklet";
        case RemoteArtworkTypeOther:   return @"Other";
    }
}

/// Get short name for filenames (front.jpg, back.jpg, etc.)
static inline NSString *RemoteArtworkTypeFilename(RemoteArtworkType type) {
    switch (type) {
        case RemoteArtworkTypeFront:   return @"front";
        case RemoteArtworkTypeBack:    return @"back";
        case RemoteArtworkTypeDisc:    return @"disc";
        case RemoteArtworkTypeIcon:    return @"icon";
        case RemoteArtworkTypeArtist:  return @"artist";
        case RemoteArtworkTypeBooklet: return @"booklet";
        case RemoteArtworkTypeOther:   return @"artwork";
    }
}

#pragma mark - Error Domain

/// Error domain for artwork fetch operations
extern NSString *const ArtworkFetchErrorDomain;

/// Error codes for artwork fetch operations
typedef NS_ENUM(NSInteger, ArtworkFetchError) {
    // Network errors (1xxx)
    ArtworkFetchErrorNetworkUnavailable = 1001,
    ArtworkFetchErrorTimeout = 1002,
    ArtworkFetchErrorAPIError = 1003,
    ArtworkFetchErrorRateLimited = 1004,
    ArtworkFetchErrorNoResults = 1005,
    ArtworkFetchErrorInvalidMetadata = 1006,

    // Save errors (2xxx)
    ArtworkFetchErrorSaveFailed = 2001,
    ArtworkFetchErrorFileReadOnly = 2002,
    ArtworkFetchErrorEmbedFailed = 2003,
    ArtworkFetchErrorImageTooLarge = 2004,
};

NS_ASSUME_NONNULL_END
