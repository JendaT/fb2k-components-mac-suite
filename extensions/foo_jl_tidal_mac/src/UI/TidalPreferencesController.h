//
//  TidalPreferencesController.h
//  foo_jl_tidal_mac
//
//  Preferences page for Tidal configuration
//

#pragma once

#import <Cocoa/Cocoa.h>

@interface JLTidalPreferencesController : NSViewController

/// Reconnect button shown when token is expired
@property (nonatomic, strong, readonly) NSButton *reconnectButton;

@end
