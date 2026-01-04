# Context Menu Crash Analysis - 2026-01-03

## Summary

SimPlaylist crashes on right-click (context menu) with `EXC_BAD_ACCESS` (SIGSEGV). The crash occurs when setting `representedObject` on an NSMenuItem, caused by incorrectly bridging a C++ pointer as an Objective-C object.

## Affected Versions

- v1.1.4 and v1.1.5
- Fixed in v1.1.6

## Crash Signature

```
Exception Type:  EXC_BAD_ACCESS (SIGSEGV)
Exception Subtype: KERN_INVALID_ADDRESS at 0x0f004d26aa0003f0
                   (possible pointer authentication failure)

Stack Trace:
0  lookUpImpOrForward + 96
1  _objc_msgSend_uncached + 68
2  -[NSMenuItem setRepresentedObject:] + 48
3  -[SimPlaylistController buildNSMenu:fromMenuItem:contextManager:] + 540
4  -[SimPlaylistController showContextMenuForHandles:atPoint:inView:] + 332
5  -[SimPlaylistController playlistView:requestContextMenuForRows:atPoint:] + 496
6  -[SimPlaylistView rightMouseDown:] + 236
```

## Root Cause

In `SimPlaylistController.mm`, line 1439:

```objc
menuItem.representedObject = (__bridge id)cmm.get_ptr();  // WRONG!
```

The bug:
1. `cmm` is a `contextmenu_manager_v2::ptr` (fb2k smart pointer to C++ object)
2. `cmm.get_ptr()` returns a raw `contextmenu_manager_v2*` (C++ pointer)
3. `(__bridge id)` casts this C++ pointer to an Objective-C object
4. When Cocoa calls `[newValue retain]` in `setRepresentedObject:`, it sends an ObjC message to a C++ object
5. The ObjC runtime tries to find the `retain` method via `objc_msgSend`
6. The C++ vtable pointer fails Pointer Authentication (PAC) check on Apple Silicon

## Why "Pointer Authentication Failure"?

On Apple Silicon (ARM64e), pointers to ObjC objects are signed with Pointer Authentication Codes (PAC). When the ObjC runtime dereferences what it thinks is an object pointer:

1. It first validates the PAC signature
2. C++ pointers don't have valid PAC signatures
3. The CPU raises `EXC_BAD_ACCESS` with "possible pointer authentication failure"

The `0x0f00` prefix in the crash addresses (`0x0f004d26aa0003f0`) is the invalid PAC signature bytes.

## Why We Couldn't Reproduce

The crash only occurs when using the **V2 context menu API**, which is only available in foobar2000 2.26+.

```objc
auto cmm = contextmenu_manager_v2::tryGet();
if (!cmm.is_valid()) {
    // V1 fallback - SAFE, no representedObject bug
    [self showContextMenuWithManagerV1:...];
    return;
}
// V2 path - HAS THE BUG (only reached on fb2k 2.26+)
[self buildNSMenu:menu fromMenuItem:root contextManager:_contextMenuManager];
```

| foobar2000 Version | `contextmenu_manager_v2::tryGet()` | Code Path | Result |
|--------------------|-----------------------------------|-----------|--------|
| 2.25.x and earlier | Returns invalid | V1 fallback | No crash |
| 2.26+ | Returns valid | V2 path | **Crash** |

Development was done on fb2k 2.25.4, which always used the V1 fallback path. Users on fb2k 2.26 hit the V2 path and crashed immediately on right-click.

**Crash reports confirmed:** All 5 crashes were from fb2k 2.26 users.

## How The Bug Got Into The Codebase

The buggy line is **dead code left over from a refactoring**.

### Original Design (from AMENDMENTS.md)

The original implementation stored the manager pointer in `representedObject` to pass it to the click handler:

