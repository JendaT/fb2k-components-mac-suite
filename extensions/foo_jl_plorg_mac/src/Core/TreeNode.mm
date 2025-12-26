//
//  TreeNode.mm
//  foo_plorg_mac
//

#import "TreeNode.h"

@implementation TreeNode

#pragma mark - Factory Methods

+ (instancetype)folderWithName:(NSString *)name {
    TreeNode *node = [[TreeNode alloc] init];
    node.nodeType = TreeNodeTypeFolder;
    node.name = name;
    node.children = [NSMutableArray array];
    node.isExpanded = NO;
    return node;
}

+ (instancetype)playlistWithName:(NSString *)name {
    TreeNode *node = [[TreeNode alloc] init];
    node.nodeType = TreeNodeTypePlaylist;
    node.name = name;
    node.children = nil;
    return node;
}

#pragma mark - Convenience Properties

- (BOOL)isFolder {
    return self.nodeType == TreeNodeTypeFolder;
}

- (NSInteger)childCount {
    return self.children ? (NSInteger)self.children.count : 0;
}

#pragma mark - Child Management

- (void)addChild:(TreeNode *)child {
    if (!self.isFolder || !child) return;
    child.parent = self;
    [self.children addObject:child];
}

- (void)insertChild:(TreeNode *)child atIndex:(NSInteger)index {
    if (!self.isFolder || !child) return;
    if (index < 0) index = 0;
    if (index > (NSInteger)self.children.count) index = self.children.count;
    child.parent = self;
    [self.children insertObject:child atIndex:index];
}

- (void)removeChild:(TreeNode *)child {
    if (!self.isFolder || !child) return;
    child.parent = nil;
    [self.children removeObject:child];
}

- (void)removeChildAtIndex:(NSInteger)index {
    if (!self.isFolder) return;
    if (index < 0 || index >= (NSInteger)self.children.count) return;
    TreeNode *child = self.children[index];
    child.parent = nil;
    [self.children removeObjectAtIndex:index];
}

- (TreeNode *)childAtIndex:(NSInteger)index {
    if (!self.isFolder) return nil;
    if (index < 0 || index >= (NSInteger)self.children.count) return nil;
    return self.children[index];
}

#pragma mark - Serialization

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    if (self.isFolder) {
        dict[@"folder"] = self.name;
        if (self.children.count > 0) {
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:self.children.count];
            for (TreeNode *child in self.children) {
                [items addObject:[child toDictionary]];
            }
            dict[@"items"] = items;
        } else {
            dict[@"items"] = @[];
        }
        if (self.isExpanded) {
            dict[@"expanded"] = @YES;
        }
    } else {
        dict[@"playlist"] = self.name;
    }

    return dict;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    if (!dict) return nil;

    NSString *folderName = dict[@"folder"];
    NSString *playlistName = dict[@"playlist"];

    if (folderName) {
        TreeNode *folder = [TreeNode folderWithName:folderName];
        folder.isExpanded = [dict[@"expanded"] boolValue];

        NSArray *items = dict[@"items"];
        if ([items isKindOfClass:[NSArray class]]) {
            for (NSDictionary *itemDict in items) {
                TreeNode *child = [TreeNode fromDictionary:itemDict];
                if (child) {
                    [folder addChild:child];
                }
            }
        }
        return folder;
    } else if (playlistName) {
        return [TreeNode playlistWithName:playlistName];
    }

    return nil;
}

#pragma mark - Path Utilities

- (NSString *)path {
    if (!self.parent) {
        return self.name;
    }
    return [NSString stringWithFormat:@"%@/%@", self.parent.path, self.name];
}

#pragma mark - Formatting

- (NSString *)formattedNameWithFormat:(NSString *)format playlistItemCount:(NSInteger)itemCount {
    if (!format || format.length == 0) {
        return self.name;
    }

    NSString *result = format;

    // Replace variables
    result = [result stringByReplacingOccurrencesOfString:@"%node_name%" withString:self.name ?: @""];
    result = [result stringByReplacingOccurrencesOfString:@"%is_folder%" withString:self.isFolder ? @"1" : @""];

    // Count: child count for folders, item count for playlists
    NSString *countStr = self.isFolder ? [NSString stringWithFormat:@"%ld", (long)self.childCount]
                                       : [NSString stringWithFormat:@"%ld", (long)itemCount];
    result = [result stringByReplacingOccurrencesOfString:@"%count%" withString:countStr];

    // Process $if() conditionals
    result = [self evaluateSimpleIf:result];

    return result;
}

// Parse $if(condition,true_text,false_text) - handles quoted strings with commas
- (NSString *)evaluateSimpleIf:(NSString *)input {
    NSString *result = input;
    NSInteger maxIterations = 10;

    while (maxIterations-- > 0) {
        NSRange ifRange = [result rangeOfString:@"$if("];
        if (ifRange.location == NSNotFound) break;

        // Find the matching closing paren, respecting quotes
        NSInteger start = ifRange.location + 4;  // After "$if("
        NSInteger parenDepth = 1;
        NSInteger pos = start;
        BOOL inQuote = NO;
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        NSInteger argStart = start;

        while (pos < (NSInteger)result.length && parenDepth > 0) {
            unichar c = [result characterAtIndex:pos];

            if (c == '\'' && !inQuote) {
                inQuote = YES;
            } else if (c == '\'' && inQuote) {
                inQuote = NO;
            } else if (!inQuote) {
                if (c == '(') {
                    parenDepth++;
                } else if (c == ')') {
                    parenDepth--;
                    if (parenDepth == 0) {
                        // End of $if() - capture last arg
                        [args addObject:[result substringWithRange:NSMakeRange(argStart, pos - argStart)]];
                    }
                } else if (c == ',' && parenDepth == 1) {
                    // Argument separator at our level
                    [args addObject:[result substringWithRange:NSMakeRange(argStart, pos - argStart)]];
                    argStart = pos + 1;
                }
            }
            pos++;
        }

        if (parenDepth != 0 || args.count < 2) {
            // Malformed - skip
            break;
        }

        // Pad to 3 args if needed
        while (args.count < 3) {
            [args addObject:@""];
        }

        NSString *condition = [self stripQuotes:args[0]];
        NSString *trueText = [self stripQuotes:args[1]];
        NSString *falseText = [self stripQuotes:args[2]];

        // Condition is true if non-empty
        NSString *replacement = (condition.length > 0) ? trueText : falseText;

        // Replace the entire $if(...) with result
        NSRange fullRange = NSMakeRange(ifRange.location, pos - ifRange.location);
        result = [result stringByReplacingCharactersInRange:fullRange withString:replacement];
    }

    return result;
}

- (NSString *)stripQuotes:(NSString *)str {
    NSString *trimmed = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length >= 2 &&
        [trimmed characterAtIndex:0] == '\'' &&
        [trimmed characterAtIndex:trimmed.length - 1] == '\'') {
        return [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
    }
    return trimmed;
}

#pragma mark - Description

- (NSString *)description {
    if (self.isFolder) {
        return [NSString stringWithFormat:@"<Folder: %@ (%ld items)>", self.name, (long)self.childCount];
    } else {
        return [NSString stringWithFormat:@"<Playlist: %@>", self.name];
    }
}

@end
