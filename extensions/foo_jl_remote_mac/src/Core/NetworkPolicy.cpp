//
//  NetworkPolicy.cpp
//  foo_jl_remote_mac
//

#include "NetworkPolicy.h"

#include <arpa/inet.h>
#include <cctype>
#include <cstdint>
#include <cstring>

namespace remote_policy {

namespace {

bool isLocalIPv4(const uint8_t a[4]) {
    if (a[0] == 127) return true;                                   // Loopback
    if (a[0] == 10) return true;                                    // 10.0.0.0/8
    if (a[0] == 172 && (a[1] & 0xF0) == 16) return true;            // 172.16.0.0/12
    if (a[0] == 192 && a[1] == 168) return true;                    // 192.168.0.0/16
    if (a[0] == 169 && a[1] == 254) return true;                    // Link-local
    return false;
}

bool isLocalIPv6(const uint8_t a[16]) {
    static const uint8_t loopback[16] = {0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,1};
    if (std::memcmp(a, loopback, 16) == 0) return true;
    if (a[0] == 0xFE && (a[1] & 0xC0) == 0x80) return true;         // fe80::/10 link-local
    if ((a[0] & 0xFE) == 0xFC) return true;                         // fc00::/7 unique-local

    // ::ffff:a.b.c.d (IPv4-mapped)
    static const uint8_t mappedPrefix[12] = {0,0,0,0, 0,0,0,0, 0,0,0xFF,0xFF};
    if (std::memcmp(a, mappedPrefix, 12) == 0) return isLocalIPv4(a + 12);
    return false;
}

std::string toLower(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

bool endsWith(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Host names are letters, digits, hyphens and dots; nothing else is accepted.
bool isPlainHostName(const std::string& s) {
    if (s.empty()) return false;
    for (char c : s) {
        if (!std::isalnum((unsigned char)c) && c != '-' && c != '.') return false;
    }
    return true;
}

} // namespace

bool isLocalNetworkAddress(const std::string& ipIn) {
    std::string ip = ipIn.substr(0, ipIn.find('%'));
    uint8_t v4[4];
    if (inet_pton(AF_INET, ip.c_str(), v4) == 1) return isLocalIPv4(v4);
    uint8_t v6[16];
    if (inet_pton(AF_INET6, ip.c_str(), v6) == 1) return isLocalIPv6(v6);
    return false;
}

bool isAllowedHost(const std::string& hostHeader) {
    std::string host = toLower(hostHeader);
    if (host.empty()) return false;

    if (host[0] == '[') {
        // [ipv6]:port
        const size_t close = host.find(']');
        if (close == std::string::npos) return false;
        const std::string rest = host.substr(close + 1);
        if (!rest.empty() && rest[0] != ':') return false;
        return isLocalNetworkAddress(host.substr(1, close - 1));
    }

    // name-or-ipv4[:port]; a bare IPv6 literal without brackets is invalid here.
    const size_t colon = host.find(':');
    if (colon != std::string::npos) {
        if (host.find(':', colon + 1) != std::string::npos) return false;
        host = host.substr(0, colon);
    }

    uint8_t v4[4];
    if (inet_pton(AF_INET, host.c_str(), v4) == 1) return isLocalIPv4(v4);

    if (!isPlainHostName(host)) return false;
    if (host == "localhost") return true;
    return endsWith(host, ".local") && host.size() > 6;
}

} // namespace remote_policy
