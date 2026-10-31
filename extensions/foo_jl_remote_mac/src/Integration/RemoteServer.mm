//
//  RemoteServer.mm
//  foo_jl_remote_mac
//

#include "../fb2k_sdk.h"
#import "RemoteServer.h"

#include "PlayerBridge.h"
#include "../Core/HttpRequest.h"
#include "../Core/NetworkPolicy.h"
#include "../Core/RemoteApi.h"
#include "../Core/RemoteConfig.h"

#import <Network/Network.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>

#include <atomic>
#include <memory>

NSString* const RemoteServerStatusChangedNotification = @"RemoteServerStatusChanged";

namespace {

// A connection that has not delivered a full request by then is dropped.
constexpr int64_t kConnectionTimeoutSec = 15;
constexpr uint32_t kMaxReceiveChunk = 64 * 1024;

// Set at shutdown so queued main-thread work stops touching playback services.
std::atomic<bool> g_shuttingDown{false};

std::string remoteAddress(nw_connection_t connection) {
    nw_endpoint_t endpoint = nw_connection_copy_endpoint(connection);
    if (!endpoint || nw_endpoint_get_type(endpoint) != nw_endpoint_type_address) return {};
    const struct sockaddr* sa = nw_endpoint_get_address(endpoint);
    if (!sa) return {};

    char buf[INET6_ADDRSTRLEN] = {0};
    if (sa->sa_family == AF_INET) {
        inet_ntop(AF_INET, &((const struct sockaddr_in*)sa)->sin_addr, buf, sizeof(buf));
    } else if (sa->sa_family == AF_INET6) {
        inet_ntop(AF_INET6, &((const struct sockaddr_in6*)sa)->sin6_addr, buf, sizeof(buf));
    }
    return buf;
}

remote_http::Response errorResponse(int status) {
    remote_http::Response r;
    r.status = status;
    r.body = remote_http::reasonPhrase(status);
    return r;
}

remote_http::Response indexResponse() {
    NSBundle* bundle = [NSBundle bundleForClass:[RemoteServer class]];
    NSString* path = [bundle pathForResource:@"index" ofType:@"html" inDirectory:@"web"];
    NSData* data = path ? [NSData dataWithContentsOfFile:path] : nil;
    if (!data) return errorResponse(500);

    remote_http::Response r;
    r.contentType = "text/html; charset=utf-8";
    r.headers.push_back({"Cache-Control", "no-cache"});
    r.headers.push_back({"Content-Security-Policy",
        "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
        "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'"});
    r.body.assign((const char*)data.bytes, data.length);
    return r;
}

void sendAndClose(nw_connection_t connection, const remote_http::Response& response) {
    const std::string bytes = remote_http::serialize(response);
    dispatch_data_t data = dispatch_data_create(bytes.data(), bytes.size(), nullptr,
                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t) {
        // Graceful close: pending bytes are flushed first.
        nw_connection_cancel(connection);
    });
}

void handleRequest(nw_connection_t connection, const remote_http::Request& request,
                   const std::string& clientIp, dispatch_queue_t queue) {
    const remote_api::Decision decision = remote_api::decide(request, clientIp);
    if (decision.errorStatus != 0) {
        sendAndClose(connection, errorResponse(decision.errorStatus));
        return;
    }
    if (decision.route == remote_api::Route::Index) {
        sendAndClose(connection, indexResponse());
        return;
    }

    const remote_api::Route route = decision.route;
    // Blocks capture C++ references as references: copy the request so the
    // main-thread block does not read the caller's destroyed parse result.
    const remote_http::Request requestCopy = request;
    dispatch_async(dispatch_get_main_queue(), ^{
        const remote_http::Response response = g_shuttingDown
            ? errorResponse(503)
            : player_bridge::execute(route, requestCopy);
        dispatch_async(queue, ^{ sendAndClose(connection, response); });
    });
}

void receive(nw_connection_t connection, std::shared_ptr<std::string> buffer,
             std::string clientIp, dispatch_queue_t queue) {
    nw_connection_receive(connection, 1, kMaxReceiveChunk,
        ^(dispatch_data_t content, nw_content_context_t, bool isComplete, nw_error_t error) {
            if (content) {
                dispatch_data_apply(content, ^bool(dispatch_data_t, size_t, const void* ptr, size_t size) {
                    buffer->append((const char*)ptr, size);
                    return true;
                });
            }
            if (error) {
                nw_connection_cancel(connection);
                return;
            }

            const remote_http::ParseResult parsed = remote_http::parseRequest(*buffer);
            switch (parsed.status) {
                case remote_http::ParseStatus::Incomplete:
                    if (isComplete) nw_connection_cancel(connection);
                    else receive(connection, buffer, clientIp, queue);
                    break;
                case remote_http::ParseStatus::Error:
                    sendAndClose(connection, errorResponse(parsed.errorStatus));
                    break;
                case remote_http::ParseStatus::Complete:
                    handleRequest(connection, parsed.request, clientIp, queue);
                    break;
            }
        });
}

