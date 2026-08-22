//
//  fb2k_sdk.h
//  foo_jl_spectrum_mac
//
//  Common SDK header with macOS-specific configuration.
//  Include THIS file instead of <foobar2000/SDK/foobar2000.h> directly.
//

#pragma once

// Enable legacy cfg_var API for compatibility with Windows code
// MUST be defined BEFORE including SDK headers
#define FOOBAR2000_HAVE_CFG_VAR_LEGACY 1

// Include foobar2000 SDK
#include <foobar2000/SDK/foobar2000.h>
#include <foobar2000/SDK/vis.h>
