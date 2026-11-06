//
//  QueuePersistence.cpp
//  foo_jl_queue_manager
//
//  Format (one entry per line, fields tab-separated):
//    QMQ1
//    <playlist|->\t<item>\t<subsong>\t<escaped path>
//  Paths escape backslash, tab, CR and LF so any byte sequence round-trips.
//

#include "QueuePersistence.h"

#include <cerrno>
#include <cstdlib>

namespace queue_persist {

namespace {

const char* const kHeader = "QMQ1";

std::string escapePath(const std::string& in) {
    std::string out;
    out.reserve(in.size());
    for (char c : in) {
        switch (c) {
            case '\\': out += "\\\\"; break;
            case '\t': out += "\\t"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            default: out += c; break;
        }
    }
    return out;
}

bool unescapePath(const std::string& in, std::string& out) {
    out.clear();
    out.reserve(in.size());
    for (size_t i = 0; i < in.size(); i++) {
        if (in[i] != '\\') {
            out += in[i];
            continue;
        }
        if (++i >= in.size()) return false;
        switch (in[i]) {
            case '\\': out += '\\'; break;
            case 't': out += '\t'; break;
            case 'n': out += '\n'; break;
            case 'r': out += '\r'; break;
            default: return false;
        }
    }
    return true;
}

bool parseUnsigned(const std::string& s, unsigned long long max, unsigned long long& out) {
    if (s.empty() || s.size() > 20) return false;
    for (char c : s) {
        if (c < '0' || c > '9') return false;
    }
    errno = 0;
    char* end = nullptr;
    unsigned long long v = std::strtoull(s.c_str(), &end, 10);
    if (errno != 0 || *end != '\0' || v > max) return false;
    out = v;
    return true;
}

bool parseLine(const std::string& line, SavedEntry& out) {
    // Split into exactly four fields; the path is last and cannot contain
    // a raw tab (escaped), so splitting on the first three tabs is exact.
    size_t t1 = line.find('\t');
    if (t1 == std::string::npos) return false;
    size_t t2 = line.find('\t', t1 + 1);
    if (t2 == std::string::npos) return false;
    size_t t3 = line.find('\t', t2 + 1);
    if (t3 == std::string::npos) return false;

    std::string playlistField = line.substr(0, t1);
    std::string itemField = line.substr(t1 + 1, t2 - t1 - 1);
    std::string subsongField = line.substr(t2 + 1, t3 - t2 - 1);
    std::string pathField = line.substr(t3 + 1);

    SavedEntry e;
    unsigned long long v = 0;

    if (playlistField == "-") {
        e.playlist = kNoPlaylist;
    } else {
        if (!parseUnsigned(playlistField, kNoPlaylist - 1, v)) return false;
        e.playlist = (size_t)v;
    }

    if (!parseUnsigned(itemField, kNoPlaylist - 1, v)) return false;
    e.item = (size_t)v;

    if (!parseUnsigned(subsongField, UINT32_MAX, v)) return false;
    e.subsong = (uint32_t)v;

    if (!unescapePath(pathField, e.path) || e.path.empty()) return false;

    out = std::move(e);
    return true;
}

} // namespace

std::string serialize(const std::vector<SavedEntry>& entries) {
    std::string out = kHeader;
    out += '\n';
    for (const auto& e : entries) {
        if (e.playlist == kNoPlaylist) {
            out += "-\t0";
        } else {
            out += std::to_string(e.playlist);
            out += '\t';
            out += std::to_string(e.item);
        }
        out += '\t';
        out += std::to_string(e.subsong);
        out += '\t';
        out += escapePath(e.path);
        out += '\n';
    }
    return out;
}

std::vector<SavedEntry> deserialize(const std::string& blob) {
    std::vector<SavedEntry> result;

    size_t pos = 0;
    bool first = true;
    while (pos < blob.size()) {
        size_t nl = blob.find('\n', pos);
        if (nl == std::string::npos) nl = blob.size();
        std::string line = blob.substr(pos, nl - pos);
        pos = nl + 1;

        if (first) {
            if (line != kHeader) return {};
            first = false;
            continue;
        }
        if (line.empty()) continue;

        SavedEntry e;
        if (parseLine(line, e)) {
            result.push_back(std::move(e));
        }
    }
    return result;
}

} // namespace queue_persist
