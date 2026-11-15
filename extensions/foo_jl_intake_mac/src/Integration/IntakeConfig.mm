//
//  IntakeConfig.mm
//  foo_jl_intake
//

#include "IntakeConfig.h"

#include "../Core/IntakeLog.h"

namespace intake {
namespace config {

namespace {

pfc::string8 fullKey(const char *key) {
    pfc::string8 out;
    out << kPrefix << key;
    return out;
}

std::string trimmed(std::string text) {
    const char *space = " \t\r\n";
    const size_t first = text.find_first_not_of(space);
    if (first == std::string::npos) return std::string();
    const size_t last = text.find_last_not_of(space);
    return text.substr(first, last - first + 1);
}

} // anonymous namespace

int64_t getInt(const char *key, int64_t defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultValue;
        return store->getConfigInt(fullKey(key).c_str(), defaultValue);
    } catch (...) {
        return defaultValue;
    }
}

std::string getString(const char *key, const char *defaultValue) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return std::string(defaultValue);
        fb2k::stringRef value = store->getConfigString(fullKey(key).c_str(), defaultValue);
        return value.is_valid() ? std::string(value->c_str()) : std::string(defaultValue);
    } catch (...) {
        return std::string(defaultValue);
    }
}

void setInt(const char *key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) store->setConfigInt(fullKey(key).c_str(), value);
    } catch (...) {
        logError(std::string("could not save the setting ") + key);
    }
}

void setString(const char *key, const std::string &value) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) store->setConfigString(fullKey(key).c_str(), value.c_str());
    } catch (...) {
        logError(std::string("could not save the setting ") + key);
    }
}

int defaultLogLevel() {
#ifdef DEBUG
    return static_cast<int>(LogLevel::Debug);
#else
    return static_cast<int>(LogLevel::Info);
#endif
}

IntakeSettings load() {
    IntakeSettings s;
    s.cliPath = trimmed(getString(kCliPath, ""));
    s.bunPath = trimmed(getString(kBunPath, ""));
    s.rulesDir = trimmed(getString(kRulesDir, ""));
    int64_t level = getInt(kLogLevel, defaultLogLevel());
    if (level < 0) level = 0;
    if (level > 2) level = 2;
    s.logLevel = static_cast<int>(level);
    s.decorStats = getInt(kDecorStats, 0) != 0;
    return s;
}

} // namespace config
} // namespace intake
