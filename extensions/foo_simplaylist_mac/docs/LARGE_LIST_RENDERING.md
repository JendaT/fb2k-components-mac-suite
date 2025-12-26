# Large List Rendering: Optimization Strategies for Grouped Playlists

## Executive Summary

This document provides a comprehensive analysis of techniques for efficiently rendering large grouped playlists (10,000-100,000+ tracks) in AppKit. The current implementation faces performance bottlenecks when dealing with grouped playlists containing thousands of tracks. This guide presents multiple solution paths with complexity/performance tradeoffs.

## Table of Contents

1. [Current Implementation Analysis](#current-implementation-analysis)
2. [Core Problem: Variable Height Row Lookup](#core-problem-variable-height-row-lookup)
3. [Solution 1: Fenwick Tree (Binary Indexed Tree)](#solution-1-fenwick-tree-binary-indexed-tree)
4. [Solution 2: Segment Tree](#solution-2-segment-tree)
5. [Solution 3: Sparse Boundary Model (Current Partial)](#solution-3-sparse-boundary-model)
6. [Solution 4: Jump Pointer / Level Ancestor](#solution-4-jump-pointer--level-ancestor)
7. [Rendering Pipeline Optimizations](#rendering-pipeline-optimizations)
8. [Memory Optimization Strategies](#memory-optimization-strategies)
9. [Incremental Update Strategies](#incremental-update-strategies)
10. [GPU Acceleration with CALayer](#gpu-acceleration-with-calayer)
11. [Recommended Implementation Path](#recommended-implementation-path)
12. [References](#references)

---

## Current Implementation Analysis

### Architecture Overview

The current `SimPlaylistView` uses a **custom NSView** with manual drawing (`drawRect:`) rather than `NSTableView` or `NSOutlineView`. This provides maximum control but requires implementing all optimization techniques manually.

**Key Components:**
- `GroupNode` array - O(n) memory for all rows (headers, subgroups, tracks)
- `GroupBoundary` array - O(groups) sparse representation (partially implemented)
- `rowYOffsets` cache - O(n) array for row position lookup
- Binary search for visible row calculation

### Current Performance Characteristics

| Operation | Current Complexity | Target Complexity |
|-----------|-------------------|-------------------|
| Build node list | O(n) | O(n) - unavoidable |
| Find row at Y | O(log n) | O(log n) - OK |
| Find Y for row | O(1) with cache | O(log n) acceptable |
| Update single row | O(n) rebuild | O(log n) |
| Insert/remove rows | O(n) rebuild | O(log n) |
| Scroll (visible rows) | O(visible) | O(visible) - OK |

### Identified Bottlenecks

1. **Full GroupNode Array Creation**: Creating O(n) `GroupNode` objects for 50,000 tracks = 50,000+ allocations
2. **Cache Invalidation**: Any playlist change triggers full rebuild
3. **Album Art Selection Detection**: O(group_size) loop per visible group to find selected tracks
4. **Column Value Formatting**: Per-visible-row per-frame, no prefetch

---

## Core Problem: Variable Height Row Lookup

The fundamental challenge with grouped playlists is **variable row heights**:
- Headers: 28pt
- Subgroups: 24pt
- Tracks: 22pt

Given scroll position Y, we need to find which row is visible. With uniform heights this is O(1): `row = floor(Y / rowHeight)`. With variable heights, we need data structures.

### The Two Core Queries

1. **Position-to-Row**: Given scroll offset Y, find the first visible row
2. **Row-to-Position**: Given row index, find its Y offset

Both require **prefix sum** operations over row heights.

---

## Solution 1: Fenwick Tree (Binary Indexed Tree)

### Overview

A Fenwick Tree (Binary Indexed Tree) provides O(log n) operations for:
- Point updates (change one row's height)
- Prefix sum queries (total height up to row N)

### Data Structure

```cpp
class FenwickTree {
    std::vector<int> tree;  // 1-indexed
    int n;

public:
    FenwickTree(int size) : n(size), tree(size + 1, 0) {}

    // Update height at index i by delta
    void update(int i, int delta) {
        for (++i; i <= n; i += i & (-i))
            tree[i] += delta;
    }

    // Get prefix sum (total height from row 0 to row i-1)
    int prefixSum(int i) const {
        int sum = 0;
        for (; i > 0; i -= i & (-i))
            sum += tree[i];
        return sum;
    }

    // Binary search: find first row where prefix sum >= target
    int findRow(int targetY) const {
        int pos = 0;
        int sum = 0;
        for (int pw = 1 << (int)log2(n); pw > 0; pw >>= 1) {
            if (pos + pw <= n && sum + tree[pos + pw] < targetY) {
                pos += pw;
                sum += tree[pos];
            }
        }
        return pos;
    }
};
```

### Integration with SimPlaylistView

```objc
@interface SimPlaylistView ()
@property (nonatomic) std::unique_ptr<FenwickTree> heightTree;
@property (nonatomic, assign) NSInteger totalRowCount;
@end

- (void)rebuildHeightTree {
    _heightTree = std::make_unique<FenwickTree>(_totalRowCount);

    for (NSInteger i = 0; i < self.nodes.count; i++) {
        GroupNode *node = self.nodes[i];
        int height = [self heightForNodeType:node.type];
        _heightTree->update((int)i, height);
    }
}

- (NSInteger)rowAtPoint:(NSPoint)point {
    if (!_heightTree) return NSNotFound;
    return _heightTree->findRow((int)point.y);
}

- (CGFloat)yOffsetForRow:(NSInteger)row {
    if (!_heightTree || row < 0) return 0;
    return _heightTree->prefixSum((int)row);
}
```

### Complexity Analysis

| Operation | Complexity |
|-----------|------------|
| Build tree | O(n log n) |
| Query row at Y | O(log n) |
| Query Y for row | O(log n) |
| Update single height | O(log n) |
| Space | O(n) |

### When to Use

- Frequent single-row updates (collapse/expand)
- Moderate query frequency
- Simple implementation requirements

---

## Solution 2: Segment Tree

### Overview

Segment trees provide similar O(log n) operations but with more flexibility for range queries and lazy propagation.

### Data Structure

```cpp
class SegmentTree {
    std::vector<int> tree;
    int n;

    void build(const std::vector<int>& heights, int node, int start, int end) {
        if (start == end) {
            tree[node] = heights[start];
        } else {
            int mid = (start + end) / 2;
            build(heights, 2*node, start, mid);
            build(heights, 2*node+1, mid+1, end);
            tree[node] = tree[2*node] + tree[2*node+1];
        }
    }

public:
    SegmentTree(const std::vector<int>& heights) : n(heights.size()) {
        tree.resize(4 * n);
        if (n > 0) build(heights, 1, 0, n-1);
    }

    // Range sum query [l, r]
    int query(int node, int start, int end, int l, int r) {
        if (r < start || end < l) return 0;
        if (l <= start && end <= r) return tree[node];
        int mid = (start + end) / 2;
        return query(2*node, start, mid, l, r) +
               query(2*node+1, mid+1, end, l, r);
    }

    int prefixSum(int idx) {
        return query(1, 0, n-1, 0, idx);
    }

    // Point update
    void update(int node, int start, int end, int idx, int val) {
        if (start == end) {
            tree[node] = val;
        } else {
            int mid = (start + end) / 2;
            if (idx <= mid)
                update(2*node, start, mid, idx, val);
            else
                update(2*node+1, mid+1, end, idx, val);
            tree[node] = tree[2*node] + tree[2*node+1];
        }
    }
};
```

### Advantages Over Fenwick Tree

1. **Lazy Propagation**: Can batch-update ranges efficiently
2. **Range Queries**: Sum any range [l, r], not just prefix
3. **More Intuitive**: Easier to extend for complex queries

### When to Use

- Need range updates (e.g., collapse entire group)
- Complex queries beyond prefix sums
- Willing to trade 2x memory for flexibility

---

## Solution 3: Sparse Boundary Model

### Overview

The current codebase partially implements a **sparse boundary model** via `GroupBoundary`. This is optimal when:
- Row heights are uniform WITHIN groups
- Only headers/subgroups have different heights
- Groups are relatively large

### Data Structure

```objc
@interface GroupBoundary : NSObject
@property (nonatomic, assign) NSInteger startPlaylistIndex;
@property (nonatomic, assign) NSInteger endPlaylistIndex;
@property (nonatomic, assign) NSInteger rowOffset;      // Cumulative row count before this group
@property (nonatomic, assign) CGFloat yOffset;          // Cumulative Y before this group
@property (nonatomic, copy) NSString *headerText;
@property (nonatomic, copy) NSString *albumArtKey;
@property (nonatomic, assign) BOOL hasSubgroups;
@end
```

### Enhanced Implementation

```objc
@interface SparseGroupManager : NSObject

@property (nonatomic, strong) NSMutableArray<GroupBoundary *> *boundaries;
@property (nonatomic, assign) CGFloat headerHeight;
@property (nonatomic, assign) CGFloat subgroupHeight;
@property (nonatomic, assign) CGFloat trackHeight;

// O(log g) where g = number of groups
- (GroupBoundary *)boundaryContainingPlaylistIndex:(NSInteger)playlistIndex;

// O(log g) - binary search on yOffset
- (NSInteger)rowAtY:(CGFloat)y;

// O(log g) - binary search then O(1) calculation
- (CGFloat)yForPlaylistIndex:(NSInteger)playlistIndex;

// O(1) amortized - incremental calculation
- (void)appendBoundaryWithHeaderText:(NSString *)header
                         startIndex:(NSInteger)start;

// O(g) - only on playlist change
- (void)rebuildYOffsets;

@end
```

### Row Calculation Within Group

```objc
- (NSInteger)rowAtY:(CGFloat)y {
    // Binary search for containing boundary
    GroupBoundary *boundary = [self boundaryContainingY:y];
    if (!boundary) return NSNotFound;

    CGFloat localY = y - boundary.yOffset;

    // Header
    if (localY < self.headerHeight) {
        return boundary.rowOffset;
    }
    localY -= self.headerHeight;

    // Subgroup handling (if any)
    if (boundary.hasSubgroups) {
        // More complex: need subgroup boundaries too
        // Or assume uniform subgroup distribution
    }

    // Track within group
    NSInteger trackOffset = (NSInteger)floor(localY / self.trackHeight);
    return boundary.rowOffset + 1 + trackOffset;  // +1 for header
}
```

### Complexity Analysis

| Operation | Complexity | Notes |
|-----------|------------|-------|
| Build | O(n) | Single pass |
| Query row at Y | O(log g) | g = group count |
| Query Y for row | O(log g) | |
| Insert/remove items | O(g) | Rebuild offsets |
| Space | O(g) | Much smaller than O(n) |

### When to Use

- Large groups (100+ tracks per album)
- Uniform track heights within groups
- Low group churn (albums don't change often)

---

## Solution 4: Jump Pointer / Level Ancestor

### Overview

For hierarchical navigation (header -> subgroup -> track), the Level Ancestor problem provides O(1) queries after O(n log n) preprocessing.

### Application to Grouped Playlists

```cpp
struct JumpPointers {
    // For each row, store pointers to ancestors at 2^k levels up
    // Level 0 = parent, Level 1 = grandparent, etc.
    std::vector<std::array<int, 16>> jump;  // 16 levels = 65536 depth
    std::vector<int> depth;

    void build(const std::vector<int>& parent) {
        int n = parent.size();
        jump.resize(n);
        depth.resize(n);

        for (int i = 0; i < n; i++) {
            jump[i][0] = parent[i];
            depth[i] = (parent[i] == -1) ? 0 : depth[parent[i]] + 1;
        }

        for (int k = 1; k < 16; k++) {
            for (int i = 0; i < n; i++) {
                if (jump[i][k-1] != -1)
                    jump[i][k] = jump[jump[i][k-1]][k-1];
                else
                    jump[i][k] = -1;
            }
        }
    }

    // Find ancestor at given depth in O(log n)
    int ancestor(int node, int targetDepth) {
        int diff = depth[node] - targetDepth;
        for (int k = 0; diff > 0; k++, diff >>= 1) {
            if (diff & 1) node = jump[node][k];
        }
        return node;
    }

    // Find containing group header in O(1)
    int groupHeader(int trackRow) {
        return ancestor(trackRow, 0);  // Depth 0 = headers
    }
};
```

### When to Use

- Deep nesting (multiple subgroup levels)
- Frequent "find parent group" queries
- Navigation-heavy UI (keyboard up/down through groups)

---

## Rendering Pipeline Optimizations

### 1. Dirty Rect Optimization

Current implementation already uses dirty rect, but can be improved:

```objc
- (void)drawRect:(NSRect)dirtyRect {
    // Current: find all rows intersecting dirtyRect
    // Improved: track dirty row ranges explicitly

    if (self.dirtyRowRange.location != NSNotFound) {
        NSInteger startRow = self.dirtyRowRange.location;
        NSInteger endRow = NSMaxRange(self.dirtyRowRange);

        for (NSInteger row = startRow; row < endRow; row++) {
            [self drawRow:row];
        }

        self.dirtyRowRange = NSMakeRange(NSNotFound, 0);
    }
}

- (void)invalidateRowsInRange:(NSRange)range {
    if (self.dirtyRowRange.location == NSNotFound) {
        self.dirtyRowRange = range;
    } else {
        self.dirtyRowRange = NSUnionRange(self.dirtyRowRange, range);
    }
    [self setNeedsDisplayInRect:[self rectForRowRange:range]];
}
```

### 2. Row View Recycling (Hybrid Approach)

Even with custom drawing, maintain a small pool of pre-rendered row bitmaps:

```objc
@interface RowRenderCache : NSObject
@property (nonatomic, strong) NSCache<NSNumber *, NSImage *> *cache;
@property (nonatomic, assign) NSInteger cacheHits;
@property (nonatomic, assign) NSInteger cacheMisses;

- (NSImage *)cachedImageForRow:(NSInteger)row
                      version:(NSUInteger)version
                       bounds:(NSRect)bounds
                   renderBlock:(void(^)(NSGraphicsContext *))render;
@end

@implementation RowRenderCache

- (NSImage *)cachedImageForRow:(NSInteger)row
                      version:(NSUInteger)version
                       bounds:(NSRect)bounds
                   renderBlock:(void(^)(NSGraphicsContext *))render {

    NSNumber *key = @(row * 1000000 + version);  // Composite key
    NSImage *cached = [self.cache objectForKey:key];

    if (cached) {
        self.cacheHits++;
        return cached;
    }

    self.cacheMisses++;

    NSImage *image = [[NSImage alloc] initWithSize:bounds.size];
    [image lockFocus];
    render([NSGraphicsContext currentContext]);
    [image unlockFocus];

    [self.cache setObject:image forKey:key cost:bounds.size.width * bounds.size.height * 4];
    return image;
}

@end
```

### 3. Prefetch Visible + Buffer Rows

```objc
- (void)scrollViewDidScroll:(NSNotification *)notification {
    NSRange visibleRange = [self visibleRowRange];

    // Prefetch buffer zone (e.g., 20 rows above and below)
    NSInteger bufferSize = 20;
    NSInteger prefetchStart = MAX(0, (NSInteger)visibleRange.location - bufferSize);
    NSInteger prefetchEnd = MIN(self.totalRowCount,
                                 NSMaxRange(visibleRange) + bufferSize);

    dispatch_async(self.prefetchQueue, ^{
        for (NSInteger row = prefetchStart; row < prefetchEnd; row++) {
            [self prefetchDataForRow:row];
        }
    });
}

- (void)prefetchDataForRow:(NSInteger)row {
    GroupNode *node = [self nodeForRow:row];

    // Prefetch column values if not already cached
    if (node.type == GroupNodeTypeTrack && !node.columnValues) {
        NSArray *values = [self.delegate playlistView:self
                           columnValuesForPlaylistIndex:node.playlistIndex];

        dispatch_async(dispatch_get_main_queue(), ^{
            node.columnValues = values;
        });
    }
}
```

### 4. Horizontal Clipping

Only render columns visible in the horizontal scroll area:

```objc
- (void)drawTrackNode:(GroupNode *)node inRect:(NSRect)rowRect {
    CGFloat x = self.groupColumnWidth;
    NSRect clipRect = self.visibleRect;

    for (ColumnDefinition *column in self.columns) {
        NSRect columnRect = NSMakeRect(x, rowRect.origin.y,
                                        column.width, rowRect.size.height);

        // Skip columns entirely outside visible horizontal area
        if (NSMaxX(columnRect) < clipRect.origin.x) {
            x += column.width;
            continue;
        }
        if (columnRect.origin.x > NSMaxX(clipRect)) {
            break;  // All remaining columns are off-screen
        }

        [self drawColumn:column forNode:node inRect:columnRect];
        x += column.width;
    }
}
```

---

## Memory Optimization Strategies

### 1. Flyweight Pattern for Nodes

Instead of storing full data in each node, use indices and shared lookup:

```objc
// Before: Each node stores strings
@interface GroupNode : NSObject
@property (copy) NSString *displayText;      // Allocated per node
@property (copy) NSArray<NSString *> *columnValues;  // Allocated per node
@end

// After: Nodes store indices, shared pool stores strings
@interface LightweightNode : NSObject
@property (assign) GroupNodeType type;
@property (assign) NSInteger playlistIndex;  // -1 for headers
@property (assign) NSInteger displayTextIndex;  // Index into string pool
@property (assign) uint8_t indentLevel;
@end

@interface StringPool : NSObject
@property (strong) NSMutableArray<NSString *> *strings;
@property (strong) NSMapTable<NSString *, NSNumber *> *stringToIndex;

- (NSInteger)internString:(NSString *)string;
- (NSString *)stringAtIndex:(NSInteger)index;
@end
```

### 2. Lazy Node Creation

Only create nodes for visible range + buffer:

```objc
@interface LazyNodeManager : NSObject

@property (assign) NSRange materializedRange;
@property (strong) NSMutableArray<GroupNode *> *materializedNodes;

- (GroupNode *)nodeAtRow:(NSInteger)row {
    if (!NSLocationInRange(row, self.materializedRange)) {
        [self materializeRangeAroundRow:row];
    }

    NSInteger localIndex = row - self.materializedRange.location;
    return self.materializedNodes[localIndex];
}

- (void)materializeRangeAroundRow:(NSInteger)row {
    NSInteger bufferSize = 100;
    NSInteger start = MAX(0, row - bufferSize);
    NSInteger end = MIN(self.totalRowCount, row + bufferSize);

    // Release old nodes
    [self.materializedNodes removeAllObjects];

    // Create nodes for new range
    for (NSInteger i = start; i < end; i++) {
        GroupNode *node = [self createNodeForRow:i];
        [self.materializedNodes addObject:node];
    }

    self.materializedRange = NSMakeRange(start, end - start);
}

@end
```

### 3. Compact Bit Flags for Selection

Instead of `NSIndexSet` for selection (which can be heavy), use bit array:

```cpp
class CompactSelection {
    std::vector<uint64_t> bits;
    size_t count;

public:
    CompactSelection(size_t capacity)
        : bits((capacity + 63) / 64, 0), count(0) {}

    void set(size_t index, bool selected) {
        size_t word = index / 64;
        size_t bit = index % 64;
        bool was = (bits[word] >> bit) & 1;

        if (selected && !was) {
            bits[word] |= (1ULL << bit);
            count++;
        } else if (!selected && was) {
            bits[word] &= ~(1ULL << bit);
            count--;
        }
    }

    bool isSelected(size_t index) const {
        return (bits[index / 64] >> (index % 64)) & 1;
    }

    size_t selectedCount() const { return count; }

    // Fast range check: any selected in [start, end)?
    bool anySelectedInRange(size_t start, size_t end) const {
        // Optimized with word-level operations
        size_t startWord = start / 64;
        size_t endWord = (end - 1) / 64;

        if (startWord == endWord) {
            uint64_t mask = ((1ULL << (end - start)) - 1) << (start % 64);
            return bits[startWord] & mask;
        }

        // Check partial first word
        uint64_t firstMask = ~((1ULL << (start % 64)) - 1);
        if (bits[startWord] & firstMask) return true;

        // Check full middle words
        for (size_t w = startWord + 1; w < endWord; w++) {
            if (bits[w]) return true;
        }

        // Check partial last word
        uint64_t lastMask = (1ULL << ((end - 1) % 64 + 1)) - 1;
        return bits[endWord] & lastMask;
    }
};
```

---

## Incremental Update Strategies

### 1. Diff-Based Updates

When playlist changes, compute minimal diff:

```objc
typedef NS_ENUM(NSInteger, PlaylistDiffType) {
    PlaylistDiffInsert,
    PlaylistDiffDelete,
    PlaylistDiffMove,
    PlaylistDiffUpdate
};

@interface PlaylistDiff : NSObject
@property (assign) PlaylistDiffType type;
@property (assign) NSRange range;
@property (assign) NSInteger destination;  // For moves
@end

- (void)applyDiffs:(NSArray<PlaylistDiff *> *)diffs {
    for (PlaylistDiff *diff in diffs) {
        switch (diff.type) {
            case PlaylistDiffInsert:
                [self insertRowsInRange:diff.range];
                break;
            case PlaylistDiffDelete:
                [self deleteRowsInRange:diff.range];
                break;
            case PlaylistDiffMove:
                [self moveRowsInRange:diff.range toIndex:diff.destination];
                break;
            case PlaylistDiffUpdate:
                [self updateRowsInRange:diff.range];
                break;
        }
    }

    // Update Fenwick tree incrementally
    [self.heightTree applyDiffs:diffs];
}
```

### 2. Amortized Batch Updates

Collect multiple rapid changes and apply together:

```objc
@interface BatchUpdateManager : NSObject

@property (strong) NSMutableArray<PlaylistDiff *> *pendingDiffs;
@property (strong) NSTimer *flushTimer;
@property (assign) NSTimeInterval batchWindow;  // e.g., 16ms (one frame)

- (void)enqueueDiff:(PlaylistDiff *)diff {
    [self.pendingDiffs addObject:diff];

    if (!self.flushTimer) {
        self.flushTimer = [NSTimer scheduledTimerWithTimeInterval:self.batchWindow
                                                           target:self
                                                         selector:@selector(flush)
                                                         userInfo:nil
                                                          repeats:NO];
    }
}

- (void)flush {
    NSArray *diffs = [self.pendingDiffs copy];
    [self.pendingDiffs removeAllObjects];
    self.flushTimer = nil;

    // Coalesce and optimize diffs
    NSArray *optimizedDiffs = [self coalesceDiffs:diffs];

    [self.playlistView applyDiffs:optimizedDiffs];
}

- (NSArray *)coalesceDiffs:(NSArray *)diffs {
    // Merge adjacent inserts/deletes
    // Cancel out insert+delete of same items
    // Convert multiple updates to single range
    // ... optimization logic
}

@end
```

---

## GPU Acceleration with CALayer

### 1. Layer-Backed View

```objc
- (void)awakeFromNib {
    [super awakeFromNib];
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.layer.drawsAsynchronously = YES;
}
```

### 2. Tile-Based Rendering

Split the content into tiles for efficient partial updates:

```objc
@interface TiledContentLayer : CALayer

@property (assign) CGSize tileSize;  // e.g., 1024x256
@property (strong) NSMutableDictionary<NSValue *, CALayer *> *tiles;

- (void)updateTilesForVisibleRect:(CGRect)visibleRect;

@end

@implementation TiledContentLayer

- (void)updateTilesForVisibleRect:(CGRect)visibleRect {
    // Calculate which tiles are needed
    NSInteger startCol = floor(visibleRect.origin.x / self.tileSize.width);
    NSInteger endCol = ceil(CGRectGetMaxX(visibleRect) / self.tileSize.width);
    NSInteger startRow = floor(visibleRect.origin.y / self.tileSize.height);
    NSInteger endRow = ceil(CGRectGetMaxY(visibleRect) / self.tileSize.height);

    NSMutableSet *neededTiles = [NSMutableSet set];

    for (NSInteger row = startRow; row < endRow; row++) {
        for (NSInteger col = startCol; col < endCol; col++) {
            [neededTiles addObject:[NSValue valueWithPoint:NSMakePoint(col, row)]];
        }
    }

    // Remove tiles no longer needed
    NSMutableArray *tilesToRemove = [NSMutableArray array];
    for (NSValue *key in self.tiles) {
        if (![neededTiles containsObject:key]) {
            [tilesToRemove addObject:key];
        }
    }
    for (NSValue *key in tilesToRemove) {
        [self.tiles[key] removeFromSuperlayer];
        [self.tiles removeObjectForKey:key];
    }

    // Create new tiles
    for (NSValue *key in neededTiles) {
        if (!self.tiles[key]) {
            [self createTileAtPosition:key.pointValue];
        }
    }
}

- (void)createTileAtPosition:(NSPoint)position {
    CALayer *tile = [CALayer layer];
    tile.frame = CGRectMake(position.x * self.tileSize.width,
                            position.y * self.tileSize.height,
                            self.tileSize.width,
                            self.tileSize.height);
    tile.delegate = self;
    tile.drawsAsynchronously = YES;

    [self addSublayer:tile];
    self.tiles[[NSValue valueWithPoint:position]] = tile;

    [tile setNeedsDisplay];
}

@end
```

### 3. CAScrollLayer for Smooth Scrolling

```objc
- (void)setupScrollLayer {
    CAScrollLayer *scrollLayer = [CAScrollLayer layer];
    scrollLayer.scrollMode = kCAScrollVertically;

    // Content layer contains all rows
    CALayer *contentLayer = [CALayer layer];
    contentLayer.frame = CGRectMake(0, 0,
                                     self.bounds.size.width,
                                     self.totalContentHeight);

    [scrollLayer addSublayer:contentLayer];
    self.layer = scrollLayer;

    self.contentLayer = contentLayer;
}

- (void)scrollToY:(CGFloat)y {
    // GPU-accelerated scroll - no redraw needed
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [(CAScrollLayer *)self.layer scrollToPoint:CGPointMake(0, y)];
    [CATransaction commit];

    // Update visible tiles
    [self updateTilesForVisibleRect:[self visibleRect]];
}
```

---

## Recommended Implementation Path

### Phase 1: Quick Wins (1-2 days)

1. **Implement Fenwick Tree** for row position lookup
   - Replace `rowYOffsets` array with Fenwick tree
   - O(log n) updates instead of O(n) rebuild

2. **Add horizontal column clipping**
   - Skip drawing columns outside visible horizontal area
   - Immediate rendering speedup

3. **Enable layer backing**
   - `self.wantsLayer = YES`
   - `self.layer.drawsAsynchronously = YES`

### Phase 2: Memory Optimization (2-3 days)

4. **Complete sparse boundary model**
   - Finish `GroupBoundary` implementation
   - Only materialize visible nodes + buffer

5. **Implement compact selection**
   - Replace `NSIndexSet` with bit array
   - O(1) range selection checks for album art

6. **String interning for display text**
   - Deduplicate repeated album/artist names

### Phase 3: Advanced Optimization (3-5 days)

7. **Tile-based rendering**
   - Implement `TiledContentLayer`
   - Partial redraws instead of full

8. **Prefetch pipeline**
   - Background queue for column value formatting
   - Prefetch buffer zone during scroll

9. **Batch update coalescing**
   - Collect rapid playlist changes
   - Apply as single optimized update

### Phase 4: Polish (2-3 days)

10. **Profile and tune**
    - Use Instruments to find remaining hotspots
    - Tune buffer sizes, cache limits, tile dimensions

11. **Fallback modes**
    - Detect very large playlists (>50k)
    - Auto-disable expensive features (album art, grouping)

---

## References

### Apple Documentation
- [NSScrollView](https://developer.apple.com/documentation/appkit/nsscrollview)
- [CALayer](https://developer.apple.com/documentation/quartzcore/calayer)
- [Improving Animation Performance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/ImprovingAnimationPerformance/ImprovingAnimationPerformance.html)

### Data Structures
- [Fenwick Tree - CP Algorithms](https://cp-algorithms.com/data_structures/fenwick.html)
- [Segment Tree - CP Algorithms](https://cp-algorithms.com/data_structures/segment_tree.html)
- [Level Ancestor Problem - Wikipedia](https://en.wikipedia.org/wiki/Level_ancestor_problem)

### Virtual Scrolling
- [Virtual Scrolling: Optimize Large Lists](https://kitemetric.com/blogs/virtual-scroll)
- [Custom Lazy List in SwiftUI](https://nilcoalescing.com/blog/CustomLazyListInSwiftUI/)
- [Optimized NSTableView Scrolling](https://jwilling.com/blog/optimized-nstableview-scrolling/)

### React/Web (Concepts Apply)
- [React Reconciliation](https://legacy.reactjs.org/docs/reconciliation.html)
- [React Virtualized](https://blog.logrocket.com/rendering-large-lists-react-virtualized/)

### foobar2000
- [foobar2000 Changelog - Performance Improvements](https://www.foobar2000.org/changelog)

---

## Appendix: Benchmark Targets

For a playlist with 50,000 tracks grouped into ~500 albums:

| Metric | Current | Target | Excellent |
|--------|---------|--------|-----------|
| Initial load | 2-5s | <500ms | <100ms |
| Scroll FPS | 30-45 | 60 | 120 |
| Memory (nodes) | 50MB | 5MB | 1MB |
| Single row update | 500ms | 10ms | <1ms |
| Group collapse | 1s | 50ms | 10ms |

---

*Document created: 2024-12-23*
*Last updated: 2024-12-23*
