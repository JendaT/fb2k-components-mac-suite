//
//  IntakeIncomeTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeIncome: the `income --json` data shape (doc 03 v1.2,
//  CR-004.7): a valid list, unknown fields ignored, unusable entries
//  skipped, `exists` false kept, and data that is not an array. Synthetic
//  paths only.
//
// TEST_DEPS: src/Core/IntakePath.mm src/Core/IntakeEnvelope.mm src/Core/IntakeLog.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeEnvelope.h"
#include "../src/Core/IntakeIncome.h"
#include "TestHarness.h"

#include <string>

using namespace intake;

static IncomeParseResult parse(const char *json) {
    IncomeParseResult r;
    @autoreleasepool {
        r = parseIncomeFolders(parseJsonValue(json));
    }
    return r;
}

static void testValid() {
    g_context = "valid";
    IncomeParseResult r = parse(R"([{"name":"dump","path":"/fixture/income/dump","exists":true},
                                    {"name":"shop","path":"/fixture/income/shop","exists":true,"extra":1},
                                    {"name":"offline","path":"/fixture/income/offline","exists":false}])");
    CHECK(r.ok && r.error.empty(), "an array parses");
    CHECK_EQ(r.folders.size(), 3, "three folders");
    CHECK_EQ(r.skipped, 0, "none skipped");
    CHECK(r.folders.size() == 3 && r.folders[0].name == "dump" && r.folders[0].path == "/fixture/income/dump" &&
              r.folders[0].exists,
          "the first folder, in file order");
    CHECK(r.folders.size() == 3 && r.folders[1].name == "shop", "an unknown field is ignored");
    CHECK(r.folders.size() == 3 && !r.folders[2].exists && r.folders[2].path == "/fixture/income/offline",
          "a missing folder is kept, with exists false");
    IncomeParseResult empty = parse("[]");
    CHECK(empty.ok && empty.folders.empty(), "an empty array is a valid empty list");
}

static void testUnusable() {
    g_context = "unusable";
    IncomeParseResult r = parse(R"([{"name":"no-path"},
                                    {"name":"relative","path":"income/dump"},
                                    {"name":"number","path":7},
                                    "a string",
                                    {"path":"/fixture/income/plain"},
                                    {"name":"odd-exists","path":"/fixture/income/odd","exists":"yes"}])");
    CHECK(r.ok, "still a list");
    CHECK_EQ(r.skipped, 4, "no path, a relative path, a number and a non-object are skipped");
    CHECK(r.folders.size() == 2 && r.folders[0].path == "/fixture/income/plain" && r.folders[0].name.empty() &&
              r.folders[0].exists,
          "no name: empty; no exists: true");
    CHECK(r.folders.size() == 2 && r.folders[1].exists, "an exists that is not a boolean counts as true");
    CHECK(parse("[{\"path\":\"/fixture/income/a\",\"exists\":0}]").folders[0].exists,
          "the number 0 is not a JSON boolean");
}

static void testNotArray() {
    g_context = "not-array";
    IncomeParseResult obj = parse(R"({"path":"/fixture/income/dump"})");
    CHECK(!obj.ok && obj.error == "income data is not an array" && obj.folders.empty(), "an object fails");
    IncomeParseResult null = parseIncomeFolders([NSNull null]);
    CHECK(!null.ok && null.error == "income data is null", "JSON null (exit 2's data) fails");
    IncomeParseResult none = parseIncomeFolders(nil);
    CHECK(!none.ok && !none.error.empty(), "nil fails");
}

int main(void) {
    @autoreleasepool {
        testValid();
        testUnusable();
        testNotArray();
    }
    TEST_MAIN_END();
}
