#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

// GUIDs of the ui_element_mac services ShellVanced hosts.
// AlbumViewVanced {B4E8F3A2-9C5D-4E6B-AF7E-2D3C4B5A6E7F}
inline const GUID kSVGuidAlbumViewVanced = {
    0xB4E8F3A2, 0x9C5D, 0x4E6B,
    {0xAF, 0x7E, 0x2D, 0x3C, 0x4B, 0x5A, 0x6E, 0x7F}
};
// SimPlaylist {8FE5C4B4-619D-4D89-8567-1D96C32E2162}
inline const GUID kSVGuidSimPlaylist = {
    0x8FE5C4B4, 0x619D, 0x4D89,
    {0x85, 0x67, 0x1D, 0x96, 0xC3, 0x2E, 0x21, 0x62}
};

// Instantiates another component's ui_element_mac by GUID.
// returns nil if the component isn't installed
NSViewController* SVInstantiateElement(const GUID& guid, NSDictionary<NSString*,NSString*>* params);
