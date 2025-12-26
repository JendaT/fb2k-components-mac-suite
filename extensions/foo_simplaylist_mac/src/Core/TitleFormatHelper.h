//
//  TitleFormatHelper.h
//  foo_simplaylist_mac
//
//  THIN wrapper for SDK titleformat_compiler
//  DO NOT implement custom parsing - SDK handles everything
//

#pragma once
#include "../fb2k_sdk.h"
#include <string>
#include <unordered_map>
#include <mutex>

namespace simplaylist {

class TitleFormatHelper {
public:
    // Compile a pattern with fallback on error
    static titleformat_object::ptr compile(const char* pattern) {
        titleformat_object::ptr tf;
        titleformat_compiler::get()->compile_safe_ex(tf, pattern, "%filename%");
        return tf;
    }

    // Compile with caching (patterns are often reused)
    static titleformat_object::ptr compileWithCache(const std::string& pattern) {
        std::lock_guard<std::mutex> lock(s_cacheMutex);

        auto it = s_cache.find(pattern);
        if (it != s_cache.end()) {
            return it->second;
        }

        titleformat_object::ptr tf = compile(pattern.c_str());
        s_cache[pattern] = tf;
        return tf;
    }

    // Format a track using compiled script
    static std::string format(metadb_handle_ptr track, titleformat_object::ptr script) {
        if (!track.is_valid() || script.is_empty()) {
            return "";
        }

        pfc::string8 out;
        track->format_title(nullptr, out, script, nullptr);
        return std::string(out.c_str());
    }

    // Format a track with a pattern string (compiles and caches)
    static std::string formatWithPattern(metadb_handle_ptr track, const std::string& pattern) {
        titleformat_object::ptr script = compileWithCache(pattern);
        return format(track, script);
    }

    // Clear the cache (call on shutdown or major config changes)
    static void clearCache() {
        std::lock_guard<std::mutex> lock(s_cacheMutex);
        s_cache.clear();
    }

private:
    static std::unordered_map<std::string, titleformat_object::ptr> s_cache;
    static std::mutex s_cacheMutex;
};

} // namespace simplaylist
