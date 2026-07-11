//
//  PlorgTreeYamlCodec.mm
//  foo_plorg_mac
//

#import "PlorgTreeYamlCodec.h"

@implementation PlorgTreeYamlCodec

#pragma mark - Escaping

+ (NSString *)escapeString:(NSString *)str {
    return [[str stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
            stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

+ (NSString *)unescapeString:(NSString *)str {
    return [[str stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""]
            stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
}

#pragma mark - Serialization

+ (NSString *)nodeToYaml:(TreeNode *)node indent:(NSInteger)indent {
    NSMutableString *yaml = [NSMutableString string];
    NSString *indentStr = [@"" stringByPaddingToLength:indent withString:@"  " startingAtIndex:0];

    if (node.isFolder) {
        [yaml appendFormat:@"%@- folder: \"%@\"\n", indentStr, [self escapeString:node.name]];
        if (node.isExpanded) {
            [yaml appendFormat:@"%@  expanded: true\n", indentStr];
        }
        if (node.children.count > 0) {
            [yaml appendFormat:@"%@  items:\n", indentStr];
            for (TreeNode *child in node.children) {
                [yaml appendString:[self nodeToYaml:child indent:indent + 2]];
            }
        }
    } else {
        [yaml appendFormat:@"%@- playlist: \"%@\"\n", indentStr, [self escapeString:node.name]];
    }

    return yaml;
}

+ (NSString *)yamlForTree:(NSArray<TreeNode *> *)rootNodes nodeFormat:(NSString *)nodeFormat {
    NSMutableString *yaml = [NSMutableString string];
    [yaml appendString:@"# Playlist Organizer Configuration\n"];
    [yaml appendFormat:@"node_format: \"%@\"\n\n", [self escapeString:nodeFormat ?: @"%node_name%"]];

    if (rootNodes.count > 0) {
        [yaml appendString:@"tree:\n"];
        for (TreeNode *node in rootNodes) {
            [yaml appendString:[self nodeToYaml:node indent:1]];
        }
    } else {
        [yaml appendString:@"tree: []\n"];
    }

    return yaml;
}

#pragma mark - Parsing

+ (BOOL)parseConfigYaml:(NSString *)yaml
              rootNodes:(NSArray<TreeNode *> **)outRoots
             nodeFormat:(NSString **)outFormat {
    if (outRoots) *outRoots = @[];
    if (outFormat) *outFormat = nil;
    if (!yaml || yaml.length == 0) return NO;

    NSArray *lines = [yaml componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<TreeNode *> *rootNodes = [NSMutableArray array];
    NSMutableArray<TreeNode *> *nodeStack = [NSMutableArray array];  // Stack of parent nodes
    NSMutableArray<NSNumber *> *indentStack = [NSMutableArray array];  // Corresponding indents

    BOOL inTree = NO;

    for (NSString *rawLine in lines) {
        // Skip empty lines and comments
        if (rawLine.length == 0 || [rawLine hasPrefix:@"#"]) continue;

        // Count leading spaces
        NSInteger indent = 0;
        while (indent < (NSInteger)rawLine.length && [rawLine characterAtIndex:indent] == ' ') {
            indent++;
        }

        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;

        // Parse node_format
        if ([line hasPrefix:@"node_format:"]) {
            NSString *value = [line substringFromIndex:12];
            value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
                value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
            }
            if (outFormat) *outFormat = [self unescapeString:value];
            continue;
        }

        // Start of tree section
        if ([line hasPrefix:@"tree:"]) {
            inTree = YES;
            continue;
        }

        if (!inTree) continue;

        // Parse folder or playlist
        TreeNode *node = nil;

        if ([line hasPrefix:@"- folder:"]) {
            NSString *name = [self extractQuotedValue:line afterPrefix:@"- folder:"];
            if (name) {
                node = [TreeNode folderWithName:name];
            }
        } else if ([line hasPrefix:@"- playlist:"]) {
            NSString *name = [self extractQuotedValue:line afterPrefix:@"- playlist:"];
            if (name) {
                node = [TreeNode playlistWithName:name];
            }
        } else if ([line hasPrefix:@"expanded:"]) {
            // This is a property of the previous folder
            if (nodeStack.count > 0) {
                TreeNode *lastNode = nodeStack.lastObject;
                if (lastNode.isFolder) {
                    lastNode.isExpanded = [line containsString:@"true"];
                }
            }
            continue;
        } else if ([line isEqualToString:@"items:"]) {
            // Items marker - children follow
            continue;
        }

        if (!node) continue;

        // Pop nodes from stack that are at same or higher indent
        while (indentStack.count > 0 && indentStack.lastObject.integerValue >= indent) {
            [nodeStack removeLastObject];
            [indentStack removeLastObject];
        }

        // Add to parent or root
        if (nodeStack.count > 0) {
            TreeNode *parent = nodeStack.lastObject;
            if (parent.isFolder) {
                [parent addChild:node];
            }
        } else {
            node.parent = nil;
            [rootNodes addObject:node];
        }

        // Push this node if it's a folder (might have children)
        if (node.isFolder) {
            [nodeStack addObject:node];
            [indentStack addObject:@(indent)];
        }
    }

    if (outRoots) *outRoots = rootNodes;
    return rootNodes.count > 0;
}

+ (NSArray<TreeNode *> *)parseNodeList:(NSString *)yaml {
    if (!yaml || yaml.length == 0) return @[];

    NSMutableArray<TreeNode *> *parsedRoots = [NSMutableArray array];
    NSMutableArray<TreeNode *> *nodeStack = [NSMutableArray array];
    NSMutableArray<NSNumber *> *indentStack = [NSMutableArray array];

    NSArray *lines = [yaml componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL inTree = NO;

    for (NSString *rawLine in lines) {
        if (rawLine.length == 0 || [rawLine hasPrefix:@"#"]) continue;

        NSInteger indent = 0;
        while (indent < (NSInteger)rawLine.length && [rawLine characterAtIndex:indent] == ' ') {
            indent++;
        }

        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([line hasPrefix:@"tree:"]) {
            inTree = YES;
            continue;
        }

        if (!inTree) continue;

        while (indentStack.count > 0 && indent <= indentStack.lastObject.integerValue) {
            [nodeStack removeLastObject];
            [indentStack removeLastObject];
        }

        TreeNode *newNode = nil;

        if ([line hasPrefix:@"- folder:"]) {
            NSString *name = [self extractQuotedValue:line afterPrefix:@"- folder:"];
            if (name) {
                newNode = [TreeNode folderWithName:name];
            }
        } else if ([line hasPrefix:@"- playlist:"]) {
            NSString *name = [self extractQuotedValue:line afterPrefix:@"- playlist:"];
            if (name) {
                newNode = [TreeNode playlistWithName:name];
            }
        } else if ([line hasPrefix:@"expanded:"]) {
            if (nodeStack.count > 0 && nodeStack.lastObject.isFolder) {
                BOOL expanded = [line containsString:@"true"];
                nodeStack.lastObject.isExpanded = expanded;
            }
            continue;
        } else if ([line hasPrefix:@"items:"]) {
            continue;
        }

        if (newNode) {
            if (nodeStack.count > 0) {
                [nodeStack.lastObject addChild:newNode];
            } else {
                [parsedRoots addObject:newNode];
            }

            if (newNode.isFolder) {
                [nodeStack addObject:newNode];
                [indentStack addObject:@(indent)];
            }
        }
    }

    return parsedRoots;
}

+ (NSString *)extractQuotedValue:(NSString *)line afterPrefix:(NSString *)prefix {
    NSRange range = [line rangeOfString:prefix];
    if (range.location == NSNotFound) return nil;

    NSString *value = [line substringFromIndex:range.location + range.length];
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        return [self unescapeString:value];
    }

    return value;
}

@end
