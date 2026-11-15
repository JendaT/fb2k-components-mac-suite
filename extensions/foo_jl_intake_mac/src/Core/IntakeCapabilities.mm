//
//  IntakeCapabilities.mm
//  foo_jl_intake
//

#include "IntakeCapabilities.h"

#include "IntakeSemver.h"

#include <algorithm>

namespace intake {

namespace {

std::string utf8(NSString *text) {
    const char *bytes = text.UTF8String;
    return bytes ? std::string(bytes) : std::string();
}

} // anonymous namespace

CliVersionInfo parseCliVersionInfo(id data) {
    CliVersionInfo info;
    @autoreleasepool {
        if (![data isKindOfClass:[NSDictionary class]]) return info;
        NSDictionary *dict = data;
        id cli = dict[@"cli"];
        if ([cli isKindOfClass:[NSString class]]) info.cli = utf8(cli);
        id commands = dict[@"commands"];
        if ([commands isKindOfClass:[NSArray class]]) {
            info.hasCommands = true;
            for (id entry in (NSArray *)commands) {
                if ([entry isKindOfClass:[NSString class]]) info.commands.push_back(utf8(entry));
            }
        }
    }
    return info;
}

bool cliSupportsCommand(const CliVersionInfo &info, CliCommand command) {
    if (info.hasCommands) {
        const std::string word = cliCommandWord(command);
        return std::find(info.commands.begin(), info.commands.end(), word) != info.commands.end();
    }
    switch (command) {
        case CliCommand::Reject: return cliSupportsReject(info.cli);
        case CliCommand::Resume: return cliSupportsPerRootResume(info.cli);
        case CliCommand::Income: return false;
        case CliCommand::Version:
        case CliCommand::Status:
        case CliCommand::Collections:
        case CliCommand::Propose:
        case CliCommand::Assign:
        case CliCommand::Approve:
        case CliCommand::Execute:
        case CliCommand::Gc:
            return true;
    }
    return false;
}

} // namespace intake
