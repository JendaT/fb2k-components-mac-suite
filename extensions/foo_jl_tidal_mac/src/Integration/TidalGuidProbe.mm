//
//  TidalGuidProbe.mm
//  foo_jl_tidal_mac
//
//  Temporary probe: are playlist_manager_v5 GUIDs a reliable persistent
//  playlist identity? Answers Q1-Q12 of
//  docs/design/2026-11-05-playlist-guid-brief.md over two foobar2000 starts:
//  run A (tidal.TI_guid_probe = 1) and run B (= 2). See docs/hidden-options.md.
//
//  The probe creates, renames, reorders and removes only playlists it created
//  itself, tracked by the GUIDs it recorded. User playlists are only read.
//

#import <Foundation/Foundation.h>
#include "TidalGuidProbe.h"
#include "../Core/TidalConfig.h"

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fstream>
#include <functional>
#include <initializer_list>
#include <iterator>
#include <map>
#include <numeric>
#include <set>
#include <string>
#include <sys/time.h>
#include <vector>

namespace tidal {
namespace {

enum ProbeMode { kProbeOff = 0, kProbeRunA = 1, kProbeRunB = 2, kProbeDone = 3 };

// Playlist Organizer adds a tree node for every new playlist name and never
// removes it, so every probe playlist shares this one name.
const char* const kProbeName = "JL GUID probe";
const char* const kProbeRenamed = "JL GUID probe (renamed)";
const char* const kLibraryViewerSelection = "Library Viewer Selection";

// Run A -> run B state. Keys are auto-prefixed "tidal.".
const char* const kStateGuid = "guid_probe.guid";
const char* const kStateItemCount = "guid_probe.item_count";
const char* const kStateFirstPath = "guid_probe.first_path";
const char* const kStateProperty = "guid_probe.property";

// {E106E0D9-7A05-4F9B-8A5B-F1D88881837D}
const GUID kProbePropertyKey = {
    0xe106e0d9, 0x7a05, 0x4f9b, {0x8a, 0x5b, 0xf1, 0xd8, 0x88, 0x81, 0x83, 0x7d}};

#pragma mark - Logging

std::string timestampNow() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    time_t secs = tv.tv_sec;
    struct tm local;
    localtime_r(&secs, &local);
    char date[32];
    strftime(date, sizeof(date), "%Y-%m-%d %H:%M:%S", &local);
    char out[48];
    snprintf(out, sizeof(out), "%s.%03d", date, static_cast<int>(tv.tv_usec / 1000));
    return out;
}

const std::string& logFilePath() {
    static const std::string path = [] {
        NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/foobar2000"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString* file = [dir stringByAppendingPathComponent:@"jl_tidal_guid_probe.log"];
        return std::string(file.fileSystemRepresentation);
    }();
    return path;
}

void emit(bool isError, const std::string& text) {
    const std::string line = "[GUID probe] " + text;
    if (isError) {
        logError(line.c_str());
    } else {
        logInfo(line.c_str());
    }
    if (FILE* f = fopen(logFilePath().c_str(), "a")) {
        fprintf(f, "%s [Tidal] [GUID probe] %s%s\n", timestampNow().c_str(),
                isError ? "ERROR: " : "", text.c_str());
        fclose(f);
    }
}

std::string vformat(const char* fmt, va_list args) {
    va_list copy;
    va_copy(copy, args);
    const int needed = vsnprintf(nullptr, 0, fmt, copy);
    va_end(copy);
    if (needed < 0) return fmt;
    std::vector<char> buf(static_cast<size_t>(needed) + 1);
    vsnprintf(buf.data(), buf.size(), fmt, args);
    return std::string(buf.data(), static_cast<size_t>(needed));
}

__attribute__((format(printf, 1, 2))) void plog(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    const std::string text = vformat(fmt, args);
    va_end(args);
    emit(false, text);
}

__attribute__((format(printf, 1, 2))) void perr(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    const std::string text = vformat(fmt, args);
    va_end(args);
    emit(true, text);
}

#pragma mark - Small helpers

const char* yn(bool value) {
    return value ? "yes" : "no";
}

std::string guidText(const GUID& g) {
    return pfc::print_guid(g).c_str();
}

bool startsWith(const std::string& s, const char* prefix) {
    return s.rfind(prefix, 0) == 0;
}

struct GuidLess {
    bool operator()(const GUID& a, const GUID& b) const { return pfc::guid_compare(a, b) < 0; }
};
using GuidSet = std::set<GUID, GuidLess>;

std::string idList(const std::set<uint32_t>& ids) {
    std::string out;
    for (uint32_t id : ids) {
        if (!out.empty()) out += ",";
        out += std::to_string(id);
    }
    return out;
}

std::string hexDump(const std::vector<uint8_t>& data, size_t maxBytes) {
    std::string out;
    char byte[4];
    for (size_t i = 0; i < data.size() && i < maxBytes; ++i) {
        snprintf(byte, sizeof(byte), i == 0 ? "%02x" : " %02x", data[i]);
        out += byte;
    }
    return out;
}

bool containsBytes(const std::vector<uint8_t>& haystack, const void* needle, size_t length) {
    const uint8_t* begin = static_cast<const uint8_t*>(needle);
    return length > 0 &&
           std::search(haystack.begin(), haystack.end(), begin, begin + length) != haystack.end();
}

// The GUID as it reads in text: Data1..Data3 big-endian, then Data4.
std::vector<uint8_t> guidTextOrderBytes(const GUID& g) {
    std::vector<uint8_t> out;
    const uint32_t d1 = g.Data1;
    const uint16_t d2 = g.Data2;
    const uint16_t d3 = g.Data3;
    for (int shift = 24; shift >= 0; shift -= 8) out.push_back(static_cast<uint8_t>(d1 >> shift));
    out.push_back(static_cast<uint8_t>(d2 >> 8));
    out.push_back(static_cast<uint8_t>(d2 & 0xff));
    out.push_back(static_cast<uint8_t>(d3 >> 8));
    out.push_back(static_cast<uint8_t>(d3 & 0xff));
    for (int i = 0; i < 8; ++i) out.push_back(g.Data4[i]);
    return out;
}

void clearState() {
    if (!core_api::are_services_available()) return;
    fb2k::configStore::ptr store;
    if (!fb2k::configStore::tryGet(store)) return;
    store->deleteConfigString(TidalConfig::getFullKey(kStateGuid).c_str());
    store->deleteConfigInt(TidalConfig::getFullKey(kStateItemCount).c_str());
    store->deleteConfigString(TidalConfig::getFullKey(kStateFirstPath).c_str());
    store->deleteConfigString(TidalConfig::getFullKey(kStateProperty).c_str());
    plog("state keys tidal.guid_probe.* cleared");
}

struct IndexFile {
    bool read = false;
    std::string dir;
    std::map<GUID, std::string, GuidLess> entries;
};

#pragma mark - Probe

class GuidProbe {
public:
    void runA();
    void runB();

private:
    // Shared
    void step(const char* name, const std::function<void()>& body);
    void logThread();
    bool probeInterfaces();
    void recordStart();
    void checkUniqueness(bool perPlaylist);
    void readIndexFile();
    void compareWithIndex();
    void checkActive(const char* label);
    void restoreActive(const char* label, bool logUnchanged);
    bool removeProbeAt(size_t index, const GUID& expected, const char* label, bool allowP);
    void purgeProbeRecycler(const char* label);
    void verifyOrder(const char* label, const std::vector<GUID>& expectedTail);
    void addResult(int question, const std::string& text);
    void printResults(std::initializer_list<int> questions);

    std::vector<GUID> currentOrder();
    std::string nameAt(size_t index);
    std::string itemPath(size_t playlist, size_t item);
    std::set<uint32_t> recyclerIds();
    size_t occurrences(const GUID& g);
    bool readProperty(size_t index, std::string& out);
    void writeProperty(size_t index, const std::string& value);

