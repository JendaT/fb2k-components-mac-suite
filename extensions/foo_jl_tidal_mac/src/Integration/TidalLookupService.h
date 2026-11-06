//
//  TidalLookupService.h
//  foo_jl_tidal_mac
//
//  Implements jl_tidal_lookup (shared/jl_tidal_api.h): tempo and key from
//  the TIDAL catalogue for any track, for other components to ask for.
//

#pragma once

namespace tidal {

// Drops queued lookups without notifying and writes the cache to disk.
// Called from initquit::on_quit, before the API session is torn down.
void shutdownLookupService();

} // namespace tidal
