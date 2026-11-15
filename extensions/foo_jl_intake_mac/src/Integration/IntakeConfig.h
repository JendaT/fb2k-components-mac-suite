//
//  IntakeConfig.h
//  foo_jl_intake
//
//  The component's settings in foobar2000's configStore (knowledge_base/08;
//  never cfg_var), keys under "foo_jl_intake." (PLAN.md 3.9). Every call is
//  wrapped in try/catch: the store may be gone during shutdown
//  (foo_jl_cloud_streamer_mac CloudConfig.mm).
//
//  B3 keys (no preferences page until B5; docs/hidden-options.md):
//   - cli_path (string): the intake CLI. Empty, the default, means not
//     configured: nothing runs and nothing is decorated.
//   - bun_path (string): bun for a .ts CLI; empty: probed.
//   - rules_dir (string): INTAKE_RULES_DIR for the CLI; empty: inherited.
//   - log_level (int 0-2): Error, Info, Debug. Default 1 (2 in DEBUG builds).
//   - decor_stats (int, 0 or 1): the hidden decorate counters (B3
//     "INTAKE_DECOR_STATS"); default 0.
//
//  load() reads every key once (on_init, later the preferences page); the
//  values are kept in memory by the caller and never read on the decorate
//  path.
//
//  Thread-safety: configStore calls belong on the main thread.
//

#pragma once

#import "../fb2k_sdk.h"

#include <cstdint>
#include <string>

namespace intake {

struct IntakeSettings {
    std::string cliPath;
    std::string bunPath;
    std::string rulesDir;
    int logLevel = 1;
    bool decorStats = false;
    bool logFile = false;  // hidden: mirror log lines to ~/Library/Logs/foobar2000/jl_intake.log
};

namespace config {

inline constexpr const char *kPrefix = "foo_jl_intake.";
inline constexpr const char *kCliPath = "cli_path";
inline constexpr const char *kBunPath = "bun_path";
inline constexpr const char *kRulesDir = "rules_dir";
inline constexpr const char *kLogLevel = "log_level";
inline constexpr const char *kDecorStats = "decor_stats";
inline constexpr const char *kLogFile = "log_file";

// `key` without the prefix.
int64_t getInt(const char *key, int64_t defaultValue);
std::string getString(const char *key, const char *defaultValue);
void setInt(const char *key, int64_t value);
void setString(const char *key, const std::string &value);

// 1 (Info), or 2 (Debug) in DEBUG builds (PLAN.md 3.9).
int defaultLogLevel();

// Every key, with surrounding whitespace trimmed from the strings and
// log_level clamped to 0-2.
IntakeSettings load();

} // namespace config

} // namespace intake
