//
//  TidalGuidProbe.h
//  foo_jl_tidal_mac
//
//  Temporary probe: are playlist_manager_v5 GUIDs a reliable persistent
//  playlist identity? Gated by the hidden option tidal.TI_guid_probe, see
//  docs/hidden-options.md and docs/design/2026-11-05-playlist-guid-brief.md.
//

#pragma once

namespace tidal {

// Call once from initquit::on_init. Does nothing unless tidal.TI_guid_probe
// is 1 (run A) or 2 (run B); the run then starts about 3 s later on the main
// queue.
void scheduleGuidProbeIfArmed();

} // namespace tidal
