//
//  PlorgOutlineView.h
//  foo_plorg_mac
//
//  Custom NSOutlineView subclass to forward drag lifecycle callbacks
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PlorgOutlineViewDelegate <NSOutlineViewDelegate>
@optional
- (void)outlineView:(NSOutlineView *)outlineView draggingEntered:(id<NSDraggingInfo>)sender;
- (void)outlineView:(NSOutlineView *)outlineView draggingExited:(id<NSDraggingInfo>)sender;
- (void)outlineView:(NSOutlineView *)outlineView draggingEnded:(id<NSDraggingInfo>)sender;
@end

@interface PlorgOutlineView : NSOutlineView
@end

NS_ASSUME_NONNULL_END
