//
//  fb2k_sdk.h
//  foo_simplaylist_mac
//
//  SDK include wrapper for foobar2000 macOS
//

#pragma once

// foobar2000 SDK
#include <foobar2000/SDK/foobar2000.h>

// macOS/Cocoa (when included from .mm files)
#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#endif
