//
//  HttpRequest.cpp
//  foo_jl_remote_mac
//

#include "HttpRequest.h"

#include <cctype>
#include <cstdlib>

namespace remote_http {

namespace {

std::string toLower(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

std::string trim(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t')) --e;
    return s.substr(b, e - b);
}

int hexValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

ParseResult error(int status) {
    ParseResult r;
    r.status = ParseStatus::Error;
    r.errorStatus = status;
    return r;
}

// Content-Length must be plain digits; anything else is a malformed request.
bool parseContentLength(const std::string& value, size_t& out) {
    if (value.empty() || value.size() > 9) return false;
    for (char c : value) {
        if (c < '0' || c > '9') return false;
    }
    out = (size_t)std::strtoul(value.c_str(), nullptr, 10);
    return true;
}

} // namespace

std::string Request::header(const std::string& lowerName) const {
    auto it = headers.find(lowerName);
    return it == headers.end() ? std::string() : it->second;
}

ParseResult parseRequest(const std::string& buffer) {
    const size_t headerEnd = buffer.find("\r\n\r\n");
    if (headerEnd == std::string::npos) {
        if (buffer.size() > kMaxHeaderBytes) return error(431);
        return ParseResult{};
    }
    if (headerEnd > kMaxHeaderBytes) return error(431);

    ParseResult result;
    Request& req = result.request;

    // Request line: METHOD SP TARGET SP VERSION
    const size_t lineEnd = buffer.find("\r\n");
    const std::string requestLine = buffer.substr(0, lineEnd);
    const size_t sp1 = requestLine.find(' ');
    const size_t sp2 = sp1 == std::string::npos ? std::string::npos : requestLine.find(' ', sp1 + 1);
    if (sp1 == std::string::npos || sp2 == std::string::npos || sp1 == 0) return error(400);
    if (requestLine.find(' ', sp2 + 1) != std::string::npos) return error(400);

    req.method = requestLine.substr(0, sp1);
    const std::string target = requestLine.substr(sp1 + 1, sp2 - sp1 - 1);
    const std::string version = requestLine.substr(sp2 + 1);
    if (version != "HTTP/1.1" && version != "HTTP/1.0") return error(400);
    if (target.empty() || target[0] != '/') return error(400);

    const size_t q = target.find('?');
    const std::string rawPath = target.substr(0, q);
    if (q != std::string::npos) req.query = target.substr(q + 1);
    if (!urlDecode(rawPath, req.path, false)) return error(400);
    if (req.path.find('\0') != std::string::npos) return error(400);

    // Header fields
    size_t pos = lineEnd + 2;
    while (pos < headerEnd) {
        size_t eol = buffer.find("\r\n", pos);
        if (eol == std::string::npos || eol > headerEnd) eol = headerEnd;
        const std::string line = buffer.substr(pos, eol - pos);
        pos = eol + 2;

        const size_t colon = line.find(':');
        if (colon == std::string::npos || colon == 0) return error(400);
        const std::string name = line.substr(0, colon);
        if (name.find(' ') != std::string::npos || name.find('\t') != std::string::npos) return error(400);
        req.headers.emplace(toLower(name), trim(line.substr(colon + 1)));
    }

    if (!req.header("transfer-encoding").empty()) return error(501);

    size_t contentLength = 0;
    const std::string lengthValue = req.header("content-length");
    if (!lengthValue.empty() && !parseContentLength(lengthValue, contentLength)) return error(400);
    if (contentLength > kMaxBodyBytes) return error(413);

    const size_t bodyStart = headerEnd + 4;
    if (buffer.size() < bodyStart + contentLength) return ParseResult{};

    req.body = buffer.substr(bodyStart, contentLength);
    result.status = ParseStatus::Complete;
    return result;
}

bool urlDecode(const std::string& in, std::string& out, bool plusAsSpace) {
    out.clear();
    out.reserve(in.size());
    for (size_t i = 0; i < in.size(); ++i) {
        const char c = in[i];
        if (c == '%') {
            if (i + 2 >= in.size()) return false;
            const int hi = hexValue(in[i + 1]);
            const int lo = hexValue(in[i + 2]);
            if (hi < 0 || lo < 0) return false;
            out.push_back((char)(hi * 16 + lo));
            i += 2;
        } else if (c == '+' && plusAsSpace) {
            out.push_back(' ');
        } else {
            out.push_back(c);
        }
    }
    return true;
}

std::map<std::string, std::string> parseQuery(const std::string& query) {
    std::map<std::string, std::string> out;
    size_t pos = 0;
    while (pos <= query.size()) {
        size_t amp = query.find('&', pos);
        if (amp == std::string::npos) amp = query.size();
        const std::string pair = query.substr(pos, amp - pos);
        pos = amp + 1;
        if (pair.empty()) continue;

        const size_t eq = pair.find('=');
        std::string key, value;
        if (!urlDecode(pair.substr(0, eq), key, true)) continue;
        if (eq != std::string::npos && !urlDecode(pair.substr(eq + 1), value, true)) continue;
        if (key.empty()) continue;
        out.emplace(key, value);
    }
    return out;
}

const char* reasonPhrase(int status) {
    switch (status) {
        case 200: return "OK";
        case 204: return "No Content";
        case 400: return "Bad Request";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 405: return "Method Not Allowed";
        case 413: return "Payload Too Large";
        case 421: return "Misdirected Request";
        case 431: return "Request Header Fields Too Large";
        case 500: return "Internal Server Error";
        case 501: return "Not Implemented";
        case 503: return "Service Unavailable";
        default:  return "Unknown";
    }
}

std::string serialize(const Response& response) {
    std::string out;
    out.reserve(256 + response.body.size());
    out += "HTTP/1.1 " + std::to_string(response.status) + " " + reasonPhrase(response.status) + "\r\n";
    out += "Content-Type: " + response.contentType + "\r\n";
    out += "Content-Length: " + std::to_string(response.body.size()) + "\r\n";
    out += "Connection: close\r\n";
    out += "X-Content-Type-Options: nosniff\r\n";
    for (const auto& h : response.headers) {
        out += h.first + ": " + h.second + "\r\n";
    }
    out += "\r\n";
    out += response.body;
    return out;
}

} // namespace remote_http
