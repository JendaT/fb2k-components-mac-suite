//
//  NetworkPolicy.h
//  foo_jl_remote_mac
//
//  Who may talk to the remote control server. The listener binds on every
//  interface, so these checks are what keeps it local-network only:
//
//  - The client address must be loopback, private (RFC 1918 / IPv6 ULA) or
//    link-local. Anything routed in from the internet is refused.
//  - The Host header must name a local address or a .local name. This stops
//    DNS rebinding, where a web page tricks the browser into sending
//    requests to this server under the page's own hostname.
//

#pragma once

#include <string>

namespace remote_policy {

// True for loopback, RFC 1918, link-local and IPv6 unique-local addresses
// (IPv4-mapped IPv6 is checked as IPv4). A trailing %scope is ignored.
bool isLocalNetworkAddress(const std::string& ip);

// True when the Host header (optionally with :port) names a local-network IP
// literal, "localhost", or a multicast DNS name ending in ".local".
bool isAllowedHost(const std::string& hostHeader);

} // namespace remote_policy
