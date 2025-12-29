//
//  fb2k_sdk.h
//  foo_jl_queue_manager
//
//  Common SDK header with macOS-specific configuration
//  Include THIS file instead of <foobar2000/SDK/foobar2000.h> directly
//

#pragma once

// Enable legacy cfg_var API for compatibility with Windows code
// MUST be defined BEFORE including SDK headers
#define FOOBAR2000_HAVE_CFG_VAR_LEGACY 1

// Include foobar2000 SDK
#include <foobar2000/SDK/foobar2000.h>

// Note: Use cfg_var_legacy:: prefix explicitly for cfg_int, cfg_bool, etc.
// to avoid ambiguity with cfg_var_modern types from SDK's cfg_var.h
