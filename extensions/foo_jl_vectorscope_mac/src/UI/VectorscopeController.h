//
//  VectorscopeController.h
//  foo_jl_vectorscope_mac
//
//  NSViewController hosting the vectorscope view; drives the display timer.
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "VectorscopeView.h"

NS_ASSUME_NONNULL_BEGIN

@interface VectorscopeController : NSViewController <VectorscopeViewDelegate>

@property (nonatomic, readonly) VectorscopeView *scopeView;

@end

NS_ASSUME_NONNULL_END
