#pragma once

//
// Names a component is known by, shared by its About text, its layout
// element's match_name and the info popover on its preferences page.
//
// Each component defines them in src/Integration/ComponentInfo.h and then
// includes this header:
//
//   #define JL_COMPONENT_FILE "foo_jl_example"
//   #define JL_COMPONENT_VERSION EXAMPLE_VERSION
//   #define JL_LAYOUT_NAME "example"                  // recommended name
//   #define JL_LAYOUT_ALIASES "Example", "jl_example" // other accepted names
//   #define JL_LAYOUT_PARAMETERS ""                   // e.g. "type=front|back"
//   #define JL_PREFERENCES_PATH "Display > Example"   // or "none"
//
// Never drop a name from JL_LAYOUT_ALIASES: saved layouts refer to it.
//

#ifndef JL_LAYOUT_NAME
#error "Define the JL_* names in the component's ComponentInfo.h before including component_info.h"
#endif

#include <string.h>

// True when name is the layout name or one of its aliases (case-sensitive).
static inline bool JLMatchesLayoutName(const char *name) {
    static const char *const names[] = {JL_LAYOUT_NAME, JL_LAYOUT_ALIASES};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strcmp(name, names[i]) == 0) return true;
    }
    return false;
}

#ifdef __OBJC__
#import <Foundation/Foundation.h>

// Label/value rows for the preferences info popover.
static inline NSArray<NSArray<NSString *> *> *JLComponentInfoRows(void) {
    static const char *const aliasNames[] = {JL_LAYOUT_ALIASES};
    NSMutableArray<NSString *> *aliases = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(aliasNames) / sizeof(aliasNames[0]); i++) {
        [aliases addObject:@(aliasNames[i])];
    }
    NSString *parameters = @(JL_LAYOUT_PARAMETERS);
    return @[
        @[@"Component", @JL_COMPONENT_FILE],
        @[@"Version", @JL_COMPONENT_VERSION],
        @[@"Layout element", @JL_LAYOUT_NAME],
        @[@"Also accepted", [aliases componentsJoinedByString:@"\n"]],
        @[@"Parameters", parameters.length ? parameters : @"none"],
    ];
}
#endif
