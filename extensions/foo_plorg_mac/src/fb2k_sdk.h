//
//  fb2k_sdk.h
//  foo_plorg_mac
//
//  Common SDK header with macOS-specific configuration
//

#pragma once

// Enable legacy cfg_var API for compatibility
#define FOOBAR2000_HAVE_CFG_VAR_LEGACY 1

// Include foobar2000 SDK
#include <foobar2000/SDK/foobar2000.h>

// Note: Use fb2k::configStore for persistent configuration on macOS
// cfg_var doesn't persist reliably on macOS
