//
//  IntakeCommandArgs.mm
//  foo_jl_intake
//

#include "IntakeCommandArgs.h"

#include "IntakeSemver.h"

#include <sys/stat.h>
#include <unistd.h>

#include <unordered_set>

extern char **environ;

namespace intake {

namespace {

const char *const kStandardPath[] = {
    "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
};

bool hasNul(const std::string &s) {
    return s.find('\0') != std::string::npos;
}

bool endsWith(std::string_view s, std::string_view suffix) {
    return s.size() >= suffix.size() && s.substr(s.size() - suffix.size()) == suffix;
}

// The value of NAME in a "NAME=value" list (first match, like getenv), or
// nullopt.
std::optional<std::string> envValue(const std::vector<std::string> &env, std::string_view name) {
    for (const std::string &entry : env) {
        if (entry.size() > name.size() && entry.compare(0, name.size(), name) == 0 &&
            entry[name.size()] == '=') {
            return entry.substr(name.size() + 1);
        }
    }
    return std::nullopt;
}

// Removes every NAME=... entry, then appends NAME=value.
void setEnv(std::vector<std::string> &env, std::string_view name, const std::string &value) {
    std::vector<std::string> kept;
    kept.reserve(env.size() + 1);
    for (std::string &entry : env) {
        bool match = entry.size() > name.size() && entry.compare(0, name.size(), name) == 0 &&
                     entry[name.size()] == '=';
        if (!match) kept.push_back(std::move(entry));
    }
    kept.push_back(std::string(name) + "=" + value);
    env = std::move(kept);
}

bool isExecutableFile(const std::string &path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode) && access(path.c_str(), X_OK) == 0;
}

bool isReadableFile(const std::string &path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode) && access(path.c_str(), R_OK) == 0;
}

std::string dirName(const std::string &path) {
    size_t slash = path.rfind('/');
    if (slash == std::string::npos) return ".";
    if (slash == 0) return "/";
    return path.substr(0, slash);
}

std::string buildPath(const std::string &bunDir, const std::optional<std::string> &inherited) {
    std::vector<std::string> parts;
    std::unordered_set<std::string> seen;
    auto add = [&](const std::string &dir) {
        if (dir.empty() || seen.count(dir)) return;
        seen.insert(dir);
        parts.push_back(dir);
    };
    if (!bunDir.empty()) add(bunDir);
    for (const char *dir : kStandardPath) add(dir);
    if (inherited) {
        size_t start = 0;
        while (start <= inherited->size()) {
            size_t colon = inherited->find(':', start);
            if (colon == std::string::npos) colon = inherited->size();
            add(inherited->substr(start, colon - start));
            start = colon + 1;
        }
    }
    std::string path;
    for (const std::string &dir : parts) {
        if (!path.empty()) path += ':';
        path += dir;
    }
    return path;
}

CliInvocation refused(std::string message) {
    CliInvocation inv;
    inv.status = BuildStatus::Refused;
    inv.message = std::move(message);
    return inv;
}

// The request on its own: everything a caller could get wrong.
std::string checkRequest(const CliRequest &request) {
    const CliCommand cmd = request.command;
    const std::string name = cliCommandName(cmd);
    const bool mutating = isMutatingCommand(cmd);

    if (mutating && request.ids.empty()) {
        return "refusing " + name + " with no ids: the CLI would act on every root";
    }
    if (!mutating && !request.ids.empty()) return name + " takes no ids";
    for (const std::string &id : request.ids) {
        if (!isSidecarId(id)) return name + ": not a sidecar id: " + id;
    }
    if (request.dryRun && !mutating) return name + " has no --dry-run";

    if (cmd == CliCommand::Assign) {
        if (request.collection.empty()) return "assign needs a collection";
        if (hasNul(request.collection)) return "assign: collection contains a NUL byte";
    } else if (!request.collection.empty()) {
        return name + " takes no collection";
    }

    if (cmd == CliCommand::Reject) {
        if (hasNul(request.reason)) return "reject: reason contains a NUL byte";
    } else if (!request.reason.empty()) {
        return name + " takes no reason";
    }

    if (cmd != CliCommand::Status && !request.filters.empty()) return name + " takes no filters";
    for (const auto &filter : request.filters) {
        // The CLI splits at the first '=' and drops an empty key (cli.ts parseArgs).
        if (filter.first.empty() || filter.first.find('=') != std::string::npos ||
            hasNul(filter.first) || hasNul(filter.second)) {
            return "status: invalid filter key: " + filter.first;
        }
    }
    return std::string();
}

} // anonymous namespace

const char *cliCommandWord(CliCommand command) {
    switch (command) {
        case CliCommand::Version: return "version";
        case CliCommand::Status: return "status";
        case CliCommand::Collections: return "collections";
        case CliCommand::Propose: return "propose";
        case CliCommand::Assign: return "assign";
        case CliCommand::Approve: return "approve";
        case CliCommand::Reject: return "reject";
        case CliCommand::Execute: return "execute";
        case CliCommand::Resume: return "execute";
        case CliCommand::Gc: return "gc";
    }
    return "version";
}

const char *cliCommandName(CliCommand command) {
    return command == CliCommand::Resume ? "resume" : cliCommandWord(command);
}

bool isMutatingCommand(CliCommand command) {
    switch (command) {
        case CliCommand::Version:
        case CliCommand::Status:
        case CliCommand::Collections:
            return false;
        case CliCommand::Propose:
        case CliCommand::Assign:
        case CliCommand::Approve:
        case CliCommand::Reject:
        case CliCommand::Execute:
        case CliCommand::Resume:
        case CliCommand::Gc:
            return true;
    }
    return true;
}

