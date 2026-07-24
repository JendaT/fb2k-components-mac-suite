//
//  TidalProvider.h
//  foo_jl_album_art_mac
//
//  TIDAL API provider (front covers via the official TIDAL developer API)
//
//  Requires OAuth2 client credentials from https://developer.tidal.com.
//  The provider is inactive (isConfigured == NO) until the user supplies
//  credentials; the search controller then skips it automatically.
//

#pragma once

#import <Foundation/Foundation.h>
#import "ArtworkSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// NSUserDefaults keys for TIDAL client credentials
extern NSString *const kTidalClientIDDefaultsKey;
extern NSString *const kTidalClientSecretDefaultsKey;

@interface TidalProvider : ArtworkSourceProviderBase

+ (TidalProvider *)sharedInstance;

/// YES when both client ID and secret are present in NSUserDefaults
@property (readonly, getter=isConfigured) BOOL configured;

@end

NS_ASSUME_NONNULL_END
