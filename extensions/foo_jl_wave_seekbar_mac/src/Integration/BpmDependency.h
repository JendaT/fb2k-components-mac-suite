//
//  BpmDependency.h
//  foo_wave_seekbar_mac
//
//  BPM Analyzer as the dependency of the phrase markers: installed from the
//  preferences (JLDependencyGate) when it is missing or too old.
//

#pragma once

#import "../../../../shared/jl_dependency/JLDependencyGate.h"

// The manager for BPM Analyzer, configured for this component
JLDependencyManager *waveseekBpmDependency(void);
