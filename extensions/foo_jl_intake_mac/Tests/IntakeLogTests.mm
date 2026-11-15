//
//  IntakeLogTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeLog (level gating, backend swap, no-op default).
//  Compiled standalone under ASan+UBSan; see Scripts/run_tests.sh.
//

#include "../src/Core/IntakeLog.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using intake::LogLevel;

namespace {

struct Entry {
    LogLevel level;
    std::string message;
};

std::vector<Entry> g_first;
std::vector<Entry> g_second;

void firstBackend(LogLevel level, const char *message) {
    g_first.push_back({level, message});
}

void secondBackend(LogLevel level, const char *message) {
    g_second.push_back({level, message});
}

void logOneOfEach() {
    intake::logError("e");
    intake::logInfo("i");
    intake::logDebug(std::string("d"));
}

} // namespace

int main(void) {
    // --- compiled-in default: tests build without DEBUG, so Release's Info ---
    g_context = "default-level";
    CHECK(intake::logLevel() == LogLevel::Info, "default threshold is Info without DEBUG");
    CHECK(!intake::isLogEnabled(LogLevel::Debug), "Debug is off by default without DEBUG");

    // --- default backend is a no-op: logging before install must not crash ---
    g_context = "no-backend";
    intake::setLogLevel(LogLevel::Debug);
    logOneOfEach();
    intake::logMessage(LogLevel::Error, nullptr);
    CHECK(true, "logging with no backend installed does not crash");

    // --- prefix and delivery ---
    g_context = "delivery";
    intake::setLogBackend(firstBackend);
    intake::setLogLevel(LogLevel::Debug);
    intake::logInfo("loaded 3 roots");
    CHECK_EQ(g_first.size(), 1, "one message delivered");
    CHECK(!g_first.empty() && g_first[0].message == "[intake] loaded 3 roots",
          "message carries the [intake] prefix");
    CHECK(!g_first.empty() && g_first[0].level == LogLevel::Info, "level is passed through");
    intake::logMessage(LogLevel::Error, nullptr);
    CHECK(g_first.size() == 2 && g_first[1].message == "[intake] ",
          "null message logs as an empty one");

    // --- level gating ---
    g_context = "gating";
    g_first.clear();
    intake::setLogLevel(LogLevel::Debug);
    logOneOfEach();
    CHECK_EQ(g_first.size(), 3, "Debug threshold passes all three levels");

    g_first.clear();
    intake::setLogLevel(LogLevel::Info);
    logOneOfEach();
    CHECK_EQ(g_first.size(), 2, "Info threshold drops Debug");
    CHECK(g_first.size() == 2 && g_first[0].message == "[intake] e" &&
              g_first[1].message == "[intake] i",
          "Info threshold keeps Error and Info in order");

    g_first.clear();
    intake::setLogLevel(LogLevel::Error);
    logOneOfEach();
    CHECK(g_first.size() == 1 && g_first[0].level == LogLevel::Error,
          "Error threshold keeps only Error");

    CHECK(intake::isLogEnabled(LogLevel::Error), "Error is always enabled");
    CHECK(!intake::isLogEnabled(LogLevel::Info), "Info disabled at Error threshold");

    // --- integer levels from the preference are clamped ---
    g_context = "clamp";
    intake::setLogLevel(7);
    CHECK(intake::logLevel() == LogLevel::Debug, "level above 2 clamps to Debug");
    intake::setLogLevel(-3);
    CHECK(intake::logLevel() == LogLevel::Error, "level below 0 clamps to Error");
    intake::setLogLevel(1);
    CHECK(intake::logLevel() == LogLevel::Info, "level 1 is Info");

    // --- backend swap ---
    g_context = "swap";
    g_first.clear();
    g_second.clear();
    intake::setLogLevel(LogLevel::Debug);
    intake::setLogBackend(secondBackend);
    intake::logInfo("after swap");
    CHECK(g_first.empty(), "old backend receives nothing after the swap");
    CHECK(g_second.size() == 1 && g_second[0].message == "[intake] after swap",
          "new backend receives the message");

    // --- removing the backend restores the no-op ---
    g_context = "remove";
    intake::setLogBackend(nullptr);
    logOneOfEach();
    CHECK(g_first.empty() && g_second.size() == 1, "no backend receives anything after removal");

    TEST_MAIN_END();
}
