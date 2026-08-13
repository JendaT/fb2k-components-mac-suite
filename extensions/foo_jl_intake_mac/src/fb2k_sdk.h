//
//  fb2k_sdk.h
//  foo_jl_intake
//
//  Common SDK header. Include THIS instead of <foobar2000/SDK/foobar2000.h>.
//
//  Deliberately does NOT define FOOBAR2000_HAVE_CFG_VAR_LEGACY: this component
//  is new code with no Windows ancestry, so it uses the modern configStore API
//  for persistence (suite convention, knowledge_base/08). Nothing here should
//  reach for cfg_var.
//

#pragma once

#include <foobar2000/SDK/foobar2000.h>
