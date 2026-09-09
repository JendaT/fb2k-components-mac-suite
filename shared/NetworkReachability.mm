//
//  NetworkReachability.mm
//  shared
//
//  Network reachability monitoring implementation
//

#import "NetworkReachability.h"
#import <Network/Network.h>

NSNotificationName const JLNetworkReachabilityChangedNotification = @"JLNetworkReachabilityChangedNotification";

@implementation JLNetworkReachability {
    nw_path_monitor_t _monitor;
    dispatch_queue_t _monitorQueue;
    BOOL _isMonitoring;
    BOOL _reachable;
    BOOL _hasReceivedUpdate;
    BOOL _expensive;
    BOOL _constrained;
    dispatch_queue_t _syncQueue;
}

+ (JLNetworkReachability *)sharedInstance {
    static JLNetworkReachability *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initPrivate];
        [instance startMonitoring];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _syncQueue = dispatch_queue_create("com.foobar2000.networkReachability.sync",
                                           DISPATCH_QUEUE_SERIAL);
        _monitorQueue = dispatch_queue_create("com.foobar2000.networkReachability.monitor",
                                              DISPATCH_QUEUE_SERIAL);
        _isMonitoring = NO;
        _reachable = NO;
        _expensive = NO;
        _constrained = NO;
    }
    return self;
}

- (void)dealloc {
    [self stopMonitoring];
}

- (BOOL)isReachable {
    __block BOOL result;
    dispatch_sync(_syncQueue, ^{
        // Fail open until the path monitor delivers its first update;
        // otherwise the first query after startup falsely reports offline.
        result = _hasReceivedUpdate ? _reachable : YES;
    });
    return result;
}

- (BOOL)isExpensive {
    __block BOOL result;
    dispatch_sync(_syncQueue, ^{
        result = _expensive;
    });
    return result;
}

- (BOOL)isConstrained {
    __block BOOL result;
    dispatch_sync(_syncQueue, ^{
        result = _constrained;
    });
    return result;
}

- (void)startMonitoring {
    dispatch_sync(_syncQueue, ^{
        if (_isMonitoring) {
            return;
        }
        _isMonitoring = YES;
    });

    _monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(_monitor, _monitorQueue);

    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(_monitor, ^(nw_path_t path) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        nw_path_status_t status = nw_path_get_status(path);
        BOOL newReachable = (status == nw_path_status_satisfied ||
                            status == nw_path_status_satisfiable);
        BOOL newExpensive = nw_path_is_expensive(path);
        BOOL newConstrained = nw_path_is_constrained(path);

        __block BOOL wasReachable;
        dispatch_sync(strongSelf->_syncQueue, ^{
            wasReachable = strongSelf->_reachable;
            strongSelf->_reachable = newReachable;
            strongSelf->_hasReceivedUpdate = YES;
            strongSelf->_expensive = newExpensive;
            strongSelf->_constrained = newConstrained;
        });

        if (wasReachable != newReachable) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:JLNetworkReachabilityChangedNotification
                                  object:strongSelf
                                userInfo:@{@"isReachable": @(newReachable)}];
            });
        }
    });

    nw_path_monitor_start(_monitor);
}

- (void)stopMonitoring {
    dispatch_sync(_syncQueue, ^{
        if (!_isMonitoring) {
            return;
        }
        _isMonitoring = NO;
    });

    if (_monitor) {
        nw_path_monitor_cancel(_monitor);
        _monitor = nil;
    }
}

@end
