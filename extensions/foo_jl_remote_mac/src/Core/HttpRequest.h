//
//  HttpRequest.h
//  foo_jl_remote_mac
//
//  Minimal HTTP/1.1 request parser and response serializer for the remote
//  control server. SDK-free so it compiles standalone in the unit tests.
//
//  Scope is deliberately narrow: one request per connection, Content-Length
//  bodies only (no chunked encoding), small header and body limits.
//

#pragma once

#include <cstddef>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace remote_http {

constexpr size_t kMaxHeaderBytes = 8 * 1024;
constexpr size_t kMaxBodyBytes = 16 * 1024;

struct Request {
    std::string method;                         // "GET", "POST", ...
    std::string path;                           // Decoded, without the query string
    std::string query;                          // Raw query string, without '?'
    std::map<std::string, std::string> headers; // Lower-case names
    std::string body;

    // Header value by lower-case name; empty when absent.
    std::string header(const std::string& lowerName) const;
};

enum class ParseStatus {
    Incomplete,     // Need more bytes
    Complete,       // request is filled in
    Error           // errorStatus holds the HTTP status to answer with
};

struct ParseResult {
    ParseStatus status = ParseStatus::Incomplete;
    Request request;
    int errorStatus = 0;
};

// Parses the bytes received so far. Call again with the grown buffer while
// the result is Incomplete.
ParseResult parseRequest(const std::string& buffer);

// Percent-decodes a URL component. Returns false on a malformed escape.
// plusAsSpace applies to query strings (form encoding), not to paths.
bool urlDecode(const std::string& in, std::string& out, bool plusAsSpace);

// Splits "a=1&b=two" into decoded key/value pairs. Malformed pairs are skipped;
// a repeated key keeps its first value.
std::map<std::string, std::string> parseQuery(const std::string& query);

struct Response {
    int status = 200;
    std::string contentType = "text/plain; charset=utf-8";
    std::string body;
    std::vector<std::pair<std::string, std::string>> headers;   // Extra headers
};

const char* reasonPhrase(int status);

// Serializes a complete response. Always closes the connection afterwards.
std::string serialize(const Response& response);

} // namespace remote_http
