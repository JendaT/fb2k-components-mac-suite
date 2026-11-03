#pragma once

//
// jl_dependency_names.h - per-component Objective-C class names.
//
// Every dependent compiles jl_dependency into its own binary, and
// Objective-C class names are global to the process: two components with a
// class of the same name get one arbitrary implementation for both. So each
// component defines JL_DEPENDENCY_PREFIX (an identifier, e.g. WaveSeek)
// before any jl_dependency header, in every file that includes one; the
// classes below then become WaveSeekComponentInstaller and so on.
//

#ifndef JL_DEPENDENCY_PREFIX
#error "Define JL_DEPENDENCY_PREFIX (a class name prefix unique to this component) before including jl_dependency headers"
#endif

#define JL_DEPENDENCY_CAT2(a, b) a##b
#define JL_DEPENDENCY_CAT(a, b) JL_DEPENDENCY_CAT2(a, b)

#define JLDependencyDescriptor JL_DEPENDENCY_CAT(JL_DEPENDENCY_PREFIX, DependencyDescriptor)
#define JLReleaseInfo JL_DEPENDENCY_CAT(JL_DEPENDENCY_PREFIX, ReleaseInfo)
#define JLComponentInstaller JL_DEPENDENCY_CAT(JL_DEPENDENCY_PREFIX, ComponentInstaller)
#define JLDependencyManager JL_DEPENDENCY_CAT(JL_DEPENDENCY_PREFIX, DependencyManager)
#define JLDependencyGate JL_DEPENDENCY_CAT(JL_DEPENDENCY_PREFIX, DependencyGate)