    // Run A
    void surveyPlaylists();
    void collectSourceItems();
    GUID createProbe(const char* label, const std::string& propertyValue, size_t& outIndex);
    void createP();
    void createT();
    void renameT();
    void reorderPT();
    void duplicateD1();
    void readSideInfo();
    void duplicateD2();
    void removeDuplicates();
    void removeT();
    void restoreT();
    void cleanupA();

    // Run B
    void checkPAfterRestart();
    void cleanupB();

    playlist_manager_v5::ptr m_pm;
    bool m_recorded = false;
    size_t m_startActive = SIZE_MAX;
    GUID m_startActiveGuid = pfc::guid_null;
    std::vector<GUID> m_startOrder;
    GuidSet m_protected;  // playlists the probe must never remove
    std::set<uint32_t> m_startRecyclerIds;
    IndexFile m_index;
    std::map<int, std::string> m_results;

    metadb_handle_list m_items;
    std::vector<GUID> m_created;  // every playlist the probe created, in order
    GUID m_gP = pfc::guid_null;
    GUID m_gT = pfc::guid_null;
    GUID m_gD1 = pfc::guid_null;
    GUID m_gD2 = pfc::guid_null;
    size_t m_d1Index = SIZE_MAX;
    size_t m_d2Index = SIZE_MAX;
    std::string m_propP;
    std::string m_propT;
    std::string m_savedProp;
    bool m_stateSaved = false;
    std::vector<uint8_t> m_sideInfo;
    bool m_tRemoved = false;
    std::set<uint32_t> m_recyclerBeforeT;
    std::set<uint32_t> m_recyclerAfterT;
};

#pragma mark - Shared helpers

void GuidProbe::step(const char* name, const std::function<void()>& body) {
    try {
        body();
    } catch (std::exception const& e) {
        perr("%s failed: %s", name, e.what());
    } catch (...) {
        perr("%s failed: unknown exception", name);
    }
}

std::vector<GUID> GuidProbe::currentOrder() {
    std::vector<GUID> out;
    const size_t count = m_pm->get_playlist_count();
    out.reserve(count);
    for (size_t i = 0; i < count; ++i) out.push_back(m_pm->playlist_get_guid(i));
    return out;
}

std::string GuidProbe::nameAt(size_t index) {
    pfc::string8 name;
    if (!m_pm->playlist_get_name(index, name)) return "";
    return name.c_str();
}

std::string GuidProbe::itemPath(size_t playlist, size_t item) {
    metadb_handle_ptr handle;
    if (!m_pm->playlist_get_item_handle(handle, playlist, item) || !handle.is_valid()) return "";
    return handle->get_path();
}

std::set<uint32_t> GuidProbe::recyclerIds() {
    std::set<uint32_t> ids;
    const size_t count = m_pm->recycler_get_count();
    for (size_t i = 0; i < count; ++i) ids.insert(m_pm->recycler_get_id(i));
    return ids;
}

size_t GuidProbe::occurrences(const GUID& g) {
    const std::vector<GUID> order = currentOrder();
    return static_cast<size_t>(std::count(order.begin(), order.end(), g));
}

bool GuidProbe::readProperty(size_t index, std::string& out) {
    pfc::array_t<t_uint8> data;
    if (!m_pm->playlist_get_property(index, kProbePropertyKey, data)) {
        out.clear();
        return false;
    }
    out.assign(reinterpret_cast<const char*>(data.get_ptr()), data.get_size());
    return true;
}

void GuidProbe::writeProperty(size_t index, const std::string& value) {
    stream_reader_memblock_ref reader(value.data(), value.size());
    m_pm->playlist_set_property(index, kProbePropertyKey, &reader, value.size(), fb2k::noAbort);
}

void GuidProbe::addResult(int question, const std::string& text) {
    std::string& entry = m_results[question];
    if (!entry.empty()) entry += "; ";
    entry += text;
}

void GuidProbe::printResults(std::initializer_list<int> questions) {
    for (int q : questions) {
        auto it = m_results.find(q);
        plog("RESULT Q%d: %s", q,
             it != m_results.end() ? it->second.c_str()
                                   : "not determined (step failed or was skipped; see above)");
    }
}

void GuidProbe::logThread() {
    const bool onMain = core_api::is_main_thread();
    plog("Q12 core_api::is_main_thread() = %s (run scheduled with dispatch_after on the main queue)",
         yn(onMain));
    addResult(12, std::string(onMain ? "main thread only by SDK contract (playlist.h:79); "
                                     : "NOT ON MAIN: ") +
                      "every probe call made from the main queue, is_main_thread() = " + yn(onMain) +
                      "; off-main calls not tested");
}

bool GuidProbe::probeInterfaces() {
    playlist_manager_v3::ptr v3;
    playlist_manager_v4::ptr v4;
    playlist_manager_v5::ptr v5;
    playlist_manager_v6::ptr v6;
    const bool h3 = playlist_manager_v3::tryGet(v3);
    const bool h4 = playlist_manager_v4::tryGet(v4);
    const bool h5 = playlist_manager_v5::tryGet(v5);
    const bool h6 = playlist_manager_v6::tryGet(v6);
    plog("Q1 tryGet: playlist_manager_v3 %s, playlist_manager_v4 %s, playlist_manager_v5 %s, "
         "playlist_manager_v6 %s",
         yn(h3), yn(h4), yn(h5), yn(h6));
    std::string summary = std::string(h5 ? "yes" : "no") + ": tryGet v3 " + yn(h3) + ", v4 " + yn(h4) +
                          ", v5 " + yn(h5) + ", v6 " + yn(h6);
    addResult(1, summary);
    if (h5) m_pm = v5;
    return h5;
}

void GuidProbe::recordStart() {
    m_startOrder = currentOrder();
    m_startActive = m_pm->get_active_playlist();
    m_startActiveGuid =
        m_startActive < m_startOrder.size() ? m_startOrder[m_startActive] : pfc::guid_null;
    m_protected = GuidSet(m_startOrder.begin(), m_startOrder.end());
    m_startRecyclerIds = recyclerIds();
    const std::string activeName = m_startActive < m_startOrder.size() ? nameAt(m_startActive) : "";
    plog("start: %zu playlists; active [%zu] %s \"%s\"; recycler %zu entries, ids [%s]",
         m_startOrder.size(), m_startActive, guidText(m_startActiveGuid).c_str(),
         activeName.c_str(), m_startRecyclerIds.size(), idList(m_startRecyclerIds).c_str());
    m_recorded = true;
}

void GuidProbe::checkUniqueness(bool perPlaylist) {
    const std::vector<GUID> order = currentOrder();
    std::map<GUID, size_t, GuidLess> counts;
    size_t nulls = 0;
    for (size_t i = 0; i < order.size(); ++i) {
        if (perPlaylist) plog("Q2 [%zu] %s", i, guidText(order[i]).c_str());
        if (order[i] == pfc::guid_null) ++nulls;
        ++counts[order[i]];
    }
    size_t duplicated = 0;
    for (const auto& entry : counts) {
        if (entry.second > 1) {
            ++duplicated;
            perr("Q2 GUID %s held by %zu playlists", guidText(entry.first).c_str(), entry.second);
        }
    }
    plog("Q2 %zu playlists, %zu unique GUIDs, %zu guid_null, %zu duplicated GUIDs", order.size(),
         counts.size(), nulls, duplicated);
    const bool ok = counts.size() == order.size() && nulls == 0;
    addResult(2, std::string(ok ? "yes" : "no") + ": " + std::to_string(order.size()) +
                     " playlists, " + std::to_string(counts.size()) + " unique GUIDs, " +
                     std::to_string(nulls) + " guid_null");
}

void GuidProbe::readIndexFile() {
    m_index = IndexFile();
    const char* raw = core_api::get_profile_path();
    std::string profile = raw ? raw : "";
    plog("Q3 core_api::get_profile_path() = \"%s\"", profile.c_str());
    if (startsWith(profile, "file://")) profile.erase(0, 7);
    m_index.dir = profile + "/playlists-v2.0";
    const std::string path = m_index.dir + "/index.txt";

    std::ifstream in(path, std::ios::binary);
    if (!in) {
        perr("Q3 cannot open %s", path.c_str());
        return;
    }
    std::string data((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    const bool bom = data.compare(0, 3, "\xEF\xBB\xBF") == 0;
    if (bom) data.erase(0, 3);
    const bool endsWithNewline = !data.empty() && data.back() == '\n';

    size_t lines = 0, crlf = 0, unparsed = 0, duplicates = 0;
    size_t pos = 0;
    while (pos < data.size()) {
        size_t end = data.find('\n', pos);
        if (end == std::string::npos) end = data.size();
        std::string line = data.substr(pos, end - pos);
        pos = end + 1;
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
            ++crlf;
        }
        if (line.empty()) continue;
        ++lines;
        const size_t colon = line.find(':');
        const std::string guidPart = colon == std::string::npos ? line : line.substr(0, colon);
        const GUID g = pfc::GUID_from_text(guidPart.c_str());
        if (colon == std::string::npos || guidPart.size() != 36 || g == pfc::guid_null) {
            ++unparsed;
            perr("Q3 index.txt line %zu not parsed: \"%s\"", lines, line.c_str());
            continue;
        }
        if (!m_index.entries.emplace(g, line.substr(colon + 1)).second) {
            ++duplicates;
            perr("Q3 index.txt lists %s more than once", guidText(g).c_str());
        }
    }
    m_index.read = true;
    plog("Q3 %s: BOM %s, %zu entries, %zu lines, %zu end in CRLF, last line ends with newline %s, "
         "%zu not parsed, %zu duplicate GUIDs",
         path.c_str(), yn(bom), m_index.entries.size(), lines, crlf, yn(endsWithNewline), unparsed,
         duplicates);
}

void GuidProbe::compareWithIndex() {
    if (!m_index.read) {
        addResult(3, "not determined: index.txt unreadable");
        return;
    }
    const std::vector<GUID> order = currentOrder();
    std::map<GUID, size_t, GuidLess> api;
    for (size_t i = 0; i < order.size(); ++i) api.emplace(order[i], i);

    size_t onlyApi = 0;
    for (size_t i = 0; i < order.size(); ++i) {
        if (m_index.entries.count(order[i]) == 0) {
            ++onlyApi;
            plog("Q3 in API, not in index.txt: [%zu] %s \"%s\"", i, guidText(order[i]).c_str(),
                 nameAt(i).c_str());
        }
    }
    size_t onlyFile = 0, nameMismatches = 0;
    for (const auto& entry : m_index.entries) {
        auto it = api.find(entry.first);
        if (it == api.end()) {
            ++onlyFile;
            plog("Q3 in index.txt, not in API: %s \"%s\"", guidText(entry.first).c_str(),
                 entry.second.c_str());
            continue;
        }
        const std::string apiName = nameAt(it->second);
        if (apiName != entry.second) {
            ++nameMismatches;
            plog("Q3 name differs for %s: API \"%s\", index.txt \"%s\"",
                 guidText(entry.first).c_str(), apiName.c_str(), entry.second.c_str());
        }
    }

    size_t fpliteTotal = 0, fpliteOrphans = 0;
    if (DIR* dir = opendir(m_index.dir.c_str())) {
        const std::string prefix = "playlist-";
        const std::string suffix = ".fplite";
        while (struct dirent* ent = readdir(dir)) {
            const std::string name = ent->d_name;
            if (name.size() != prefix.size() + 36 + suffix.size() || !startsWith(name, prefix.c_str()) ||
                name.compare(name.size() - suffix.size(), suffix.size(), suffix) != 0) {
                continue;
            }
            ++fpliteTotal;
            const GUID g = pfc::GUID_from_text(name.substr(prefix.size(), 36).c_str());
            if (m_index.entries.count(g) == 0) {
                ++fpliteOrphans;
                plog("Q3 %s has no index.txt entry; in API %s", name.c_str(), yn(api.count(g) > 0));
            }
        }
        closedir(dir);
    } else {
        perr("Q3 cannot list %s", m_index.dir.c_str());
    }

    plog("Q3 API %zu GUIDs, index.txt %zu; in API only %zu; in index.txt only %zu; name mismatches "
         "on shared GUIDs %zu; .fplite files %zu, not in index.txt %zu",
         api.size(), m_index.entries.size(), onlyApi, onlyFile, nameMismatches, fpliteTotal,
         fpliteOrphans);
    const bool equal = onlyApi == 0 && onlyFile == 0;
    addResult(3, std::string(equal ? "yes" : "no") + ": API " + std::to_string(api.size()) +
                     ", index.txt " + std::to_string(m_index.entries.size()) + ", in API only " +
                     std::to_string(onlyApi) + ", in index.txt only " + std::to_string(onlyFile) +
                     ", name mismatches " + std::to_string(nameMismatches) +
                     ", .fplite without index entry " + std::to_string(fpliteOrphans));
}

void GuidProbe::restoreActive(const char* label, bool logUnchanged) {
    const size_t current = m_pm->get_active_playlist();
    if (m_startActive == SIZE_MAX) {
        if (current != SIZE_MAX) {
            m_pm->set_active_playlist(SIZE_MAX);
            plog("%s active playlist restored to none (was [%zu])", label, current);
        } else if (logUnchanged) {
            plog("%s active playlist unchanged (none)", label);
        }
        return;
    }
    if (m_startActiveGuid == pfc::guid_null) {
        perr("%s start active playlist had guid_null; not restored", label);
        return;
    }
    const size_t index = m_pm->find_playlist_by_guid(m_startActiveGuid);
    if (index >= m_pm->get_playlist_count()) {
        perr("%s start active playlist %s no longer exists; not restored", label,
             guidText(m_startActiveGuid).c_str());
        return;
    }
    if (current != index) {
        m_pm->set_active_playlist(index);
        plog("%s active playlist restored: [%zu] -> [%zu] %s", label, current, index,
             guidText(m_startActiveGuid).c_str());
    } else if (logUnchanged) {
        plog("%s active playlist unchanged: [%zu] %s", label, index,
             guidText(m_startActiveGuid).c_str());
    }
}

void GuidProbe::checkActive(const char* label) {
    const size_t current = m_pm->get_active_playlist();
    const GUID currentGuid =
        current < m_pm->get_playlist_count() ? m_pm->playlist_get_guid(current) : pfc::guid_null;
    const bool same = m_startActive == SIZE_MAX
                          ? current == SIZE_MAX
                          : (current != SIZE_MAX && currentGuid == m_startActiveGuid);
    if (same) return;
    plog("%s changed the active playlist to [%zu] %s; restoring", label, current,
         guidText(currentGuid).c_str());
    restoreActive(label, false);
}

bool GuidProbe::removeProbeAt(size_t index, const GUID& expected, const char* label, bool allowP) {
    const size_t countBefore = m_pm->get_playlist_count();
    if (index >= countBefore) {
        plog("%s: %s not found (index %zu); nothing removed", label, guidText(expected).c_str(), index);
        return false;
    }
    const GUID actual = m_pm->playlist_get_guid(index);
    const std::string name = nameAt(index);
    if (actual != expected) {
        perr("%s refused: [%zu] holds %s, expected %s", label, index, guidText(actual).c_str(),
             guidText(expected).c_str());
        return false;
    }
    if (m_protected.count(actual) > 0) {
        perr("%s refused: [%zu] %s \"%s\" is a user playlist", label, index,
             guidText(actual).c_str(), name.c_str());
        return false;
    }
    if (actual == m_gP && !allowP) {
        perr("%s refused: [%zu] is P, kept for run B", label, index);
        return false;
    }
    if (!startsWith(name, kProbeName)) {
        perr("%s refused: [%zu] %s is named \"%s\"", label, index, guidText(actual).c_str(),
             name.c_str());
        return false;
    }
    const bool ok = m_pm->remove_playlist(index);
    plog("%s remove_playlist([%zu] %s \"%s\") = %s; count %zu -> %zu", label, index,
         guidText(actual).c_str(), name.c_str(), yn(ok), countBefore, m_pm->get_playlist_count());
    checkActive(label);
    return ok;
}

void GuidProbe::purgeProbeRecycler(const char* label) {
    const size_t count = m_pm->recycler_get_count();
    pfc::bit_array_bittable mask(count);
    std::set<uint32_t> purged;
    for (size_t i = 0; i < count; ++i) {
        const uint32_t id = m_pm->recycler_get_id(i);
        if (m_startRecyclerIds.count(id) > 0) continue;
        pfc::string8 name;
        m_pm->recycler_get_name(i, name);
        if (startsWith(name.c_str(), kProbeName)) {
            mask.set(i, true);
            purged.insert(id);
        } else {
            plog("%s recycler entry id %u \"%s\" is new but not the probe's; left alone", label, id,
                 name.c_str());
        }
    }
    if (!purged.empty()) m_pm->recycler_purge(mask);
    const std::set<uint32_t> after = recyclerIds();
    size_t stillThere = 0;
    for (uint32_t id : purged) stillThere += after.count(id);
    plog("%s recycler_purge ids [%s]; recycler count %zu -> %zu; purged ids still present %zu", label,
         idList(purged).c_str(), count, m_pm->recycler_get_count(), stillThere);
}

void GuidProbe::verifyOrder(const char* label, const std::vector<GUID>& expectedTail) {
    const std::vector<GUID> now = currentOrder();
    std::vector<GUID> userNow, userStart;
    for (const GUID& g : now) {
        if (m_protected.count(g) > 0) userNow.push_back(g);
    }
    for (const GUID& g : m_startOrder) {
        if (m_protected.count(g) > 0) userStart.push_back(g);
    }
    std::vector<GUID> expected = userStart;
    expected.insert(expected.end(), expectedTail.begin(), expectedTail.end());
    const bool userSame = userNow == userStart;
    const bool fullSame = now == expected;
    plog("%s user playlist order unchanged %s (%zu user playlists now, %zu at start); full order == "
         "expected %s (%zu playlists, expected %zu)",
         label, yn(userSame), userNow.size(), userStart.size(), yn(fullSame), now.size(),
         expected.size());
    if (!fullSame) {
        for (size_t i = 0; i < now.size(); ++i) {
            perr("%s order now [%zu] %s \"%s\"", label, i, guidText(now[i]).c_str(), nameAt(i).c_str());
        }
    }
}

#pragma mark - Run A

void GuidProbe::surveyPlaylists() {
    autoplaylist_manager::ptr apm;
    const bool haveApm = autoplaylist_manager::tryGet(apm);
    if (!haveApm) plog("Q11 autoplaylist_manager unavailable on this host; autoplaylist status unknown");

    const size_t count = m_pm->get_playlist_count();
    size_t autos = 0, autosNull = 0, autosInIndex = 0;
    size_t locked = 0, lockedNull = 0, lockedInIndex = 0, tidalLocked = 0;
    for (size_t i = 0; i < count; ++i) {
        const GUID g = m_pm->playlist_get_guid(i);
        const bool isAuto = haveApm && apm->is_client_present(i);
        const bool hasLock = m_pm->playlist_lock_is_present(i);
        pfc::string8 lockName;
        if (hasLock) m_pm->playlist_lock_query_name(i, lockName);
        const bool inIndex = m_index.read && m_index.entries.count(g) > 0;
        std::string lockText = yn(hasLock);
        if (hasLock) lockText += std::string(" \"") + lockName.c_str() + "\"";
        plog("Q11 [%zu] %s \"%s\" items %zu; autoplaylist %s; lock %s; in index.txt %s", i,
             guidText(g).c_str(), nameAt(i).c_str(), m_pm->playlist_get_item_count(i),
             haveApm ? yn(isAuto) : "n/a", lockText.c_str(), m_index.read ? yn(inIndex) : "n/a");
        if (isAuto) {
            ++autos;
            if (g == pfc::guid_null) ++autosNull;
            if (inIndex) ++autosInIndex;
        }
        if (hasLock) {
            ++locked;
            if (g == pfc::guid_null) ++lockedNull;
            if (inIndex) ++lockedInIndex;
            if (strcmp(lockName.c_str(), "TIDAL Sync") == 0) ++tidalLocked;
        }
    }

    std::string lvs = "Library Viewer Selection absent";
    bool foundLvs = false;
    for (size_t i = 0; i < count; ++i) {
        if (nameAt(i) != kLibraryViewerSelection) continue;
        foundLvs = true;
        const GUID g = m_pm->playlist_get_guid(i);
        const bool inIndex = m_index.read && m_index.entries.count(g) > 0;
        plog("Q11 \"%s\" exists: [%zu] %s, guid_null %s, in index.txt %s", kLibraryViewerSelection, i,
             guidText(g).c_str(), yn(g == pfc::guid_null), m_index.read ? yn(inIndex) : "n/a");
        lvs = std::string("Library Viewer Selection present, guid_null ") + yn(g == pfc::guid_null) +
              ", in index.txt " + (m_index.read ? yn(inIndex) : "n/a");
    }
    if (!foundLvs) plog("Q11 \"%s\" exists: no", kLibraryViewerSelection);

    std::string autoText = haveApm ? std::to_string(autos) + " autoplaylists (guid_null " +
                                         std::to_string(autosNull) + ", in index.txt " +
                                         std::to_string(autosInIndex) + ")"
                                   : std::string("autoplaylist status unknown");
    addResult(11, autoText + "; " + std::to_string(locked) + " locked (TIDAL Sync " +
                      std::to_string(tidalLocked) + ", guid_null " + std::to_string(lockedNull) +
                      ", in index.txt " + std::to_string(lockedInIndex) + "); " + lvs);
}

void GuidProbe::collectSourceItems() {
    m_items.remove_all();
    autoplaylist_manager::ptr apm;
    const bool haveApm = autoplaylist_manager::tryGet(apm);
    const size_t count = m_pm->get_playlist_count();
    for (size_t i = 0; i < count && m_items.get_count() == 0; ++i) {
        if (haveApm && apm->is_client_present(i)) continue;
        const size_t items = m_pm->playlist_get_item_count(i);
        if (items == 0) continue;
        for (size_t j = 0; j < items && j < 3; ++j) {
            metadb_handle_ptr handle;
            if (m_pm->playlist_get_item_handle(handle, i, j)) m_items.add_item(handle);
        }
        plog("A4 source: playlist [%zu] %s \"%s\", %zu of %zu items", i,
             guidText(m_pm->playlist_get_guid(i)).c_str(), nameAt(i).c_str(), m_items.get_count(),
             items);
    }
    if (m_items.get_count() == 0) {
        library_manager::ptr library;
        if (library_manager::tryGet(library)) {
            metadb_handle_list all;
            library->get_all_items(all);
            for (size_t j = 0; j < all.get_count() && j < 3; ++j) m_items.add_item(all[j]);
            plog("A4 source: media library, %zu of %zu items", m_items.get_count(), all.get_count());
        }
    }
    if (m_items.get_count() == 0) {
        plog("A4 no source tracks found; probe playlists stay empty");
    }
    for (size_t j = 0; j < m_items.get_count(); ++j) {
        plog("A4 item %zu: %s", j, m_items[j]->get_path());
    }
}

GUID GuidProbe::createProbe(const char* label, const std::string& propertyValue, size_t& outIndex) {
    outIndex = SIZE_MAX;
    const size_t countBefore = m_pm->get_playlist_count();
    const size_t index = m_pm->create_playlist(kProbeName, strlen(kProbeName), SIZE_MAX);
    const size_t countAfter = m_pm->get_playlist_count();
    plog("%s create_playlist(\"%s\", append) = %zu; count %zu -> %zu", label, kProbeName, index,
         countBefore, countAfter);
    if (index >= countAfter) {
        perr("%s create_playlist failed", label);
        return pfc::guid_null;
    }
    const GUID g = m_pm->playlist_get_guid(index);
    m_created.push_back(g);
    outIndex = index;
    const std::string given = nameAt(index);
    plog("%s guid %s; name given \"%s\" (as requested %s); guid_null %s; equals a user playlist's %s",
         label, guidText(g).c_str(), given.c_str(), yn(given == kProbeName), yn(g == pfc::guid_null),
         yn(m_protected.count(g) > 0));
    if (g == pfc::guid_null) perr("%s got guid_null; cleanup cannot find it by GUID", label);

    if (m_items.get_count() > 0) {
        const size_t base = m_pm->playlist_insert_items(index, 0, m_items, pfc::bit_array_false());
        plog("%s playlist_insert_items(%zu items, no selection) = %zu; item count %zu", label,
             m_items.get_count(), base, m_pm->playlist_get_item_count(index));
    }
    if (!propertyValue.empty()) {
        writeProperty(index, propertyValue);
        std::string back;
        const bool have = readProperty(index, back);
        plog("%s playlist_set_property(%s, \"%s\"); read back: present %s, value \"%s\", equal %s",
             label, guidText(kProbePropertyKey).c_str(), propertyValue.c_str(), yn(have), back.c_str(),
             yn(have && back == propertyValue));
    }
    checkActive(label);
    return g;
}

void GuidProbe::createP() {
    m_propP = "jl-guid-probe P " + timestampNow();
    size_t index = SIZE_MAX;
    m_gP = createProbe("A5 P", m_propP, index);
    if (index == SIZE_MAX || m_gP == pfc::guid_null) return;

    const size_t items = m_pm->playlist_get_item_count(index);
    const std::string first = items > 0 ? itemPath(index, 0) : "";
    TidalConfig::setConfigString(kStateGuid, guidText(m_gP));
    TidalConfig::setConfigInt(kStateItemCount, static_cast<int>(items));
    TidalConfig::setConfigString(kStateFirstPath, first);
    TidalConfig::setConfigString(kStateProperty, m_propP);
    m_stateSaved = TidalConfig::getConfigString(kStateGuid, "") == guidText(m_gP);
    plog("A5 state saved %s: guid %s, item count %zu, first path \"%s\", property \"%s\"",
         yn(m_stateSaved), guidText(m_gP).c_str(), items, first.c_str(), m_propP.c_str());
}

void GuidProbe::createT() {
    m_propT = "jl-guid-probe T " + timestampNow();
    size_t index = SIZE_MAX;
    m_gT = createProbe("A6 T", m_propT, index);
}

void GuidProbe::renameT() {
    if (m_gT == pfc::guid_null) {
        plog("A7 skipped: T was not created");
        return;
    }
    bool renamed = true, stable = true, kept = true;
    auto renameTo = [&](const char* label, const char* newName) {
        const size_t index = m_pm->find_playlist_by_guid(m_gT);
        if (index >= m_pm->get_playlist_count()) {
            perr("Q5 %s: T not found by GUID", label);
            renamed = false;
            return;
        }
        const bool ok = m_pm->playlist_rename(index, newName, strlen(newName));
        const GUID after = m_pm->playlist_get_guid(index);
        const size_t found = m_pm->find_playlist_by_guid(m_gT);
        const std::string name = nameAt(index);
        std::string prop;
        const bool have = readProperty(index, prop);
        plog("Q5 %s: playlist_rename([%zu], \"%s\") = %s; name now \"%s\"; guid before %s, after %s, "
             "same %s; find_playlist_by_guid(gT) = %zu, same index %s",
             label, index, newName, yn(ok), name.c_str(), guidText(m_gT).c_str(),
             guidText(after).c_str(), yn(after == m_gT), found, yn(found == index));
        plog("Q10 %s: property present %s, value \"%s\", equal %s", label, yn(have), prop.c_str(),
             yn(have && prop == m_propT));
        renamed = renamed && ok && name == newName;
        stable = stable && after == m_gT && found == index;
        kept = kept && have && prop == m_propT;
    };
    renameTo("rename", kProbeRenamed);
    renameTo("rename back", kProbeName);
    if (!renamed) {
        addResult(5, "not determined: a rename did not take effect");
        addResult(10, "rename: not determined");
        return;
    }
    addResult(5, stable ? "yes: GUID unchanged across rename and rename back, find_playlist_by_guid "
                          "kept returning the same index"
                        : "no: GUID or find_playlist_by_guid changed on rename");
    addResult(10, kept ? "rename: property kept" : "rename: property LOST");
}

void GuidProbe::reorderPT() {
    if (m_gP == pfc::guid_null || m_gT == pfc::guid_null) {
        plog("A8 skipped: P or T missing");
        return;
    }
    const size_t n = m_pm->get_playlist_count();
    if (n < 2 || m_pm->playlist_get_guid(n - 2) != m_gP || m_pm->playlist_get_guid(n - 1) != m_gT) {
        perr("A8 skipped: P and T are not the last two playlists");
        return;
    }
    std::vector<size_t> order(n);
    std::iota(order.begin(), order.end(), size_t{0});
    std::swap(order[n - 2], order[n - 1]);

    const bool ok = m_pm->reorder(order.data(), n);
    const size_t fP = m_pm->find_playlist_by_guid(m_gP);
    const size_t fT = m_pm->find_playlist_by_guid(m_gT);
    const GUID atA = m_pm->playlist_get_guid(n - 2);
    const GUID atB = m_pm->playlist_get_guid(n - 1);
    plog("Q6 reorder(swap [%zu] and [%zu]) = %s; find_playlist_by_guid(gP) = %zu (expect %zu), "
         "find_playlist_by_guid(gT) = %zu (expect %zu); playlist_get_guid(%zu) = %s, "
         "playlist_get_guid(%zu) = %s",
         n - 2, n - 1, yn(ok), fP, n - 1, fT, n - 2, n - 2, guidText(atA).c_str(), n - 1,
         guidText(atB).c_str());
    const bool followed = ok && fP == n - 1 && fT == n - 2 && atA == m_gT && atB == m_gP;
    checkActive("A8 reorder");

    const bool okBack = m_pm->reorder(order.data(), n);
    const size_t bP = m_pm->find_playlist_by_guid(m_gP);
    const size_t bT = m_pm->find_playlist_by_guid(m_gT);
    plog("Q6 reorder back = %s; find_playlist_by_guid(gP) = %zu (expect %zu), "
         "find_playlist_by_guid(gT) = %zu (expect %zu)",
         yn(okBack), bP, n - 2, bT, n - 1);
    checkActive("A8 reorder back");

    std::vector<GUID> expected = m_startOrder;
    expected.push_back(m_gP);
    expected.push_back(m_gT);
    const bool orderOk = currentOrder() == expected;
    plog("Q6 full order after swap back == start order + P + T: %s", yn(orderOk));
    const bool followedBack = okBack && bP == n - 2 && bT == n - 1;
    if (!ok || !okBack) {
        addResult(6, "not determined: reorder returned false");
        return;
    }
    addResult(6, followed && followedBack
                     ? "yes: GUIDs moved with their playlists and find_playlist_by_guid returned the "
                       "new index both ways"
                     : "no: GUID did not follow the playlist on reorder");
}

void GuidProbe::duplicateD1() {
    if (m_gT == pfc::guid_null) {
        plog("A9 D1 skipped: T was not created");
        return;
    }
    m_gD1 = createProbe("A9 D1", "", m_d1Index);
    if (m_d1Index == SIZE_MAX) return;
    std::string prop;
    const bool have = readProperty(m_d1Index, prop);
    plog("Q7 D1 (create_playlist, same name and items): guid %s, equals gT %s, equals gP %s",
         guidText(m_gD1).c_str(), yn(m_gD1 == m_gT), yn(m_gD1 == m_gP));
    plog("Q10 D1 property present %s, value \"%s\"", yn(have), prop.c_str());
    addResult(7, std::string("create_playlist duplicate gets a new GUID: ") + yn(m_gD1 != m_gT));
    addResult(10, std::string("plain duplicate (create_playlist): property ") +
                      (have ? "present" : "not copied"));
}

void GuidProbe::readSideInfo() {
    if (m_gT == pfc::guid_null) {
        plog("A9 side info skipped: T was not created");
        return;
    }
    const size_t index = m_pm->find_playlist_by_guid(m_gT);
    if (index >= m_pm->get_playlist_count()) {
        perr("A9 side info: T not found by GUID");
        return;
    }
    stream_writer_buffer_simple writer;
    m_pm->playlist_get_sideinfo(index, &writer, fb2k::noAbort);
    const t_uint8* begin = writer.m_buffer.get_ptr();
    m_sideInfo.assign(begin, begin + writer.m_buffer.get_size());

    const std::vector<uint8_t> textOrder = guidTextOrderBytes(m_gT);
    const std::string asText = guidText(m_gT);
    plog("Q7 playlist_get_sideinfo(T [%zu]) = %zu bytes; first %zu: %s", index, m_sideInfo.size(),
         std::min<size_t>(m_sideInfo.size(), 64), hexDump(m_sideInfo, 64).c_str());
    plog("Q7 side info contains gT raw bytes %s, gT big-endian bytes %s, gT as text %s, property key "
         "raw bytes %s",
         yn(containsBytes(m_sideInfo, &m_gT, sizeof(GUID))),
         yn(containsBytes(m_sideInfo, textOrder.data(), textOrder.size())),
         yn(containsBytes(m_sideInfo, asText.data(), asText.size())),
         yn(containsBytes(m_sideInfo, &kProbePropertyKey, sizeof(GUID))));
}

void GuidProbe::duplicateD2() {
    if (m_gT == pfc::guid_null) {
        plog("A9 D2 skipped: T was not created");
        return;
    }
    stream_reader_memblock_ref reader(m_sideInfo.data(), m_sideInfo.size());
    const size_t countBefore = m_pm->get_playlist_count();
    const size_t index = m_pm->create_playlist_ex(kProbeName, strlen(kProbeName), SIZE_MAX, m_items,
                                                  &reader, fb2k::noAbort);
    const size_t countAfter = m_pm->get_playlist_count();
    plog("Q7 D2 create_playlist_ex(\"%s\", append, %zu items, %zu bytes of T's side info) = %zu; "
         "count %zu -> %zu",
         kProbeName, m_items.get_count(), m_sideInfo.size(), index, countBefore, countAfter);
    if (index >= countAfter) {
        perr("A9 D2 create_playlist_ex failed");
        return;
    }
    m_gD2 = m_pm->playlist_get_guid(index);
    m_created.push_back(m_gD2);
    m_d2Index = index;
    std::string prop;
    const bool have = readProperty(index, prop);
    plog("Q7 D2 guid %s, equals gT %s; name \"%s\"; items %zu", guidText(m_gD2).c_str(),
         yn(m_gD2 == m_gT), nameAt(index).c_str(), m_pm->playlist_get_item_count(index));
    plog("Q10 D2 property present %s, value \"%s\", equals T's %s", yn(have), prop.c_str(),
         yn(have && prop == m_propT));
    if (m_gD2 == m_gT) {
        std::string holders;
        const std::vector<GUID> order = currentOrder();
        for (size_t i = 0; i < order.size(); ++i) {
            if (order[i] == m_gT) holders += (holders.empty() ? "" : ",") + std::to_string(i);
        }
        plog("Q7 D2 shares T's GUID: playlists holding it [%s]; find_playlist_by_guid(gT) = %zu",
             holders.c_str(), m_pm->find_playlist_by_guid(m_gT));
    }
    checkActive("A9 D2");
    addResult(7, std::string("create_playlist_ex with T's side info gets a new GUID: ") +
                     yn(m_gD2 != m_gT) + (m_gD2 == m_gT ? " (side info CLONES the GUID)" : ""));
    addResult(10, std::string("create_playlist_ex with side info: property ") +
                      (have ? (prop == m_propT ? "copied, same value" : "present, different value")
                            : "not copied"));
}

void GuidProbe::removeDuplicates() {
    // D2 was appended last, so removing it first leaves D1's index intact.
    // A GUID held twice cannot be resolved by find_playlist_by_guid, so such a
    // duplicate is taken by its known index, and only while it is still the
    // last playlist.
    auto resolve = [&](const GUID& g, size_t knownIndex, const char* label) -> size_t {
        if (knownIndex == SIZE_MAX) return SIZE_MAX;
        if (occurrences(g) <= 1) {
            const size_t found = m_pm->find_playlist_by_guid(g);
            plog("A9 %s find_playlist_by_guid = %zu (created at %zu)", label, found, knownIndex);
            return found;
        }
        const size_t count = m_pm->get_playlist_count();
        const bool inPlace =
            knownIndex + 1 == count && m_pm->playlist_get_guid(knownIndex) == g;
        plog("A9 %s GUID %s is held by more than one playlist; known index %zu still last and "
             "matching: %s",
             label, guidText(g).c_str(), knownIndex, yn(inPlace));
        return inPlace ? knownIndex : SIZE_MAX;
    };
    if (m_d2Index != SIZE_MAX) {
        removeProbeAt(resolve(m_gD2, m_d2Index, "D2"), m_gD2, "A9 remove D2", false);
    }
    if (m_d1Index != SIZE_MAX) {
        removeProbeAt(resolve(m_gD1, m_d1Index, "D1"), m_gD1, "A9 remove D1", false);
    }
}

void GuidProbe::removeT() {
    if (m_gT == pfc::guid_null) {
        plog("A10 skipped: T was not created");
        return;
    }
    if (occurrences(m_gT) != 1) {
        perr("A10 skipped: gT is held by %zu playlists", occurrences(m_gT));
        return;
    }
    m_recyclerBeforeT = recyclerIds();
    const size_t index = m_pm->find_playlist_by_guid(m_gT);
    if (!removeProbeAt(index, m_gT, "A10 remove T", false)) return;
    m_tRemoved = true;
    m_recyclerAfterT = recyclerIds();

    const size_t count = m_pm->get_playlist_count();
    const size_t r = m_pm->find_playlist_by_guid(m_gT);
    plog("Q8 find_playlist_by_guid(removed) = %zu (0x%zx); ==SIZE_MAX %s; ==(size_t)pfc_infinite %s; "
         "==pfc::infinite_size %s; <count %s (count %zu)",
         r, r, yn(r == SIZE_MAX), yn(r == static_cast<size_t>(pfc_infinite)),
         yn(r == pfc::infinite_size), yn(r < count), count);
    const size_t rNull = m_pm->find_playlist_by_guid(pfc::guid_null);
    plog("Q8 find_playlist_by_guid(guid_null) = %zu (0x%zx); ==SIZE_MAX %s; <count %s", rNull, rNull,
         yn(rNull == SIZE_MAX), yn(rNull < count));
    const GUID fresh = pfc::createGUID();
    const size_t rFresh = m_pm->find_playlist_by_guid(fresh);
    plog("Q8 find_playlist_by_guid(never existed %s) = %zu (0x%zx); ==SIZE_MAX %s; <count %s",
         guidText(fresh).c_str(), rFresh, rFresh, yn(rFresh == SIZE_MAX), yn(rFresh < count));

    char text[160];
    snprintf(text, sizeof(text),
             "removed -> %zu (0x%zx), ==SIZE_MAX %s; guid_null -> 0x%zx; never existed -> 0x%zx",
             r, r, yn(r == SIZE_MAX), rNull, rFresh);
    addResult(8, text);
}

void GuidProbe::restoreT() {
    if (!m_tRemoved) {
        plog("A11 skipped: T was not removed");
        return;
    }
    std::vector<uint32_t> newIds;
    for (uint32_t id : m_recyclerAfterT) {
        if (m_recyclerBeforeT.count(id) == 0) newIds.push_back(id);
    }
    std::set<uint32_t> newSet(newIds.begin(), newIds.end());
    plog("Q9 recycler ids before T's removal %zu, after %zu; new [%s]", m_recyclerBeforeT.size(),
         m_recyclerAfterT.size(), idList(newSet).c_str());
    if (newIds.empty()) {
        perr("Q9 removing T added no recycler entry");
        addResult(9, "not determined: removing T added no recycler entry");
        return;
    }
    uint32_t id = newIds.front();
    for (uint32_t candidate : newIds) {
        const size_t at = m_pm->recycler_find_by_id(candidate);
        if (at == SIZE_MAX) continue;
        pfc::string8 name;
        m_pm->recycler_get_name(at, name);
        if (startsWith(name.c_str(), kProbeName)) {
            id = candidate;
            break;
        }
    }
    const size_t entry = m_pm->recycler_find_by_id(id);
    if (entry == SIZE_MAX) {
        perr("Q9 recycler_find_by_id(%u) = SIZE_MAX", id);
        return;
    }
    pfc::string8 entryName;
    m_pm->recycler_get_name(entry, entryName);
    metadb_handle_list content;
    m_pm->recycler_get_content(entry, content);
    plog("Q9 recycler entry id %u at [%zu]: name \"%s\", %zu items", id, entry, entryName.c_str(),
         content.get_count());

    const std::vector<GUID> before = currentOrder();
    const GuidSet beforeSet(before.begin(), before.end());
    m_pm->recycler_restore_by_id(id);
    const size_t countAfter = m_pm->get_playlist_count();
    const size_t found = m_pm->find_playlist_by_guid(m_gT);
    plog("Q9 recycler_restore_by_id(%u): count %zu -> %zu; find_playlist_by_guid(gT) = %zu; active "
         "playlist now [%zu]",
         id, before.size(), countAfter, found, m_pm->get_active_playlist());

    GUID restored = pfc::guid_null;
    size_t restoredIndex = SIZE_MAX;
    if (found < countAfter) {
        restored = m_gT;
        restoredIndex = found;
        plog("Q9 restored with the same GUID %s at [%zu] \"%s\", %zu items", guidText(m_gT).c_str(),
             found, nameAt(found).c_str(), m_pm->playlist_get_item_count(found));
    } else {
        for (size_t i = 0; i < countAfter; ++i) {
            const GUID g = m_pm->playlist_get_guid(i);
            if (beforeSet.count(g) > 0) continue;
            plog("Q9 restored as a new GUID %s at [%zu] \"%s\", %zu items", guidText(g).c_str(), i,
                 nameAt(i).c_str(), m_pm->playlist_get_item_count(i));
            m_created.push_back(g);
            if (restoredIndex == SIZE_MAX) {
                restored = g;
                restoredIndex = i;
            }
        }
        if (restoredIndex == SIZE_MAX) perr("Q9 no new playlist found after restore");
    }

    const bool entryGone = m_pm->recycler_find_by_id(id) == SIZE_MAX;
    plog("Q9 recycler_find_by_id(%u) after restore = %zu; entry gone %s", id,
         m_pm->recycler_find_by_id(id), yn(entryGone));
    if (restoredIndex != SIZE_MAX) {
        std::string prop;
        const bool have = readProperty(restoredIndex, prop);
        plog("Q10 restored playlist: property present %s, value \"%s\", equals T's %s", yn(have),
             prop.c_str(), yn(have && prop == m_propT));
        addResult(10, std::string("recycler restore: property ") +
                          (have ? (prop == m_propT ? "kept" : "present, different value") : "LOST"));
        addResult(9, restored == m_gT ? "same GUID after recycler_restore_by_id"
                                      : "NEW GUID after recycler_restore_by_id (" +
                                            guidText(restored) + ")");
        addResult(9, std::string("recycler entry gone after restore: ") + yn(entryGone));
    }
    checkActive("A11 restore");

    if (restored != pfc::guid_null) {
        removeProbeAt(m_pm->find_playlist_by_guid(restored), restored, "A11 remove restored", false);
    }
}

void GuidProbe::cleanupA() {
    step("A12 remove", [&] {
        for (auto it = m_created.rbegin(); it != m_created.rend(); ++it) {
            const GUID g = *it;
            if (g == m_gP || g == pfc::guid_null) continue;
            // Up to three passes: side info may have given two playlists one GUID.
            for (int pass = 0; pass < 3; ++pass) {
                const size_t index = m_pm->find_playlist_by_guid(g);
                if (index >= m_pm->get_playlist_count()) {
                    if (pass == 0) plog("A12 %s not present; nothing to remove", guidText(g).c_str());
                    break;
                }
                if (!removeProbeAt(index, g, "A12 remove", false)) break;
            }
        }
    });

    bool keepP = false;
    step("A12 P", [&] {
        const size_t index =
            m_gP == pfc::guid_null ? SIZE_MAX : m_pm->find_playlist_by_guid(m_gP);
        const bool exists = index < m_pm->get_playlist_count();
        keepP = exists && m_stateSaved;
        if (keepP) {
            plog("A12 keeping P %s at [%zu] for run B", guidText(m_gP).c_str(), index);
            return;
        }
        perr("A12 run B cannot run: P exists %s, state saved %s", yn(exists), yn(m_stateSaved));
        if (exists) removeProbeAt(index, m_gP, "A12 remove P", true);
    });

    step("A12 purge", [&] { purgeProbeRecycler("A12"); });
    step("A12 active", [&] { restoreActive("A12", true); });
    step("A12 order", [&] {
        std::vector<GUID> tail;
        if (keepP) tail.push_back(m_gP);
        verifyOrder("A12", tail);
    });

    const int next = keepP ? kProbeRunB : kProbeDone;
    TidalConfig::setConfigInt(kGuidProbe, next);
    if (!keepP) clearState();
    plog("A12 tidal.%s set to %d%s", kGuidProbe, next,
         keepP ? " (run B at the next start)" : " (run B will not run)");
}

void GuidProbe::runA() {
    plog("run A start (tidal.%s = 1); log file %s", kGuidProbe, logFilePath().c_str());
    logThread();
    bool haveV5 = false;
    step("A0 Q1", [&] { haveV5 = probeInterfaces(); });
    if (haveV5) step("A0 record", [&] { recordStart(); });
    if (!haveV5 || !m_recorded) {
        perr("A0 %s; tidal.%s set to 3, run A stops",
             haveV5 ? "start state could not be recorded" : "playlist_manager_v5 unavailable",
             kGuidProbe);
        TidalConfig::setConfigInt(kGuidProbe, kProbeDone);
        printResults({1, 12});
        return;
    }

    step("A1", [&] { checkUniqueness(true); });
    step("A2", [&] {
        readIndexFile();
        compareWithIndex();
    });
    step("A3", [&] { surveyPlaylists(); });
    step("A4", [&] { collectSourceItems(); });
    step("A5", [&] { createP(); });
    step("A6", [&] { createT(); });
    step("A7", [&] { renameT(); });
    step("A8", [&] { reorderPT(); });
    step("A9 D1", [&] { duplicateD1(); });
    step("A9 side info", [&] { readSideInfo(); });
    step("A9 D2", [&] { duplicateD2(); });
    step("A9 remove", [&] { removeDuplicates(); });
    step("A10", [&] { removeT(); });
    step("A11", [&] { restoreT(); });
    cleanupA();

    printResults({1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12});
}

#pragma mark - Run B

void GuidProbe::checkPAfterRestart() {
    const int savedCount = TidalConfig::getConfigInt(kStateItemCount, -1);
    const std::string savedFirst = TidalConfig::getConfigString(kStateFirstPath, "");
    const size_t count = m_pm->get_playlist_count();

    if (m_gP == pfc::guid_null) {
        perr("Q4 no saved GUID; P cannot be looked up");
        addResult(4, "not determined: no saved GUID");
    } else {
        const size_t index = m_pm->find_playlist_by_guid(m_gP);
        plog("Q4 find_playlist_by_guid(saved gP %s) = %zu (count %zu)", guidText(m_gP).c_str(), index,
             count);
        if (index < count) {
            const std::string name = nameAt(index);
            const size_t items = m_pm->playlist_get_item_count(index);
            const std::string first = items > 0 ? itemPath(index, 0) : "";
            const bool sameName = name == kProbeName;
            const bool sameCount = savedCount >= 0 && items == static_cast<size_t>(savedCount);
            const bool sameFirst = first == savedFirst;
            plog("Q4 P at [%zu]: name \"%s\" (same %s); items %zu (saved %d, same %s); first item "
                 "\"%s\" (same %s)",
                 index, name.c_str(), yn(sameName), items, savedCount, yn(sameCount), first.c_str(),
                 yn(sameFirst));
            std::string prop;
            const bool have = readProperty(index, prop);
            const bool equal = have && prop == m_savedProp;
            plog("Q10 after restart: property present %s, value \"%s\", equals saved \"%s\" %s",
                 yn(have), prop.c_str(), m_savedProp.c_str(), yn(equal));
            const bool ok = sameName && sameCount && sameFirst;
            addResult(4, std::string(ok ? "yes" : "no") +
                             ": found by saved GUID after restart; same name " + yn(sameName) +
                             ", same item count " + yn(sameCount) + ", same first item " +
                             yn(sameFirst));
            addResult(10, std::string("restart: property ") +
                              (have ? (equal ? "kept" : "present, different value") : "LOST"));
        } else {
            addResult(4, "no: saved GUID not found after restart");
            addResult(10, "restart: not determined (P not found by GUID)");
        }
    }

    size_t named = 0;
    for (size_t i = 0; i < count; ++i) {
        if (nameAt(i) != kProbeName) continue;
        ++named;
        const GUID g = m_pm->playlist_get_guid(i);
        plog("Q4 playlist named \"%s\": [%zu] %s, equals saved gP %s, items %zu", kProbeName, i,
             guidText(g).c_str(), yn(g == m_gP), m_pm->playlist_get_item_count(i));
    }
    if (named == 0) plog("Q4 no playlist is named exactly \"%s\"", kProbeName);
}

void GuidProbe::cleanupB() {
    step("B2 remove", [&] {
        bool removedByGuid = false;
        if (m_gP != pfc::guid_null) {
            const size_t index = m_pm->find_playlist_by_guid(m_gP);
            if (index < m_pm->get_playlist_count()) {
                removedByGuid = removeProbeAt(index, m_gP, "B2 remove P", true);
            }
        }
        if (removedByGuid) return;
        plog("B2 P not removed by GUID; removing playlists named exactly \"%s\" instead", kProbeName);
        for (size_t i = m_pm->get_playlist_count(); i-- > 0;) {
            if (nameAt(i) != kProbeName) continue;
            removeProbeAt(i, m_pm->playlist_get_guid(i), "B2 remove by name", true);
        }
    });
    step("B2 purge", [&] { purgeProbeRecycler("B2"); });
    step("B2 active", [&] { restoreActive("B2", true); });
    step("B2 order", [&] { verifyOrder("B2", {}); });
    TidalConfig::setConfigInt(kGuidProbe, kProbeDone);
    clearState();
    plog("B2 tidal.%s set to 3", kGuidProbe);
}

void GuidProbe::runB() {
    plog("run B start (tidal.%s = 2); log file %s", kGuidProbe, logFilePath().c_str());
    logThread();
    bool haveV5 = false;
    step("B0 Q1", [&] { haveV5 = probeInterfaces(); });
    if (!haveV5) {
        perr("B0 playlist_manager_v5 unavailable; tidal.%s set to 3, run B stops", kGuidProbe);
        TidalConfig::setConfigInt(kGuidProbe, kProbeDone);
        clearState();
        printResults({1, 12});
        return;
    }

    const std::string savedGuid = TidalConfig::getConfigString(kStateGuid, "");
    m_gP = savedGuid.empty() ? pfc::guid_null : pfc::GUID_from_text(savedGuid.c_str());
    m_savedProp = TidalConfig::getConfigString(kStateProperty, "");
    plog("B0 saved state: guid \"%s\" (parsed %s), item count %d, first path \"%s\", property \"%s\"",
         savedGuid.c_str(), guidText(m_gP).c_str(), TidalConfig::getConfigInt(kStateItemCount, -1),
         TidalConfig::getConfigString(kStateFirstPath, "").c_str(), m_savedProp.c_str());

    step("B0 record", [&] {
        recordStart();
        // In run B, P and any playlist named exactly like the probe are removable.
        for (size_t i = 0; i < m_startOrder.size(); ++i) {
            const bool isP = m_gP != pfc::guid_null && m_startOrder[i] == m_gP;
            if (isP || nameAt(i) == kProbeName) m_protected.erase(m_startOrder[i]);
        }
    });
    if (!m_recorded) {
        perr("B0 start state could not be recorded; nothing removed; tidal.%s set to 3", kGuidProbe);
        TidalConfig::setConfigInt(kGuidProbe, kProbeDone);
        printResults({1, 12});
        return;
    }

    step("B0 Q2", [&] { checkUniqueness(false); });
    step("B0 Q3", [&] {
        readIndexFile();
        compareWithIndex();
        if (!m_index.read || m_gP == pfc::guid_null) return;
        auto it = m_index.entries.find(m_gP);
        const bool inIndex = it != m_index.entries.end();
        plog("Q3 saved gP %s in index.txt after restart: %s%s%s%s", guidText(m_gP).c_str(),
             yn(inIndex), inIndex ? " (\"" : "", inIndex ? it->second.c_str() : "",
             inIndex ? "\")" : "");
        addResult(3, std::string("P in index.txt after restart: ") + yn(inIndex));
    });
    step("B1", [&] { checkPAfterRestart(); });
    cleanupB();

    printResults({1, 2, 3, 4, 10, 12});
}

} // anonymous namespace

void scheduleGuidProbeIfArmed() {
    const int mode = TidalConfig::getConfigInt(kGuidProbe, kProbeOff);
    if (mode == kProbeOff || mode == kProbeDone) return;
    if (mode != kProbeRunA && mode != kProbeRunB) {
        perr("tidal.%s = %d is not a known value (0-3); nothing runs", kGuidProbe, mode);
        return;
    }
    // Deferred so the UI and the playlists are fully up before the probe runs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       if (!core_api::are_services_available() || core_api::is_shutting_down()) return;
                       try {
                           GuidProbe probe;
                           if (mode == kProbeRunA) {
                               probe.runA();
                           } else {
                               probe.runB();
                           }
                       } catch (std::exception const& e) {
                           perr("run aborted: %s", e.what());
                       } catch (...) {
                           perr("run aborted: unknown exception");
                       }
                   });
}

} // namespace tidal
