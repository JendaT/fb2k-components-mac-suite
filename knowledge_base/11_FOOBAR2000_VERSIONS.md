# foobar2000 and SDK Versions

**Revision:** 1.0
**Last Updated:** 2026-01-04

This document tracks foobar2000 and SDK versions, known compatibility issues, and version management.

---

## Current Development Environment

| Item | Version | Notes |
|------|---------|-------|
| foobar2000 for Mac | 2.25.4 | Stable release |
| SDK | 2025-03-07 | Latest available |
| Xcode | 16.x | Required for builds |
| macOS minimum | 11 (Big Sur) | Both Intel and Apple Silicon |

---

## Version Compatibility

### foobar2000 2.25.x (Stable)

**Status:** Recommended for development

All components are tested and working on 2.25.x.

### foobar2000 2.26.x (Preview)

**Status:** Known issues - use with caution

Reports of crashes from users running 2.26 preview versions. This is a beta/preview release and may have compatibility issues with the current SDK.

**Known Issues:**
- Crash reports received from 2.26 users (under investigation)
- Components built with SDK 2025-03-07 may have compatibility issues

**Recommendation:** Wait for 2.26 stable release before supporting.

---

## SDK Changelog Highlights

### 2025-03-07 (Current)
- Reverted C++20 to C++17 in some projects as C++20 is not yet required

### 2024-12-03
- Many compiler warning fixes all over the place

### 2024-08-07
- Windows: Reverted x86 compiler to VS2019

### 2023-09-23
- Allow debugging to resume after PFC_ASSERT failure

### 2023-09-13
- Added spec for user_interface API on Mac OS

### 2023-09-06
- Support for making Mac foobar2000 components

---

## Version Switching

A utility script `fb2k-version` is available for quickly switching between foobar2000 versions:

```bash
fb2k-version
```

**Features:**
- Store current version before installing new one
- Switch between stored versions
- Open download page for new versions

**Storage location:** `/Applications/foobar2000-versions/`

### Workflow: Testing on Multiple Versions

1. Run `fb2k-version`, press `s` to store current 2.25.x
2. Download and install 2.26.x from foobar2000.org/mac
3. Test components on 2.26.x
4. Run `fb2k-version`, select stored version to switch back

---

## Crash Investigation on 2.26

When crash reports come from 2.26 users:

1. **First check:** Is the crash reproducible on 2.25.x?
   - If YES: Bug in our code, investigate
   - If NO: Likely 2.26 compatibility issue

2. **Collect:**
   - Full crash log
   - foobar2000 version (exact build number)
   - Component version
   - Steps to reproduce

3. **Common 2.26 issues to watch for:**
   - SDK API changes not reflected in 2025-03-07 SDK
   - New runtime checks in 2.26 triggering on previously-working code
   - Threading model changes

---

## SDK Location

The SDK is stored at:
```
/Users/jendalen/Projects/Foobar2000/SDK-2025-03-07/
```

Configuration in `shared/sdk_config.rb`:
```ruby
DEFAULT_SDK_DIR = "SDK-2025-03-07"
```

To use a different SDK version, set environment variable:
```bash
export FB2K_SDK_PATH="/path/to/different/SDK"
```

---

## Checking for SDK Updates

SDK releases are announced at:
- https://www.foobar2000.org/changelog-sdk

Current SDK (2025-03-07) is the latest as of January 2026.

---

## References

- [foobar2000 Mac Download](https://www.foobar2000.org/mac)
- [SDK Changelog](https://www.foobar2000.org/changelog-sdk)
- [Development Overview](https://www.foobar2000.org/RTFM)
