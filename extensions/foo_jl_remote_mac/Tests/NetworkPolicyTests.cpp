//
//  NetworkPolicyTests.cpp
//  foo_jl_remote_mac
//

#include "TestHarness.h"
#include "../src/Core/NetworkPolicy.h"

using namespace remote_policy;

static void testAddresses() {
    g_context = "isLocalNetworkAddress";
    CHECK(isLocalNetworkAddress("127.0.0.1"), "loopback v4");
    CHECK(isLocalNetworkAddress("10.1.2.3"), "10/8");
    CHECK(isLocalNetworkAddress("172.16.0.1"), "172.16/12 low");
    CHECK(isLocalNetworkAddress("172.31.255.255"), "172.16/12 high");
    CHECK(!isLocalNetworkAddress("172.32.0.1"), "just above 172.16/12");
    CHECK(!isLocalNetworkAddress("172.15.0.1"), "just below 172.16/12");
    CHECK(isLocalNetworkAddress("192.168.0.42"), "192.168/16");
    CHECK(isLocalNetworkAddress("169.254.1.1"), "link-local v4");
    CHECK(!isLocalNetworkAddress("8.8.8.8"), "public v4");
    CHECK(!isLocalNetworkAddress("100.64.0.1"), "carrier-grade NAT is not local");
    CHECK(!isLocalNetworkAddress("192.169.0.1"), "near miss");

    CHECK(isLocalNetworkAddress("::1"), "loopback v6");
    CHECK(isLocalNetworkAddress("fe80::1"), "link-local v6");
    CHECK(isLocalNetworkAddress("fe80::1%en0"), "link-local v6 with scope");
    CHECK(isLocalNetworkAddress("fd12:3456::1"), "unique-local v6");
    CHECK(!isLocalNetworkAddress("2001:4860::8888"), "public v6");
    CHECK(isLocalNetworkAddress("::ffff:192.168.1.2"), "mapped private v4");
    CHECK(!isLocalNetworkAddress("::ffff:8.8.8.8"), "mapped public v4");

    CHECK(!isLocalNetworkAddress(""), "empty");
    CHECK(!isLocalNetworkAddress("localhost"), "names are not addresses");
    CHECK(!isLocalNetworkAddress("192.168.1"), "short dotted quad");
}

static void testHosts() {
    g_context = "isAllowedHost";
    CHECK(isAllowedHost("192.168.1.5:8890"), "private v4 with port");
    CHECK(isAllowedHost("192.168.1.5"), "private v4 without port");
    CHECK(isAllowedHost("localhost:8890"), "localhost");
    CHECK(isAllowedHost("LocalHost"), "case-insensitive");
    CHECK(isAllowedHost("my-mac.local:8890"), ".local name");
    CHECK(isAllowedHost("[::1]:8890"), "bracketed v6 with port");
    CHECK(isAllowedHost("[fe80::1]"), "bracketed v6 without port");

    CHECK(!isAllowedHost(""), "missing host");
    CHECK(!isAllowedHost("evil.example.com"), "public name (DNS rebinding)");
    CHECK(!isAllowedHost("evil.example.com:8890"), "public name with port");
    CHECK(!isAllowedHost("8.8.8.8"), "public v4");
    CHECK(!isAllowedHost(".local"), "bare .local");
    CHECK(!isAllowedHost("x.local.evil.com"), ".local not at the end");
    CHECK(!isAllowedHost("::1"), "unbracketed v6");
    CHECK(!isAllowedHost("[::1"), "unterminated bracket");
    CHECK(!isAllowedHost("[::1]x"), "junk after bracket");
    CHECK(!isAllowedHost("[2001:4860::8888]"), "public v6");
    CHECK(!isAllowedHost("a b.local"), "space in name");
}

int main() {
    testAddresses();
    testHosts();
    TEST_MAIN_END();
}
