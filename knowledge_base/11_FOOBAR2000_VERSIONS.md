# foobar2000 and SDK Versions

**Revision:** 1.1
**Last Updated:** 2026-10-09

This document tracks foobar2000 and SDK versions, known compatibility issues, and version management.

---

## Current Development Environment

| Item | Version | Notes |
|------|---------|-------|
| foobar2000 for Mac | 2.26 | Stable release |
| SDK | 2026-10-01 | Latest available; requires C++20 |
| Xcode | 27.x | Cannot target macOS 11 |
| macOS minimum | 12 (Monterey) | Both Intel and Apple Silicon |

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

### 2026-10-01 (Current)
- Windows-only fixes (PFC<=>shared.dll hooking in ARM64EC mode); now_playing_album_art_notify doc fix

### 2026-09-17
- Windows-only fix (32-bit link of the 09-16 hooking workaround)

### 2026-09-16 (major)
- **C++20 required** (component projects must build as `gnu++20`)
- `FOOBAR2000_TARGET_VERSION=81` (foobar2000 v2.0+) by default
- Published 2.25/2.26 APIs: dark mode, `retro` UI mode detection, `playback_control_v4`, `output_entry_v4`, `input_decoder_v5`, skipTrack, playOn, converter post-actions
- `abort_callback` spec rewritten (see `abort_callback.h`)
- File attributes: "remote" now means high-latency internet only; "network" covers internet and SMB shares
- Removed: `library_index`, `filesystem_transacted`, `packet_decoder_streamparse`, `pfc::int_specs_t`, `TEMPLATE_CONSTRUCTOR_*`
- PFC: `throw()` specs changed to `noexcept`
- helpers-mac: the `foobar2000-mac-class-suffix` hack is now discouraged (use unique class names or Swift)
- Not in the change log: the pfc Xcode target was renamed `pfc-Mac` -> `pfc`, so the library is now `libpfc.a`

### 2025-03-07
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

## Data Directory Paths

### foobar2000 v2 (Current)

| Purpose | Path |
|---------|------|
| User data root | `~/Library/foobar2000-v2/` |
| User components | `~/Library/foobar2000-v2/user-components/` |
| Configuration | `~/Library/foobar2000-v2/config.sqlite` |
| Metadata database | `~/Library/foobar2000-v2/metadb.sqlite` |
| Playlists | `~/Library/foobar2000-v2/playlists-v2.0/` |
| Library databases | `~/Library/foobar2000-v2/library-v2.0/` |

**Component installation structure:**
```
~/Library/foobar2000-v2/user-components/<component_name>/<component_name>.component/
```

### Legacy v1 Path (DO NOT USE)

```
~/Library/Application Support/foobar2000/
```

**Warning:** The v1 path is NOT used by foobar2000 v2. Components placed there will NOT be loaded.

**Common mistake:** The hybrid path `~/Library/Application Support/foobar2000-v2/` is WRONG. foobar2000 v2 uses `~/Library/foobar2000-v2/` (without "Application Support").

---

## SDK Location

The SDK is stored at:
```
/Users/jendalen/Projects/Foobar2000/SDK-2026-10-01/
```

Configuration in `shared/sdk_config.rb`:
```ruby
DEFAULT_SDK_DIR = "SDK-2026-10-01"
```

To use a different SDK version, set environment variable:
```bash
export FB2K_SDK_PATH="/path/to/different/SDK"
```

---

## Checking for SDK Updates

SDK releases are announced at:
- https://www.foobar2000.org/changelog-sdk

Current SDK (2026-10-01) is the latest as of October 2026.

### Upgrading the SDK

1. Download `SDK-<date>.7z` from foobar2000.org/SDK and extract it to the repo root as `SDK-<date>/` (gitignored). Keep the old one until every worktree has moved.
2. Build the five libraries in the order given in the README. Xcode 27 rejects the SDK projects' macOS 11 target, so pass `MACOSX_DEPLOYMENT_TARGET=12.0` on the `xcodebuild` command line instead of editing the SDK.
3. Check every library exists under its `build/Release/` directory; product names can change (2026-09-16 renamed `libpfc-Mac.a` to `libpfc.a`).
4. Update `DEFAULT_SDK_DIR` in `shared/sdk_config.rb` and the SDK name in `Scripts/worktree-setup.sh`, `Scripts/new-component.sh`, `Scripts/generate_compile_commands.rb`.
5. Symlink the new SDK into each worktree (`ln -s <repo>/SDK-<date> <worktree>/SDK-<date>`).
6. Rebuild every component with `./Scripts/build.sh --clean --regenerate`.

**Fresh worktree gotchas** (not SDK-related, but they hit any clean rebuild):
- Biography and Scrobble need their gitignored `SecretConfig.h`; symlink it from the main checkout.
- Effects DSP's `build.sh` ignores `--regenerate`; run `ruby Scripts/generate_xcode_project.rb` first.
- Playback Controls has no project generator; its `.xcodeproj` is local and untracked.

---

## References

- [foobar2000 Mac Download](https://www.foobar2000.org/mac)
- [SDK Changelog](https://www.foobar2000.org/changelog-sdk)
- [Development Overview](https://www.foobar2000.org/RTFM)
