//
//  PathCodec.h
//  foo_plorg_mac
//
//  Path-encoded foobar2000 playlist names: escaping, encoding and splitting.
//  Foundation-only (no SDK) so it is unit-testable standalone.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Path encoding separator: space + right guillemet (U+00BB) + space
extern NSString * const PlorgPathSeparator;

@interface PathCodec : NSObject

// Escape guillemet by doubling: » -> »»
+ (NSString *)escapeComponent:(nullable NSString *)component;

// Unescape doubled guillemet: »» -> »
+ (NSString *)unescapeComponent:(nullable NSString *)component;

// Escape each component, skip empties, join with PlorgPathSeparator.
// A single surviving component is returned without a separator (root-level).
+ (NSString *)encodedNameForComponents:(NSArray<NSString *> *)components;

// Split on the separator and unescape each component.
+ (NSArray<NSString *> *)splitEncodedName:(NSString *)encodedName;

@end

NS_ASSUME_NONNULL_END
