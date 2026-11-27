//
//  SVRedirectGuard.h
//  foo_jl_shellvanced_mac
//
//  Task delegate that refuses HTTP redirects leaving https + the allowed hosts (CDN downloads).
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SVRedirectGuard : NSObject <NSURLSessionTaskDelegate>
/// `hosts`: exact host names or domain suffixes ("dzcdn.net" allows "x.dzcdn.net" and "dzcdn.net").
+ (instancetype)guardWithHosts:(NSArray<NSString *> *)hosts;
+ (BOOL)url:(NSURL *)url isAllowedForHosts:(NSArray<NSString *> *)hosts;
@end

NS_ASSUME_NONNULL_END
