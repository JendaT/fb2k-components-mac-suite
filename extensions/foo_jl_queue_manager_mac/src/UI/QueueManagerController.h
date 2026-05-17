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

- (void)reloadQueueContents;
- (void)removeSelectedItems;
- (void)playSelectedItem;

- (void)handlePlaybackNewTrack;
- (void)handlePlaybackStop;
- (void)handlePlaybackPause:(BOOL)paused;

@end
