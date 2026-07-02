//
//  SubgroupDetector.h
//  foo_simplaylist_mac
//
//  Subgroup (disc-header) detection state machine, shared by all group
//  detection code paths so they use IDENTICAL logic. Moved out of
//  SimPlaylistController and switched from pfc::string8 to std::string so it
//  compiles without the foobar2000 SDK and is unit-testable standalone.
//
//  Semantics (unchanged from the original):
//  - Empty formatted values are skipped and do NOT update the tracking state.
//  - The first non-empty subgroup of a group is emitted only when it appears
//    on the group's first track AND showFirstSubgroup is enabled.
//  - A change of non-empty value (disc change) is always emitted.
//  - Non-empty values always update the tracking state, emitted or not.
//

#pragma once

#import <Foundation/Foundation.h>

#include <cstdio>
#include <cstring>
#include <string>

struct SubgroupDetector {
    std::string currentSubgroup;   // Tracks the current subgroup value
    bool showFirstSubgroup;        // Config setting

    // Debug logging support
    FILE* debugFile;
    bool debugEnabled;

    SubgroupDetector(bool showFirst, bool enableDebug = false)
        : currentSubgroup("")
        , showFirstSubgroup(showFirst)
        , debugFile(nullptr)
        , debugEnabled(enableDebug)
    {
        if (debugEnabled) {
            debugFile = fopen("/tmp/simplaylist_subgroup_debug.txt", "a");
            if (debugFile) {
                fprintf(debugFile, "\n=== New SubgroupDetector created (showFirst=%d) ===\n", showFirst);
                fflush(debugFile);
            }
        }
    }

    ~SubgroupDetector() {
        if (debugFile) {
            fclose(debugFile);
        }
    }

    // Non-copyable (FILE* ownership)
    SubgroupDetector(const SubgroupDetector&) = delete;
    SubgroupDetector& operator=(const SubgroupDetector&) = delete;

    // Initialize from existing state (for continuation from partial detection)
    void initFromState(const char* existingSubgroup) {
        currentSubgroup = existingSubgroup ? existingSubgroup : "";
        if (debugEnabled && debugFile) {
            fprintf(debugFile, "initFromState: '%s'\n", currentSubgroup.c_str());
            fflush(debugFile);
        }
    }

    // Call when entering a new group - clears subgroup tracking
    void enterNewGroup() {
        currentSubgroup.clear();
        if (debugEnabled && debugFile) {
            fprintf(debugFile, "enterNewGroup: cleared currentSubgroup\n");
            fflush(debugFile);
        }
    }

    // Check if a subgroup header should be added for this track
    // Returns: true if subgroup header should be added
    // Updates: currentSubgroup tracking state
    // Takes const char* so hot detection loops can pass reused buffers without
    // constructing a std::string per track.
    bool shouldAddSubgroup(const char* formattedSubgroup, bool isNewGroup,
                           NSMutableArray<NSNumber*>* subgroupStarts,
                           NSMutableArray<NSString*>* subgroupHeaders,
                           size_t playlistIndex, const char* debugTrackName = nullptr) {

        // Only consider non-empty subgroup values (ignore tracks with missing disc tags)
        if (!formattedSubgroup || formattedSubgroup[0] == '\0') {
            if (debugEnabled && debugFile) {
                fprintf(debugFile, "[%zu] '%s': empty subgroup, skipped\n",
                        playlistIndex, debugTrackName ? debugTrackName : "");
                fflush(debugFile);
            }
            return false;
        }

        bool isFirstSubgroupInGroup = currentSubgroup.empty();
        bool isDifferentSubgroup = (currentSubgroup != formattedSubgroup);

        bool shouldAdd = false;
        const char* reason = "";

        if (isFirstSubgroupInGroup) {
            // First non-empty subgroup in this group
            // Only add if: (1) this is the start of a new group, AND (2) showFirstSubgroup is enabled
            if (isNewGroup && showFirstSubgroup) {
                shouldAdd = true;
                reason = "first subgroup at group start (showFirst=ON)";
            } else {
                reason = isNewGroup ? "first subgroup but showFirst=OFF" : "first subgroup but NOT at group start";
            }
        } else if (isDifferentSubgroup) {
            // Real disc change (e.g., Disc 1 -> Disc 2) - always show
            shouldAdd = true;
            reason = "disc change";
        } else {
            reason = "same subgroup";
        }

        if (debugEnabled && debugFile) {
            fprintf(debugFile, "[%zu] '%s': subgroup='%s' (len=%zu), current='%s', isNew=%d, isFirst=%d, isDiff=%d -> %s: %s\n",
                    playlistIndex,
                    debugTrackName ? debugTrackName : "",
                    formattedSubgroup,
                    strlen(formattedSubgroup),
                    currentSubgroup.c_str(),
                    isNewGroup,
                    isFirstSubgroupInGroup,
                    isDifferentSubgroup,
                    shouldAdd ? "ADD" : "SKIP",
                    reason);
            fflush(debugFile);
        }

        if (shouldAdd) {
            [subgroupStarts addObject:@(playlistIndex)];
            [subgroupHeaders addObject:[NSString stringWithUTF8String:formattedSubgroup]];
        }

        // Always update currentSubgroup when formatted value is non-empty
        currentSubgroup = formattedSubgroup;

        return shouldAdd;
    }

    // Get current subgroup value (for passing to continuation)
    const char* getCurrentSubgroup() const {
        return currentSubgroup.c_str();
    }
};
