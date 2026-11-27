//
//  SVRedirectGuard.mm
//  foo_jl_shellvanced_mac
//

#import "SVRedirectGuard.h"

@implementation SVRedirectGuard {
    NSArray<NSString *> *_hosts;
}

+ (instancetype)guardWithHosts:(NSArray<NSString *> *)hosts {
    SVRedirectGuard *g = [[SVRedirectGuard alloc] init];
    g->_hosts = [hosts copy];
    return g;
}

+ (BOOL)url:(NSURL *)url isAllowedForHosts:(NSArray<NSString *> *)hosts {
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    NSString *host = url.host.lowercaseString;
    for (NSString *h in hosts)
        if ([host isEqualToString:h] || [host hasSuffix:[@"." stringByAppendingString:h]]) return YES;
    return NO;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    completionHandler([SVRedirectGuard url:request.URL isAllowedForHosts:_hosts] ? request : nil);
}

@end
