//
//  IntakeTestOpenPrefs.mm
//  foo_jl_intake
//
//  Hidden one-shot helper for in-app acceptance runs
//  (docs/hidden-options.md, foo_jl_intake.test_open_prefs). Nobody clicks
//  through foobar2000 during those runs, so the component opens its own
//  preferences page when a config switch asks it to:
//
//    1  about 5 s after start, show the Tools > Intake preferences page
//       (ui_control::show_preferences with the page's GUID) and bring the
//       preferences window to the front.
//
//  The switch is reset to 0 before it acts, so it fires once. Nothing else
//  is read or written.
//
//  Temporary: removed with the other acceptance aids before the merge
//  (PLAN.md B10).
//

#import "../fb2k_sdk.h"

#import <AppKit/AppKit.h>

#include "IntakeConfig.h"

#include "../Core/IntakeLog.h"

namespace {

const char *const kSwitchKey = "test_open_prefs";  // under foo_jl_intake.

void openPreferencesPage() {
    try {
        auto control = ui_control::get();
        if (!control.is_valid()) {
            intake::logError("test_open_prefs: no ui_control service");
            return;
        }
        control->show_preferences(intake::config::kPreferencesPageGuid);
    } catch (...) {
        intake::logError("test_open_prefs: show_preferences failed");
        return;
    }
    // show_preferences switches the page of an open window but may leave it
    // behind others (foo_jl_wave_seekbar_mac does the same).
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSWindow *window in NSApp.windows) {
            if (window.isVisible &&
                [window.title rangeOfString:@"Preferences" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [window makeKeyAndOrderFront:nil];
                break;
            }
        }
        [NSApp activateIgnoringOtherApps:YES];
    });
    intake::logInfo("test_open_prefs: opened the Intake preferences page");
}

class intake_test_open_prefs_initquit : public initquit {
public:
    void on_init() override {
        if (intake::config::getInt(kSwitchKey, 0) != 1) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (core_api::is_shutting_down()) return;
                           intake::config::setInt(kSwitchKey, 0);
                           openPreferencesPage();
                       });
    }
    void on_quit() override {}
};

FB2K_SERVICE_FACTORY(intake_test_open_prefs_initquit);

} // namespace
