//
//  IntakeConfig.h
//  foo_jl_intake
//
//  The component's settings in foobar2000's configStore (knowledge_base/08;
//  never cfg_var), keys under "foo_jl_intake." (PLAN.md 3.9). Every call is
//  wrapped in try/catch: the store may be gone during shutdown
//  (foo_jl_cloud_streamer_mac CloudConfig.mm).
//
//  On the preferences page (B5, IntakePreferencesController):
//   - cli_path (string): the intake CLI. Empty, the default, means not
//     configured: nothing runs and nothing is decorated.
//   - bun_path (string): bun for a .ts CLI; empty: probed.
//   - rules_dir (string): INTAKE_RULES_DIR for the CLI; empty: inherited.
//   - watch_folders (string, B4): extra folders to watch for sidecar
//     changes, one absolute path per line (IntakeSettingsParse
//     parseWatchFolders); default empty.
//   - swap_prefix_from / swap_prefix_to (strings): the library mapping, one
//     prefix pair (NAS path prefix, Mac path prefix; PLAN.md decision 2),
//     validated by validatePrefixPair; Swap and the library index (B9) use
//     it (IntakeSwapPlanner).
//   - log_level (int 0-2): Error, Info, Debug. Default 1 (2 in DEBUG builds).
//   - confirm_reject (int, 0 or 1, B6): Reject… asks first (the albums it
//     affects, an optional reason); 0 rejects at once, with no reason.
//     Default 1.
//   - confirm_gc (int, 0 or 1, B9; on the page since B10): Delete local
//     copy… asks first (the local paths, "Swap, then delete"); 0 runs gc at
//     once. Default 1.
//   - tint_new, tint_review, tint_proposed, tint_approved, tint_placed,
//     tint_rejected (ints, B10): the row colours, sRGB 0xRRGGBBAA; absent:
//     the IntakePalette default, 0: no tint, out of range: the default
//     (IntakeTint.h). They reach the rows only through the loader's
//     palette (IntakeLoader::setPalette).
//  Hidden (docs/hidden-options.md):
//   - decor_stats (int, 0 or 1): the hidden decorate counters (B3
//     "INTAKE_DECOR_STATS"); default 0.
//   - log_file (int, 0 or 1): mirror log lines to a file.
//
//  load() reads every key: once in on_init, and again in IntakeService
//  whenever the preferences page posts IntakeSettingsDidChangeNotification.
//  The values are kept in memory by the caller and never read on the
//  decorate path.
//
//  Thread-safety: configStore calls belong on the main thread.
//

#pragma once

#import "../fb2k_sdk.h"

#include "../Core/IntakeDecorationMap.h"

#include <cstdint>
#include <string>
#include <vector>

namespace intake {

struct IntakeSettings {
    std::string cliPath;
    std::string bunPath;
    std::string rulesDir;
    int logLevel = 1;
    bool decorStats = false;
    bool logFile = false;  // hidden: mirror log lines to ~/Library/Logs/foobar2000/jl_intake.log
    std::vector<std::string> watchFolders;        // absolute paths, in order
    std::vector<std::string> ignoredWatchFolders; // lines that were not absolute paths
    std::string swapPrefixFrom;  // normalizedPrefix; validatePrefixPair decides if it is usable
    std::string swapPrefixTo;
    bool confirmReject = true;   // B6: Reject… shows its confirmation
    bool confirmGc = true;       // B9: Delete local copy… shows its confirmation
    IntakePalette palette;       // B10: the tint_* keys (IntakeTint.h)
    std::vector<std::string> tintProblems;  // one line per malformed tint_* key
};

namespace config {

inline constexpr const char *kPrefix = "foo_jl_intake.";
inline constexpr const char *kCliPath = "cli_path";
inline constexpr const char *kBunPath = "bun_path";
inline constexpr const char *kRulesDir = "rules_dir";
inline constexpr const char *kLogLevel = "log_level";
inline constexpr const char *kDecorStats = "decor_stats";
inline constexpr const char *kLogFile = "log_file";
inline constexpr const char *kWatchFolders = "watch_folders";
inline constexpr const char *kSwapPrefixFrom = "swap_prefix_from";
inline constexpr const char *kSwapPrefixTo = "swap_prefix_to";
inline constexpr const char *kConfirmReject = "confirm_reject";
inline constexpr const char *kConfirmGc = "confirm_gc";

// The preferences page's GUID (Tools > Intake, Main.mm get_guid).
// {B5B6AB95-DB13-45D9-A9F1-A85E014C08C8}
inline constexpr GUID kPreferencesPageGuid = {
    0xb5b6ab95, 0xdb13, 0x45d9, {0xa9, 0xf1, 0xa8, 0x5e, 0x01, 0x4c, 0x08, 0xc8}};

// `key` without the prefix.
int64_t getInt(const char *key, int64_t defaultValue);
std::string getString(const char *key, const char *defaultValue);
void setInt(const char *key, int64_t value);
void setString(const char *key, const std::string &value);
// Removes the key, so it reads as its default again.
void deleteInt(const char *key);

// 1 (Info), or 2 (Debug) in DEBUG builds (PLAN.md 3.9).
int defaultLogLevel();

// Every key, with surrounding whitespace trimmed from the strings
// (trimmedSetting), the swap prefixes lexically cleaned (normalizedPrefix),
// log_level clamped to 0-2, watch_folders split into lines
// (parseWatchFolders) and the tint_* keys read into a palette
// (paletteFromSettings).
IntakeSettings load();

// The tint_* keys alone (the preferences page).
IntakePalette loadPalette();

} // namespace config

} // namespace intake
