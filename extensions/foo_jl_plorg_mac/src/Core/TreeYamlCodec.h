//
//  TreeYamlCodec.h
//  foo_plorg_mac
//
//  YAML serialization and parsing for the playlist organizer tree.
//  Foundation-only (no SDK) so it is unit-testable standalone.
//

#pragma once

#import <Foundation/Foundation.h>
#import "TreeNode.h"

NS_ASSUME_NONNULL_BEGIN

@interface TreeYamlCodec : NSObject

// Escape backslash and double-quote for YAML output
+ (NSString *)escapeString:(NSString *)str;
+ (NSString *)unescapeString:(NSString *)str;

// Full config document: header comment, node_format, tree
+ (NSString *)yamlForTree:(NSArray<TreeNode *> *)rootNodes nodeFormat:(nullable NSString *)nodeFormat;

// Parse a full config document. Returns YES if the tree section produced at
// least one root node. outFormat is set (possibly to nil) from node_format.
+ (BOOL)parseConfigYaml:(NSString *)yaml
              rootNodes:(NSArray<TreeNode *> * _Nonnull * _Nullable)outRoots
             nodeFormat:(NSString * _Nullable * _Nullable)outFormat;

// Parse just the tree section into detached root nodes (for import/merge)
+ (NSArray<TreeNode *> *)parseNodeList:(nullable NSString *)yaml;

// Extract "value" from a line like `- folder: "value"`, unescaping if quoted
+ (nullable NSString *)extractQuotedValue:(NSString *)line afterPrefix:(NSString *)prefix;

@end

NS_ASSUME_NONNULL_END
