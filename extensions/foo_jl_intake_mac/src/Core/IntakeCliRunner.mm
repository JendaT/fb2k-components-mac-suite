//
//  IntakeCliRunner.mm
//  foo_jl_intake
//

#include "IntakeCliRunner.h"

#include "IntakeLog.h"

#include <cstdio>
#include <memory>

namespace intake {

void logCliResult(const CliResult &r) {
    if (!isLogEnabled(LogLevel::Debug)) return;
    std::string line = std::string(cliCommandName(r.command)) + ": " + cliOutcomeName(r.envelope.outcome);
    switch (r.process.end) {
        case ProcessEnd::Exited:
            line += ", exit " + std::to_string(r.process.exitCode);
            break;
        case ProcessEnd::Signaled:
            line += ", signal " + std::to_string(r.process.termSignal);
            break;
        case ProcessEnd::SpawnFailed:
            if (r.process.spawnStage.empty()) {
                line += ", not run";
            } else {
                line += ", spawn failed (" + r.process.spawnStage + ", errno " +
                        std::to_string(r.process.spawnErrno) + ")";
            }
            break;
        case ProcessEnd::Abandoned:
            line += ", abandoned after kill";
            break;
        case ProcessEnd::WaitFailed:
            line += ", wait failed";
            break;
    }
    char seconds[32];
    snprintf(seconds, sizeof seconds, "%.2f s", r.process.elapsedSeconds);
    line += std::string(", ") + seconds;
    if (!r.envelope.errors.empty()) {
        line += ", errors:";
        for (const CliError &e : r.envelope.errors) line += " " + e.code;
    }
    logDebug(line);
}

std::string defaultCliOutputDirectory() {
    @autoreleasepool {
        NSString *caches =
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (caches.length == 0) return std::string();
        const char *path = [caches stringByAppendingPathComponent:@"foo_jl_intake"].fileSystemRepresentation;
        return path ? std::string(path) : std::string();
    }
}

CliBudgetEvent budgetEventFor(CommandClass commandClass) {
    return commandClass == CommandClass::ExecuteDryRun ? CliBudgetEvent::LaneRelease : CliBudgetEvent::Timeout;
}

bool startCliCommand(ProcessRunner &runner, const CliConfig &config, const CliRequest &request,
                     const CliRunOptions &options, dispatch_queue_t queue,
                     CliBudgetHandler onBudget, CliCompletion completion, std::string *refusal) {
    const CliCommand command = request.command;
    CliInvocation inv = buildInvocation(config, request);

    if (inv.status == BuildStatus::Ok && inv.commandClass != CommandClass::ReadOnly &&
        options.outputDirectory.empty()) {
        inv.status = BuildStatus::Refused;
        inv.message = std::string(cliCommandName(command)) + " needs an output directory";
    }
    if (inv.status == BuildStatus::Refused) {
        logDebug(std::string(cliCommandName(command)) + ": refused: " + inv.message);
        if (refusal) *refusal = inv.message;
        return false;
    }

    if (!queue) queue = dispatch_get_main_queue();

    if (inv.status == BuildStatus::NoCli) {
        logDebug(std::string(cliCommandName(command)) + ": " + inv.message);
        auto result = std::make_shared<CliResult>();
        result->command = command;
        result->commandClass = inv.commandClass;
        result->envelope = hostNoCli(inv.message);
        CliCompletion done = std::move(completion);
        dispatch_async(queue, ^{
            if (done) done(std::move(*result));
        });
        return true;
    }

    ProcessSpec spec;
    spec.executable = inv.executable;
    spec.arguments = std::move(inv.arguments);
    spec.environment = std::move(inv.environment);
    spec.limits = options.limits;
    switch (inv.commandClass) {
        case CommandClass::ReadOnly:
            spec.output = OutputTarget::Pipes;
            spec.policy = BudgetPolicy::KillAtBudget;
            break;
        case CommandClass::Mutating:
            spec.output = OutputTarget::Files;
            spec.policy = BudgetPolicy::ReportAtBudget;
            break;
        case CommandClass::ExecuteDryRun:
            spec.output = OutputTarget::Files;
            spec.policy = BudgetPolicy::ReportOnly;
            break;
        case CommandClass::Detached:
            spec.output = OutputTarget::Files;
            spec.policy = BudgetPolicy::Unbounded;
            break;
    }
    if (spec.output == OutputTarget::Files) {
        spec.outputDirectory = options.outputDirectory;
        spec.keepOutputFiles = options.keepOutputFiles;
    }

    if (isLogEnabled(LogLevel::Debug)) {
        std::string line = "run:";
        for (size_t i = 1; i < spec.arguments.size(); i++) line += " " + spec.arguments[i];
        logDebug(line);
    }

    const CommandClass cls = inv.commandClass;
    const CliBudgetEvent event = budgetEventFor(cls);
    ProcessBudgetHandler budget = [onBudget, command, event](pid_t) {
        if (event == CliBudgetEvent::LaneRelease) {
            logDebug(std::string(cliCommandName(command)) +
                     " dry run: still running at the lane budget; no timeout reported (execute is excepted)");
        } else {
            logDebug(std::string(cliCommandName(command)) + ": no exit within the time budget");
        }
        if (onBudget) onBudget(event);
    };
    runner.start(std::move(spec), queue, std::move(budget),
                 [completion, command, cls](ProcessResult &&process) {
                     CliResult result;
                     result.command = command;
                     result.commandClass = cls;
                     result.envelope = interpretProcessResult(process);
                     result.process = std::move(process);
                     if (completion) completion(std::move(result));
                 });
    return true;
}

} // namespace intake
