//
//  pfc_debug.cpp
//  foo_jl_album_art_mac
//
//  Required stubs for pfc debug functions
//

#include <pfc/pfc.h>

#if PFC_DEBUG
void pfc::selftest::print(const char* msg) {
    (void)msg;
}
#endif
