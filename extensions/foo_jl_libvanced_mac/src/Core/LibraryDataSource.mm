//
//  LibraryDataSource.mm
//  foo_jl_libvanced
//

#import "LibraryDataSource.h"
#import "LibraryTreeNode.h"
#import "ConfigHelper.h"

@implementation LibraryDataSource {
    std::mutex _treeMutex;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _rootNode = [LibraryTreeNode rootNode];
        _groupPattern = [NSString stringWithUTF8String:
                         libvanced_config::getDefaultGroupPattern().c_str()];
        _sortPattern = [NSString stringWithUTF8String:
                        libvanced_config::getDefaultSortPattern().c_str()];
    }
    return self;
}

- (void)rebuildTree {
    [self rebuildTreeWithFilter:nil];
}

- (void)rebuildTreeWithFilter:(nullable NSString *)filterQuery {
    [_delegate libraryDataSourceDidBeginUpdate];

    // SDK calls (library_manager, search_filter) MUST happen on the main thread.
    // Fetch all items here, then move the heavy tree-building to background.
    metadb_handle_list allItems;
    bool gotItems = false;

    try {
        auto libManager = library_manager::get();
        if (!libManager.is_valid() || !libManager->is_library_enabled()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_delegate libraryDataSourceDidUpdate];
            });
            return;
        }

        libManager->get_all_items(allItems);

        if (filterQuery && filterQuery.length > 0) {
            auto filterMgr = search_filter_manager::get();
            search_filter::ptr filter;
            try {
                filter = filterMgr->create([filterQuery UTF8String]);
            } catch (...) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self->_delegate libraryDataSourceDidUpdate];
                });
                return;
            }

            pfc::array_t<bool> mask;
            mask.set_size(allItems.get_count());
            abort_callback_dummy abort;
            filter->test_multi(allItems, mask.get_ptr());

            metadb_handle_list filtered;
            for (size_t i = 0; i < allItems.get_count(); i++) {
                if (mask[i]) {
                    filtered.add_item(allItems[i]);
                }
            }
            allItems = filtered;
        }
        gotItems = true;
    } catch (...) {
        FB2K_console_formatter() << "[LibVanced] Error fetching library items";
    }

    if (!gotItems || allItems.get_count() == 0) {
        std::lock_guard<std::mutex> lock(_treeMutex);
        _rootNode = [LibraryTreeNode rootNode];
        [_delegate libraryDataSourceDidUpdate];
        return;
    }

    // Heavy work (sorting, titleformat, tree building) goes to background.
    // metadb_handle_ptr is ref-counted and thread-safe to read;
    // format_title on handles is safe from any thread.
    NSString *groupPatternCopy = [_groupPattern copy];
    NSString *sortPatternCopy = [_sortPattern copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            LibraryTreeNode *newRoot = [self buildTreeFromItems:allItems
                                                  groupPattern:groupPatternCopy
                                                   sortPattern:sortPatternCopy];

            dispatch_async(dispatch_get_main_queue(), ^{
                std::lock_guard<std::mutex> lock(self->_treeMutex);
                self->_rootNode = newRoot;
                [self->_delegate libraryDataSourceDidUpdate];
            });
        }
    });
}

- (LibraryTreeNode *)buildTreeFromItems:(metadb_handle_list)allItems
                           groupPattern:(NSString *)groupPattern
                            sortPattern:(NSString *)sortPattern {
    LibraryTreeNode *root = [LibraryTreeNode rootNode];

    if (allItems.get_count() == 0) return root;

    [self sortItems:allItems withPattern:sortPattern];

    NSArray<NSString *> *levels = [groupPattern componentsSeparatedByString:@"|"];
    std::vector<titleformat_object::ptr> groupScripts;
    for (NSString *level in levels) {
        titleformat_object::ptr tf;
        NSString *trimmed = [level stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        titleformat_compiler::get()->compile_safe_ex(tf, [trimmed UTF8String], "%filename%");
        groupScripts.push_back(tf);
    }

    titleformat_object::ptr titleScript;
    titleformat_compiler::get()->compile_safe_ex(titleScript,
        "[%tracknumber%. ]%title%", "%filename%");

    for (size_t i = 0; i < allItems.get_count(); i++) {
        metadb_handle_ptr handle = allItems[i];

        LibraryTreeNode *current = root;
        for (size_t level = 0; level < groupScripts.size(); level++) {
            pfc::string8 groupValue;
            handle->format_title(nullptr, groupValue, groupScripts[level], nullptr);

            NSString *groupName = [NSString stringWithUTF8String:groupValue.c_str()];
            if (!groupName || groupName.length == 0) {
                groupName = @"?";
            }

            LibraryTreeNode *found = nil;
            if (current.children.count > 0) {
                LibraryTreeNode *last = current.children.lastObject;
                if ([last.displayName isEqualToString:groupName]) {
                    found = last;
                }
            }

            if (!found) {
                found = [LibraryTreeNode groupNodeWithName:groupName];
                [current addChild:found];

                if (level == groupScripts.size() - 1) {
                    const char* path = handle->get_path();
                    if (path) {
                        found.albumArtPath = [NSString stringWithUTF8String:path];
                    }
                }
            }
            current = found;
        }

        pfc::string8 title;
        handle->format_title(nullptr, title, titleScript, nullptr);

        const char* path = handle->get_path();
        NSString *trackPath = path ? [NSString stringWithUTF8String:path] : @"";
        NSString *trackTitle = [NSString stringWithUTF8String:title.c_str()];

        LibraryTreeNode *trackNode = [LibraryTreeNode trackNodeWithName:trackTitle
                                                                   path:trackPath
                                                                subsong:handle->get_subsong_index()];
        [current addChild:trackNode];
    }

    return root;
}

- (void)sortItems:(metadb_handle_list &)items withPattern:(NSString *)sortPattern {
    if (sortPattern.length == 0) return;

    titleformat_object::ptr sortScript;
    titleformat_compiler::get()->compile_safe_ex(sortScript,
        [sortPattern UTF8String], "%path_sort%");

    // Build sort keys
    std::vector<std::pair<std::string, size_t>> sortKeys;
    sortKeys.reserve(items.get_count());

    for (size_t i = 0; i < items.get_count(); i++) {
        pfc::string8 key;
        items[i]->format_title(nullptr, key, sortScript, nullptr);
        sortKeys.push_back({std::string(key.c_str()), i});
    }

    std::sort(sortKeys.begin(), sortKeys.end(),
        [](const auto &a, const auto &b) { return a.first < b.first; });

    // Rebuild items in sorted order
    metadb_handle_list sorted;
    sorted.prealloc(items.get_count());
    for (const auto &pair : sortKeys) {
        sorted.add_item(items[pair.second]);
    }

    items = sorted;
}

- (NSInteger)totalTrackCount {
    return _rootNode.trackCount;
}

- (void)getHandlesForNode:(LibraryTreeNode *)node
                  handles:(void (^)(const metadb_handle_list &))completion {
    NSArray<LibraryTreeNode *> *trackNodes = [node allTrackNodes];

    metadb_handle_list handles;
    auto db = metadb::get();

    for (LibraryTreeNode *trackNode in trackNodes) {
        if (!trackNode.trackPath) continue;

        metadb_handle_ptr handle;
        try {
            handle = db->handle_create([trackNode.trackPath UTF8String],
                                       (t_uint32)trackNode.trackSubsong);
            if (handle.is_valid()) {
                handles.add_item(handle);
            }
        } catch (...) {
            // Skip invalid handles
        }
    }

    completion(handles);
}

@end