void acceptConnection(nw_connection_t connection, dispatch_queue_t queue) {
    const std::string clientIp = remoteAddress(connection);
    // Drop outsiders before reading a byte; decide() checks again per request.
    if (!remote_policy::isLocalNetworkAddress(clientIp)) {
        nw_connection_cancel(connection);
        return;
    }

    nw_connection_set_queue(connection, queue);
    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t) {
        if (state == nw_connection_state_failed) nw_connection_cancel(connection);
    });
    nw_connection_start(connection);

    // Cancelling an already-closed connection is a no-op.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kConnectionTimeoutSec * NSEC_PER_SEC), queue, ^{
        nw_connection_cancel(connection);
    });

    receive(connection, std::make_shared<std::string>(), clientIp, queue);
}

} // namespace

@interface RemoteServer () {
    dispatch_queue_t _queue;
    nw_listener_t _listener;
    int _port;
}
@property (nonatomic, readwrite, copy) NSString *statusText;
@property (nonatomic, readwrite) BOOL isListening;
@end

@implementation RemoteServer

+ (instancetype)shared {
    static RemoteServer* instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[RemoteServer alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("foo_jl_remote.server", DISPATCH_QUEUE_SERIAL);
        _statusText = @"Off";
    }
    return self;
}

- (void)setStatus:(NSString *)text {
    self.statusText = text;
    [[NSNotificationCenter defaultCenter] postNotificationName:RemoteServerStatusChangedNotification object:self];
}

- (void)applyConfig {
    if (!remote_config::isEnabled()) {
        [self stop];
        return;
    }
    const int port = remote_config::port();
    if (_listener && port == _port) return;
    [self stop];
    [self startOnPort:port];
}

- (void)startOnPort:(int)port {
    nw_parameters_t params = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                             NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_reuse_local_address(params, true);

    nw_listener_t listener = nw_listener_create_with_port(std::to_string(port).c_str(), params);
    if (!listener) {
        [self setStatus:[NSString stringWithFormat:@"Could not open port %d", port]];
        return;
    }

    dispatch_queue_t queue = _queue;
    __weak RemoteServer* weakSelf = self;
    nw_listener_set_queue(listener, queue);
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        const int code = error ? nw_error_get_error_code(error) : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf listener:listener changedState:state errorCode:code port:port];
        });
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        acceptConnection(connection, queue);
    });

    _listener = listener;
    _port = port;
    [self setStatus:[NSString stringWithFormat:@"Starting on port %d…", port]];
    nw_listener_start(listener);
}

- (void)listener:(nw_listener_t)listener changedState:(nw_listener_state_t)state
       errorCode:(int)code port:(int)port {
    if (listener != _listener) return;   // A listener we already replaced

    switch (state) {
        case nw_listener_state_ready:
            self.isListening = YES;
            [self setStatus:[NSString stringWithFormat:@"Listening on port %d", port]];
            FB2K_console_formatter() << "[Remote] Listening on port " << port;
            break;
        case nw_listener_state_waiting:
            self.isListening = NO;
            [self setStatus:@"Waiting for the network…"];
            break;
        case nw_listener_state_failed: {
            nw_listener_cancel(listener);
            _listener = nil;
            self.isListening = NO;
            NSString* text = code == EADDRINUSE
                ? [NSString stringWithFormat:@"Port %d is in use by another app", port]
                : [NSString stringWithFormat:@"Could not listen on port %d (%s)", port, strerror(code)];
            [self setStatus:text];
            FB2K_console_formatter() << "[Remote] " << text.UTF8String;
            break;
        }
        default:
            break;
    }
}

- (void)stop {
    if (_listener) {
        nw_listener_cancel(_listener);
        _listener = nil;
    }
    self.isListening = NO;
    [self setStatus:@"Off"];
}

- (void)shutdown {
    g_shuttingDown = true;
    [self stop];
}

- (NSArray<NSString *> *)localURLs {
    NSMutableArray<NSString *>* urls = [NSMutableArray array];
    struct ifaddrs* list = nullptr;
    if (getifaddrs(&list) != 0) return urls;

    for (struct ifaddrs* ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if ((ifa->ifa_flags & (IFF_UP | IFF_RUNNING)) != (IFF_UP | IFF_RUNNING)) continue;
        if (ifa->ifa_flags & IFF_LOOPBACK) continue;

        char buf[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &((const struct sockaddr_in*)ifa->ifa_addr)->sin_addr, buf, sizeof(buf));
        const std::string ip = buf;
        // Self-assigned 169.254.x.x addresses are not reachable from a phone.
        if (!remote_policy::isLocalNetworkAddress(ip) || ip.rfind("169.254.", 0) == 0) continue;

        NSString* url = [NSString stringWithFormat:@"http://%s:%d/", buf, remote_config::port()];
        if (![urls containsObject:url]) [urls addObject:url];
    }
    freeifaddrs(list);
    return urls;
}

@end
