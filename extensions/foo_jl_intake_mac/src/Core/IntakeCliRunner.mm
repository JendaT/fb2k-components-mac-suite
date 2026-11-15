//
//  IntakeCliRunner.mm
//  foo_jl_intake
//

#include "IntakeCliRunner.h"

#include "IntakeLog.h"

#include <memory>

namespace intake {

std::string defaultCliOutputDirectory() {
    @autoreleasepool {
        NSString *caches =
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (caches.length == 0) return std::string();
        const char *path = [caches stringByAppendingPathComponent:@"foo_jl_intake"].fileSystemRepresentation;
        return path ? std::string(path) : std::string();
    }
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
        logError(std::string("refused: ") + inv.message);
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
    ProcessBudgetHandler budget = [onBudget, command](pid_t) {
        logInfo(std::string(cliCommandName(command)) + ": no exit within the time budget");
        if (onBudget) onBudget();
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
