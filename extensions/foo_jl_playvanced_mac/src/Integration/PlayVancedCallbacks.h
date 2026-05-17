#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

@class PlayVancedController;

void PlayVancedCallbackManager_registerController(PlayVancedController* controller);
void PlayVancedCallbackManager_unregisterController(PlayVancedController* controller);
