//
//  QueueManagerController.h
//  foo_jl_queue_manager
//
//  Main view controller for Queue Manager UI element
//

#pragma once

#import <Cocoa/Cocoa.h>

@class QueueItemWrapper;

@interface QueueManagerController : NSViewController <NSTableViewDataSource, NSTableViewDelegate>

// Main views
@property (nonatomic, strong) NSScrollView* scrollView;
@property (nonatomic, strong) NSTableView* tableView;
@property (nonatomic, strong) NSTextField* statusBar;

// Data
@property (nonatomic, strong) NSMutableArray<QueueItemWrapper*>* queueItems;

// State flags
@property (nonatomic) BOOL isReorderingInProgress;
@property (nonatomic) BOOL transparentBackground;

// Reload queue contents from SDK
- (void)reloadQueueContents;

// Remove selected items from queue
- (void)removeSelectedItems;

// Play selected item (double-click action)
- (void)playSelectedItem;

@end
