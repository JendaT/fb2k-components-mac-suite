//
//  TidalAPIPrivate.h
//  foo_jl_tidal_mac
//
//  Session-writer interface for JLTidalAPI. Import only from
//  JLTidalAuthService (and TidalAPI.mm itself).
//

#pragma once

#import "TidalAPI.h"

NS_ASSUME_NONNULL_BEGIN

/// Session ownership: JLTidalAuthService is the sole writer of the API
/// session. All other code reads JLTidalAPI.session (readonly).
@interface JLTidalAPI (SessionOwner)

- (void)updateSession:(nullable JLTidalSession *)session;

@end

NS_ASSUME_NONNULL_END
