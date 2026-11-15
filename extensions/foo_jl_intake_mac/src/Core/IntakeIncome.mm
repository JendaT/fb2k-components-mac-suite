//
//  IntakeIncome.mm
//  foo_jl_intake
//

#include "IntakeIncome.h"

#include "IntakePath.h"

namespace intake {

namespace {

bool isJsonBool(id value) {
    return value != nil && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

} // anonymous namespace

IncomeParseResult parseIncomeFolders(id data) {
    IncomeParseResult out;
    @autoreleasepool {
        if (![data isKindOfClass:[NSArray class]]) {
            out.error = data == nil || data == [NSNull null] ? "income data is null" : "income data is not an array";
            return out;
        }
        out.ok = true;
        for (id entry in (NSArray *)data) {
            if (![entry isKindOfClass:[NSDictionary class]]) {
                out.skipped++;
                continue;
            }
            NSDictionary *dict = entry;
            id path = dict[@"path"];
            if (![path isKindOfClass:[NSString class]]) {
                out.skipped++;
                continue;
            }
            IncomeFolder folder;
            copyUTF8(path, folder.path);
            if (folder.path.empty() || folder.path[0] != '/') {
                out.skipped++;
                continue;
            }
            id name = dict[@"name"];
            if ([name isKindOfClass:[NSString class]]) copyUTF8(name, folder.name);
            id exists = dict[@"exists"];
            if (isJsonBool(exists)) folder.exists = [exists boolValue];
            out.folders.push_back(std::move(folder));
        }
    }
    return out;
}

} // namespace intake
