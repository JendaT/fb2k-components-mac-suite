//
//  IntakeConfig.mm
//  foo_jl_intake
//

#include "IntakeConfig.h"

#include "../Core/IntakeLog.h"
#include "../Core/IntakeSettingsParse.h"
#include "../Core/IntakeTint.h"

namespace intake {
namespace config {

namespace {

pfc::string8 fullKey(const char *key) {
    pfc::string8 out;
    out << kPrefix << key;
    return out;
}

PaletteSettings readPalette() {
    return paletteFromSettings([](const char *key) { return getInt(key, kTintSettingAbsent); });
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

void deleteInt(const char *key) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) store->deleteConfigInt(fullKey(key).c_str());
    } catch (...) {
        logError(std::string("could not reset the setting ") + key);
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
    s.cliPath = trimmedSetting(getString(kCliPath, ""));
    s.bunPath = trimmedSetting(getString(kBunPath, ""));
    s.rulesDir = trimmedSetting(getString(kRulesDir, ""));
    int64_t level = getInt(kLogLevel, defaultLogLevel());
    if (level < 0) level = 0;
    if (level > 2) level = 2;
    s.logLevel = static_cast<int>(level);
    s.decorStats = getInt(kDecorStats, 0) != 0;
    s.logFile = getInt(kLogFile, 0) != 0;
    WatchFolderList folders = parseWatchFolders(getString(kWatchFolders, ""));
    s.watchFolders = std::move(folders.folders);
    s.ignoredWatchFolders = std::move(folders.ignored);
    ShareLinkList links = parseShareLinks(getString(kShareLinks, ""));
    s.shareLinks = std::move(links.links);
    s.ignoredShareLinks = std::move(links.ignored);
    s.swapPrefixFrom = normalizedPrefix(getString(kSwapPrefixFrom, ""));
    s.swapPrefixTo = normalizedPrefix(getString(kSwapPrefixTo, ""));
    s.confirmReject = confirmSetting(getInt(kConfirmReject, kConfirmSettingDefault));
    s.confirmGc = confirmSetting(getInt(kConfirmGc, kConfirmSettingDefault));
    s.autoScan = autoScanSetting(getInt(kAutoScan, kAutoScanSettingDefault));
    PaletteSettings tints = readPalette();
    s.palette = tints.palette;
    s.tintProblems = std::move(tints.problems);
    return s;
}

IntakePalette loadPalette() {
    return readPalette().palette;
}

} // namespace config
} // namespace intake
