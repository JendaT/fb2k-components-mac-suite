//
//  HttpRequestTests.cpp
//  foo_jl_remote_mac
//

#include "TestHarness.h"
#include "../src/Core/HttpRequest.h"

using namespace remote_http;

static void testCompleteGet() {
    g_context = "complete GET";
    ParseResult r = parseRequest("GET /api/state?x=1 HTTP/1.1\r\nHost: 192.168.1.5:8890\r\nX-Custom:  v \r\n\r\n");
    CHECK(r.status == ParseStatus::Complete, "complete");
    CHECK(r.request.method == "GET", "method");
    CHECK(r.request.path == "/api/state", "path without query");
    CHECK(r.request.query == "x=1", "query");
    CHECK(r.request.header("host") == "192.168.1.5:8890", "host header");
    CHECK(r.request.header("x-custom") == "v", "header name lower-cased, value trimmed");
    CHECK(r.request.header("missing").empty(), "missing header is empty");
}

static void testIncomplete() {
    g_context = "incomplete";
    CHECK(parseRequest("").status == ParseStatus::Incomplete, "empty");
    CHECK(parseRequest("GET / HTTP/1.1\r\nHost: a").status == ParseStatus::Incomplete, "headers unfinished");

    // Body still arriving
    std::string partial = "POST /api/volume HTTP/1.1\r\nContent-Length: 5\r\n\r\nab";
    CHECK(parseRequest(partial).status == ParseStatus::Incomplete, "body unfinished");
    ParseResult r = parseRequest(partial + "cde");
    CHECK(r.status == ParseStatus::Complete, "body finished");
    CHECK(r.request.body == "abcde", "body");
}

static void testMalformed() {
    g_context = "malformed";
    CHECK_EQ(parseRequest("GET\r\n\r\n").errorStatus, 400, "no target");
    CHECK_EQ(parseRequest("GET / HTTP/2\r\n\r\n").errorStatus, 400, "unsupported version");
    CHECK_EQ(parseRequest("GET api HTTP/1.1\r\n\r\n").errorStatus, 400, "target not absolute path");
    CHECK_EQ(parseRequest("GET / x HTTP/1.1\r\n\r\n").errorStatus, 400, "extra request line token");
    CHECK_EQ(parseRequest("GET / HTTP/1.1\r\nNoColon\r\n\r\n").errorStatus, 400, "header without colon");
    CHECK_EQ(parseRequest("GET / HTTP/1.1\r\nBad Name: x\r\n\r\n").errorStatus, 400, "space in header name");
    CHECK_EQ(parseRequest("GET /%zz HTTP/1.1\r\n\r\n").errorStatus, 400, "bad percent escape");
    CHECK_EQ(parseRequest("GET /a%00b HTTP/1.1\r\n\r\n").errorStatus, 400, "NUL in path");
    CHECK_EQ(parseRequest("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n").errorStatus, 400, "negative length");
    CHECK_EQ(parseRequest("POST / HTTP/1.1\r\nContent-Length: 1x\r\n\r\n").errorStatus, 400, "non-digit length");
    CHECK_EQ(parseRequest("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n").errorStatus, 501, "chunked");
}

static void testLimits() {
    g_context = "limits";
    std::string huge = "GET / HTTP/1.1\r\nX: " + std::string(kMaxHeaderBytes, 'a');
    CHECK_EQ(parseRequest(huge).errorStatus, 431, "unterminated oversized headers");
    CHECK_EQ(parseRequest(huge + "\r\n\r\n").errorStatus, 431, "terminated oversized headers");
    std::string big = "POST / HTTP/1.1\r\nContent-Length: " + std::to_string(kMaxBodyBytes + 1) + "\r\n\r\n";
    CHECK_EQ(parseRequest(big).errorStatus, 413, "body too large");
}

static void testUrlDecode() {
    g_context = "urlDecode";
    std::string out;
    CHECK(urlDecode("a%20b+c", out, false) && out == "a b+c", "path keeps plus");
    CHECK(urlDecode("a%20b+c", out, true) && out == "a b c", "query plus is space");
    CHECK(!urlDecode("%4", out, false), "truncated escape");
    CHECK(!urlDecode("%", out, false), "lone percent");
}

static void testParseQuery() {
    g_context = "parseQuery";
    auto q = parseQuery("db=-42.5&delta=&&flag&x=%2D1&db=0&=v");
    CHECK(q["db"] == "-42.5", "first value wins");
    CHECK(q.count("delta") == 1 && q["delta"].empty(), "empty value");
    CHECK(q.count("flag") == 1, "key without '='");
    CHECK(q["x"] == "-1", "decoded value");
    CHECK(q.count("") == 0, "empty key dropped");
    CHECK(parseQuery("").empty(), "empty query");
}

static void testSerialize() {
    g_context = "serialize";
    Response r;
    r.status = 404;
    r.body = "nope";
    r.headers.push_back({"Cache-Control", "no-store"});
    const std::string s = serialize(r);
    CHECK(s.rfind("HTTP/1.1 404 Not Found\r\n", 0) == 0, "status line");
    CHECK(s.find("Content-Length: 4\r\n") != std::string::npos, "length");
    CHECK(s.find("Connection: close\r\n") != std::string::npos, "connection close");
    CHECK(s.find("Cache-Control: no-store\r\n") != std::string::npos, "extra header");
    CHECK(s.size() >= 8 && s.compare(s.size() - 8, 8, "\r\n\r\nnope") == 0, "body after blank line");
}

int main() {
    testCompleteGet();
    testIncomplete();
    testMalformed();
    testLimits();
    testUrlDecode();
    testParseQuery();
    testSerialize();
    TEST_MAIN_END();
}
