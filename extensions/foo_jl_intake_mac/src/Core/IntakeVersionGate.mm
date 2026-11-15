//
//  IntakeVersionGate.mm
//  foo_jl_intake
//

#include "IntakeVersionGate.h"

#import <CoreFoundation/CoreFoundation.h>

namespace intake {

const char *gateVerdictName(GateVerdict verdict) {
    switch (verdict) {
        case GateVerdict::Pass: return "pass";
        case GateVerdict::DataNotObject: return "data-not-object";
        case GateVerdict::SchemaMissing: return "schema-missing";
        case GateVerdict::SchemaNotInteger: return "schema-not-integer";
        case GateVerdict::SchemaUnsupported: return "schema-unsupported";
    }
    return "?";
}

bool isJsonInteger(id value, long long *out) {
    if (value == nil) return false;
    CFTypeRef cf = (__bridge CFTypeRef)value;
    // CFBoolean and NSDecimalNumber have their own type ids.
    if (CFGetTypeID(cf) != CFNumberGetTypeID()) return false;
    CFNumberRef number = (CFNumberRef)cf;
    if (CFNumberIsFloatType(number)) return false;
    long long v = 0;
    if (!CFNumberGetValue(number, kCFNumberLongLongType, &v)) return false;
    if (out) *out = v;
    return true;
}

namespace {

const char *jsonKind(id value) {
    if (value == nil || value == [NSNull null]) return "null";
    if ([value isKindOfClass:[NSString class]]) return "a string";
    if ([value isKindOfClass:[NSArray class]]) return "an array";
    if ([value isKindOfClass:[NSDictionary class]]) return "an object";
    if ([value isKindOfClass:[NSNumber class]]) {
        CFTypeRef cf = (__bridge CFTypeRef)value;
        if (CFGetTypeID(cf) == CFBooleanGetTypeID()) return "a boolean";
        return "a non-integer number";
    }
    return "an unknown value";
}

VersionGateResult fail(VersionGateResult r, GateVerdict verdict, std::string detail) {
    r.verdict = verdict;
    r.detail = std::move(detail);
    return r;
}

} // anonymous namespace

VersionGateResult checkVersionGate(id data) {
    VersionGateResult r;
    @autoreleasepool {
        r.info = parseCliVersionInfo(data);
        if (![data isKindOfClass:[NSDictionary class]]) {
            return fail(std::move(r), GateVerdict::DataNotObject,
                        std::string("version data is ") + jsonKind(data) + ", not an object");
        }
        id schema = ((NSDictionary *)data)[@"schema"];
        if (schema == nil || schema == [NSNull null]) {
            return fail(std::move(r), GateVerdict::SchemaMissing, "version data has no schema");
        }
        long long value = 0;
        if (!isJsonInteger(schema, &value)) {
            return fail(std::move(r), GateVerdict::SchemaNotInteger,
                        std::string("schema is ") + jsonKind(schema) + ", not an integer");
        }
        if (value != kSupportedSchema) {
            return fail(std::move(r), GateVerdict::SchemaUnsupported,
                        "schema " + std::to_string(value) + ", supported " +
                            std::to_string(kSupportedSchema));
        }
        r.verdict = GateVerdict::Pass;
    }
    return r;
}

} // namespace intake
