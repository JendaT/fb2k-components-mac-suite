//
//  BpmResultsWindowController.h
//  foo_jl_bpm_mac
//
//  Review window for an "Analyze BPM" run: current tag, new value, where it
//  came from and how it compares, with Double/Halve for half/double tempo
//  mistakes. Tags are written only from here, and only for checked rows.
//

#pragma once

#import <Cocoa/Cocoa.h>

#include <memory>

namespace bpm {
struct AnalysisJob;
}

NS_ASSUME_NONNULL_BEGIN

@interface BpmResultsWindowController : NSWindowController

// Main thread. The window keeps itself alive until closed.
+ (void)showResultsForJob:(std::shared_ptr<bpm::AnalysisJob>)job;

@end

NS_ASSUME_NONNULL_END
