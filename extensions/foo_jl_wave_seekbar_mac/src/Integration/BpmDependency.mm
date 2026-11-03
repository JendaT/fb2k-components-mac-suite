//
//  BpmDependency.mm
//  foo_wave_seekbar_mac
//

#include "../fb2k_sdk.h"
#include "../../../../shared/jl_beatgrid_api.h"
#include "../Core/ConfigHelper.h"
#include "../Core/WaveformConfig.h"

#import "BpmDependency.h"

JLDependencyManager *waveseekBpmDependency(void) {
    static JLDependencyManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        JLDependencyDescriptor *d = [[JLDependencyDescriptor alloc] init];
        d.component = @"foo_jl_bpm";
        d.displayName = @"BPM Analyzer";
        d.tagPrefix = @"bpm-v";
        d.assetName = @"foo_jl_bpm.fb2k-component";
        d.minVersion = @"0.1.0";   // the first with grid sections (jl_beatgrid layout 2)
        d.repository = @"JendaT/fb2k-components-mac-suite";
        d.featureName = @"Phrase markers";
        d.dependentName = @"Waveform Seekbar";
        manager = [JLDependencyManager managerForDescriptor:d];
        manager.serviceAvailable = ^BOOL {
            jl_beatgrid::ptr grids;
            return fb2k::std_api_try_get(grids);
        };
        manager.preferencesPageGUID = @(pfc::print_guid(waveform_config::guid_preferences_page).c_str());
        // Installed for the phrase markers: switch them on
        manager.enableFeature = ^{
            waveform_config::setConfigBool(waveform_config::kKeyPhraseMarkers, true);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"WaveformSeekbarSettingsChanged" object:nil];
        };
    });
    return manager;
}