CommandClass commandClass(const CliRequest &request) {
    if (!isMutatingCommand(request.command)) return CommandClass::ReadOnly;
    if (request.dryRun) return CommandClass::DryRun;
    if (request.command == CliCommand::Execute || request.command == CliCommand::Resume) {
        return CommandClass::Detached;
    }
    return CommandClass::Mutating;
}

std::vector<std::string> processEnvironmentSnapshot() {
    std::vector<std::string> env;
    for (char **e = environ; e && *e; e++) env.emplace_back(*e);
    return env;
}

bool isSidecarId(std::string_view text) {
    if (text.size() != 12 || text.substr(0, 4) != "itk_") return false;
    for (char c : text.substr(4)) {
        bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!hex) return false;
    }
    return true;
}

std::vector<std::string> defaultBunSearchDirs(const std::vector<std::string> &environment) {
    std::vector<std::string> dirs;
    std::optional<std::string> home = envValue(environment, "HOME");
    if (home && !home->empty() && (*home)[0] == '/') {
        std::string h = *home;
        while (h.size() > 1 && h.back() == '/') h.pop_back();
        dirs.push_back((h == "/" ? std::string() : h) + "/.bun/bin");
    }
    dirs.push_back("/opt/homebrew/bin");
    dirs.push_back("/usr/local/bin");
    return dirs;
}

CliInvocation buildInvocation(const CliConfig &config, const CliRequest &request) {
    std::string problem = checkRequest(request);
    if (!problem.empty()) return refused(problem);
    if (request.command == CliCommand::Resume && !cliSupportsPerRootResume(config.cliVersion)) {
        return refused("refusing resume: CLI " +
                       (config.cliVersion.empty() ? std::string("version unknown") : config.cliVersion) +
                       "; before 0.2.1 the CLI ignores the ids and resumes every placing root");
    }

    CliInvocation inv;
    inv.commandClass = commandClass(request);

    auto noCli = [&inv](std::string message) {
        inv.status = BuildStatus::NoCli;
        inv.message = std::move(message);
        return inv;
    };

    const std::string &cli = config.cliPath;
    if (cli.empty()) return noCli("no intake CLI path is configured");
    if (hasNul(cli) || cli[0] != '/') return noCli("the intake CLI path must be absolute: " + cli);
    if (hasNul(config.rulesDir)) return noCli("the rules folder path contains a NUL byte");
    if (hasNul(config.bunPath)) return noCli("the bun path contains a NUL byte");
    if (!config.baseEnvironment) return noCli("no environment snapshot was given");

    std::vector<std::string> env = *config.baseEnvironment;
    // Malformed entries (no '=', or a NUL) would only confuse the child.
    std::vector<std::string> cleaned;
    cleaned.reserve(env.size());
    for (std::string &entry : env) {
        size_t eq = entry.find('=');
        if (eq == std::string::npos || eq == 0 || hasNul(entry)) continue;
        cleaned.push_back(std::move(entry));
    }
    env = std::move(cleaned);

    const bool script = endsWith(cli, ".ts");

    // bun: explicit, else probed. A bad explicit bun only matters when the
    // CLI needs bun to start.
    std::string bun;
    bool probe = config.bunPath.empty();
    if (!probe) {
        if (config.bunPath[0] == '/' && isExecutableFile(config.bunPath)) {
            bun = config.bunPath;
        } else if (script) {
            return noCli("bun is not an executable file: " + config.bunPath);
        } else {
            probe = true;
        }
    }
    if (probe) {
        std::vector<std::string> dirs =
            config.bunSearchDirs.empty() ? defaultBunSearchDirs(env) : config.bunSearchDirs;
        for (std::string dir : dirs) {
            if (dir.empty() || dir[0] != '/' || hasNul(dir)) continue;
            while (dir.size() > 1 && dir.back() == '/') dir.pop_back();
            std::string candidate = (dir == "/" ? std::string() : dir) + "/bun";
            if (isExecutableFile(candidate)) {
                bun = candidate;
                break;
            }
        }
    }

    if (script) {
        if (bun.empty()) return noCli("bun was not found; it is needed to run " + cli);
        if (!isReadableFile(cli)) return noCli("the intake CLI script is not a readable file: " + cli);
        inv.executable = bun;
        inv.arguments = {bun, cli};
    } else {
        inv.executable = cli;
        inv.arguments = {cli};
    }

    // Command word, ids, then options, then --json.
    std::vector<std::string> &args = inv.arguments;
    args.push_back(cliCommandWord(request.command));
    std::unordered_set<std::string> seenIds;
    for (const std::string &id : request.ids) {
        if (seenIds.insert(id).second) args.push_back(id);
    }
    if (request.command == CliCommand::Resume) args.push_back("--resume");
    if (request.command == CliCommand::Assign) {
        args.push_back("--collection");
        args.push_back(request.collection);
        args.push_back("--by");
        args.push_back("user");
    }
    if (request.command == CliCommand::Reject && !request.reason.empty()) {
        args.push_back("--reason");
        args.push_back(request.reason);
    }
    for (const auto &filter : request.filters) {
        args.push_back("--filter");
        args.push_back(filter.first + "=" + filter.second);
    }
    if (request.dryRun) args.push_back("--dry-run");
    args.push_back("--json");

    setEnv(env, "PATH", buildPath(bun.empty() ? std::string() : dirName(bun), envValue(env, "PATH")));
    if (!config.rulesDir.empty()) setEnv(env, "INTAKE_RULES_DIR", config.rulesDir);
    inv.environment = std::move(env);
    inv.status = BuildStatus::Ok;
    return inv;
}

} // namespace intake
