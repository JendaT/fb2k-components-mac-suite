//
//  IntakeWatchFilter.mm
//  foo_jl_intake
//

#include "IntakeWatchFilter.h"

#include <utility>

namespace intake {

namespace {

constexpr std::string_view kWholeDirectorySidecar = ".intake.json";
constexpr std::string_view kSidecarPrefix = ".intake.";
constexpr std::string_view kSidecarSuffix = ".json";

char asciiLower(char c) {
    return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
}

bool equalsIgnoringAsciiCase(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++) {
        if (asciiLower(a[i]) != asciiLower(b[i])) return false;
    }
    return true;
}

// [a-z0-9_] with the regex's i flag.
bool isIdChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

} // anonymous namespace

bool isSidecarFileName(std::string_view name) {
    if (name == kWholeDirectorySidecar) return true;
    // /^\.intake\.[a-z0-9_]+\.json$/i
    const size_t fixed = kSidecarPrefix.size() + kSidecarSuffix.size();
    if (name.size() <= fixed) return false;
    if (!equalsIgnoringAsciiCase(name.substr(0, kSidecarPrefix.size()), kSidecarPrefix)) return false;
    if (!equalsIgnoringAsciiCase(name.substr(name.size() - kSidecarSuffix.size()), kSidecarSuffix)) return false;
    const std::string_view id = name.substr(kSidecarPrefix.size(), name.size() - fixed);
    for (char c : id) {
        if (!isIdChar(c)) return false;
    }
    return !id.empty();
}

std::string_view pathFileName(std::string_view path) {
    const size_t slash = path.rfind('/');
    return slash == std::string_view::npos ? path : path.substr(slash + 1);
}

bool sidecarEventDirectory(std::string_view path, std::string &directory) {
    directory.clear();
    const size_t slash = path.rfind('/');
    if (slash == std::string_view::npos) return false;
    if (!isSidecarFileName(path.substr(slash + 1))) return false;
    directory.assign(slash == 0 ? std::string_view("/") : path.substr(0, slash));
    return true;
}

bool WatchBatchBuilder::addPath(std::string_view path) {
    std::string directory;
    if (!sidecarEventDirectory(path, directory)) return false;
    batch_.sidecarEvents++;
    if (seen_.insert(directory).second) batch_.directories.push_back(std::move(directory));
    return true;
}

WatchBatch WatchBatchBuilder::take() {
    WatchBatch out = std::move(batch_);
    batch_ = WatchBatch();
    seen_.clear();
    return out;
}

} // namespace intake