```objc
// ORIGINAL: Store manager in representedObject
menuItem.representedObject = (__bridge id)(void*)cm.get_ptr();

// ORIGINAL: Click handler retrieves from representedObject
- (void)contextMenuItemClicked:(NSMenuItem *)sender {
    contextmenu_manager* cm = (__bridge contextmenu_manager*)sender.representedObject;
    if (cm) {
        cm->execute_by_id((unsigned)sender.tag);
    }
}
```

This design was flawed from the start (`__bridge` on a C++ pointer is unsafe), but it may have worked on x86 Macs where PAC doesn't exist.

### Refactored Design (current)

Later, the code was refactored to store the manager in an instance variable instead:

```objc
// REFACTORED: Store in instance variable (line 1388)
_contextMenuManager = cmm;

// REFACTORED: Click handler uses instance variable
- (void)contextMenuItemClicked:(NSMenuItem *)sender {
    if (_contextMenuManager.is_valid()) {
        _contextMenuManager->execute_by_id(commandID);
    }
}
```

### The Problem

**The old `representedObject` line was never removed.** It became dead code that:
1. Still executed during menu construction
2. Still crashed when Cocoa called `retain` on the fake ObjC object
3. Served absolutely no purpose (the value was never read)

This is a classic refactoring mistake: updating the consumer but forgetting to remove the now-unused producer.

## The Fix

Simply remove the incorrect line:

```diff
- menuItem.representedObject = (__bridge id)cmm.get_ptr();  // Store reference
```

## Lessons Learned

### 1. Never bridge C++ pointers to ObjC objects

```objc
// WRONG - C++ pointer is not an ObjC object
menuItem.representedObject = (__bridge id)cppPtr;

// If you need to store C++ data, use NSValue:
menuItem.representedObject = [NSValue valueWithPointer:cppPtr];
// Then retrieve with:
void *ptr = [menuItem.representedObject pointerValue];
```

### 2. PAC makes these bugs more visible

On older x86 Macs, this might silently corrupt memory. On Apple Silicon, PAC catches invalid pointer usage immediately. This is a security feature working as intended.

### 3. Unused code is dangerous

The `representedObject` line served no purpose. Dead code accumulates and causes mysterious bugs.

### 4. Test on multiple machines

Different memory layouts expose different bugs. CI testing on multiple architectures helps.

## Crash Reports Analyzed

All had identical stack traces and similar crash addresses:

| File | Address |
|------|---------|
| foobar2000-2026-01-01-183401.ips | 0x0f004d26aa0003f0 |
| foobar2000-2026-01-01-222158.ips | 0x0f004d26aa0003f0 |
| foobar2000-2026-01-02-212621.ips | 0x0f004d26aa0003f0 |
| foobar2000-2026-01-02-234528.ips | 0x0f004d26aa0003f0 |
| User-provided (different user)   | 0x0f004d28aa0003f0 |

The near-identical addresses across sessions suggest the `contextmenu_manager_v2` object is allocated at a predictable offset from some base address.

## Reproduction Flow

**Requirements:** foobar2000 2.26 or later (provides `contextmenu_manager_v2` API)

1. Open SimPlaylist view with tracks loaded
2. Right-click on any track
3. `contextmenu_manager_v2::tryGet()` returns valid manager (fb2k 2.26+)
4. Code enters V2 path: `buildNSMenu:fromMenuItem:contextManager:`
5. For first menu item, `setRepresentedObject:` is called with C++ pointer
6. Cocoa calls `[newValue retain]` inside `setRepresentedObject:`
7. ARM64 PAC validation fails on the C++ pointer
8. `EXC_BAD_ACCESS` with "possible pointer authentication failure"

**100% reproducible** on fb2k 2.26+ with SimPlaylist v1.1.4 or v1.1.5.

## Prevention: Code Review Checklist

This bug could have been caught by:

1. **Dead code detection:** The `representedObject` was set but never read
2. **Type safety review:** `(__bridge id)` on non-ObjC pointers is always suspicious
3. **Testing on latest fb2k version:** V2 API was only available in 2.26
4. **Compiler warnings:** `-Wunused-value` might have flagged unused `representedObject`
