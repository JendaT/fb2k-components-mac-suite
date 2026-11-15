//
//  IntakeEnvelope.mm
//  foo_jl_intake
//

#include "IntakeEnvelope.h"

#include <cstring>
#include <signal.h>

namespace intake {

const char *const kErrorNoCli = "E_NO_CLI";
const char *const kErrorCliTimeout = "E_CLI_TIMEOUT";

namespace {

bool isJsonSpace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

std::string_view trimmed(std::string_view s) {
    size_t begin = 0, end = s.size();
    while (begin < end && isJsonSpace(s[begin])) begin++;
    while (end > begin && isJsonSpace(s[end - 1])) end--;
    return s.substr(begin, end - begin);
}

bool isBoolean(id value) {
    return [value isKindOfClass:[NSNumber class]] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

std::string utf8(NSString *s) {
    const char *c = s.UTF8String;
    return c ? std::string(c) : std::string();
}

EnvelopeResult host(CliOutcome outcome, const char *code, std::string detail) {
    EnvelopeResult r;
    r.outcome = outcome;
    CliError e;
    e.code = code;
    e.msg = detail;
    r.errors.push_back(std::move(e));
    r.detail = std::move(detail);
    return r;
}

} // anonymous namespace

const char *cliOutcomeName(CliOutcome outcome) {
    switch (outcome) {
        case CliOutcome::Ok: return "ok";
        case CliOutcome::Partial: return "partial";
        case CliOutcome::Failed: return "failed";
        case CliOutcome::NoCli: return "no-cli";
        case CliOutcome::Timeout: return "timeout";
        case CliOutcome::Cancelled: return "cancelled";
    }
    return "?";
}

EnvelopeResult hostNoCli(std::string detail) {
    return host(CliOutcome::NoCli, kErrorNoCli, std::move(detail));
}

EnvelopeResult hostTimeout(std::string detail) {
    return host(CliOutcome::Timeout, kErrorCliTimeout, std::move(detail));
}

EnvelopeResult parseEnvelope(std::string_view stdoutText, int exitCode) {
    // Rule 5 first: other exit codes say nothing usable, whatever stdout holds.
    if (exitCode != 0 && exitCode != 1 && exitCode != 2) {
        return hostNoCli("exit code " + std::to_string(exitCode));
    }

    std::string_view text = trimmed(stdoutText);
    if (text.empty()) return hostNoCli("empty stdout (exit " + std::to_string(exitCode) + ")");

    @autoreleasepool {
        // A copy, so nothing the parser hands back can point into the
        // caller's buffer.
        NSData *bytes = [NSData dataWithBytes:text.data() length:text.size()];
        NSError *error = nil;
        // A second value or trailing text makes this fail: exactly one value.
        id root = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:&error];
        if (!root) return hostNoCli("stdout is not one JSON value");
        if (![root isKindOfClass:[NSDictionary class]]) return hostNoCli("stdout is not a JSON object");
        NSDictionary *envelope = root;

        id ok = envelope[@"ok"];
        if (!isBoolean(ok)) return hostNoCli("envelope has no boolean ok");
        id errors = envelope[@"errors"];
        if (![errors isKindOfClass:[NSArray class]]) return hostNoCli("envelope has no errors array");
        id data = envelope[@"data"];
        if (!data) return hostNoCli("envelope has no data member");
        if (data == [NSNull null]) data = nil;

        std::vector<CliError> parsed;
        for (id entry in (NSArray *)errors) {
            if (![entry isKindOfClass:[NSDictionary class]]) return hostNoCli("malformed error entry");
            id code = entry[@"code"];
            if (![code isKindOfClass:[NSString class]] || [code length] == 0) {
                return hostNoCli("error entry without a code");
            }
            CliError e;
            e.code = utf8(code);
            id msg = entry[@"msg"];
            if ([msg isKindOfClass:[NSString class]]) e.msg = utf8(msg);
            id path = entry[@"path"];
            if ([path isKindOfClass:[NSString class]]) {
                e.path = utf8(path);
                e.hasPath = true;
            }
            parsed.push_back(std::move(e));
        }

        const bool okValue = [ok boolValue];
        EnvelopeResult r;
        switch (exitCode) {
            case 0:
                if (!okValue) return hostNoCli("exit 0 with ok false");
                if (!parsed.empty()) return hostNoCli("exit 0 with errors");
                r.outcome = CliOutcome::Ok;
                r.data = data;
                return r;
            case 1:
                if (okValue) return hostNoCli("exit 1 with ok true");
                if (parsed.empty()) return hostNoCli("exit 1 without errors");
                r.outcome = CliOutcome::Partial;
                r.data = data;
                r.errors = std::move(parsed);
                return r;
            default: // 2
                if (okValue) return hostNoCli("exit 2 with ok true");
                if (parsed.empty()) return hostNoCli("exit 2 without errors");
                if (data && !([data isKindOfClass:[NSArray class]] && [data count] == 0)) {
                    return hostNoCli("exit 2 with data");
                }
                r.outcome = CliOutcome::Failed;
                r.errors = std::move(parsed);
                return r;
        }
    }
}

EnvelopeResult interpretProcessResult(const ProcessResult &result) {
    if (result.cancelled) {
        EnvelopeResult r;
        r.outcome = CliOutcome::Cancelled;
        r.detail = "cancelled";
        return r;
    }
    if (result.killedForTimeout) {
        if (result.hardCapHit) {
            return hostTimeout("still running at the hard cap; terminated");
        }
        return hostTimeout("no exit within the time budget; terminated");
    }
    switch (result.end) {
        case ProcessEnd::SpawnFailed:
            return hostNoCli("cannot start the intake CLI (" + result.spawnStage + "): " +
                             strerror(result.spawnErrno));
        case ProcessEnd::Abandoned:
            // Only a signalled process is abandoned, so killedForTimeout or
            // cancelled is set; kept for completeness.
            return hostTimeout("the intake CLI did not die after SIGKILL");
        case ProcessEnd::WaitFailed:
            return hostNoCli("the exit status of the intake CLI was lost");
        case ProcessEnd::Signaled:
            return hostNoCli(std::string("the intake CLI was terminated by signal ") +
                             std::to_string(result.termSignal));
        case ProcessEnd::Exited:
            break;
    }
    if (!result.outputError.empty()) return hostNoCli(result.outputError);
    if (result.stdoutTruncated) return hostNoCli("stdout exceeded its size cap");
    return parseEnvelope(result.stdoutData, result.exitCode);
}

std::vector<std::string> idsInData(id data) {
    std::vector<std::string> ids;
    if (![data isKindOfClass:[NSArray class]]) return ids;
    for (id row in (NSArray *)data) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        id identifier = row[@"id"];
        if ([identifier isKindOfClass:[NSString class]]) ids.push_back(utf8(identifier));
    }
    return ids;
}

} // namespace intake
