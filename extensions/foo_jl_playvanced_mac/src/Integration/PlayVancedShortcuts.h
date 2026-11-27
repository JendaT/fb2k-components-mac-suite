#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

// Installs the app-wide key-down monitor once (main thread). Safe to call twice.
void PlayVancedShortcuts_install(void);
// Removes the monitor (component shutdown).
void PlayVancedShortcuts_uninstall(void);
