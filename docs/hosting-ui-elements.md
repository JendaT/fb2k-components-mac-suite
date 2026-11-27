# Hosting another component's UI element (macOS)

How ShellVanced embeds AlbumViewVanced and SimPlaylist inside its own view, plus the gotchas found while building it (2026-11).

## The mechanism

On macOS every layout element is a `ui_element_mac` service. Any component can enumerate them and instantiate one:

```cpp
for (auto e : ui_element_mac::enumerate()) {
    if (e->get_guid() != targetGuid) continue;
    service_ptr wrapped = e->instantiate(fb2k::wrapNSObject(params ?: @{}));   // params: NSDictionary<NSString*,NSString*>
    id obj = fb2k::unwrapNSObject(wrapped);                                     // an NSViewController
}
```

- `params` is the same dictionary the layout editor passes, the key/value pairs written as `element(key=value)` in UI-Layout.txt. SimPlaylist reads `vanced=1` from it to switch on shell mode.
- Add the returned controller with `addChildViewController:` and put its view in your hierarchy. AppKit delivers `viewWillAppear`/`viewDidAppear` when the view enters a window. No manual forwarding is needed, and forwarding by hand caused double loads.
- See `extensions/foo_jl_shellvanced_mac/src/Integration/ElementHost.mm` (`SVInstantiateElement`).

## Gotchas

- **Treat the hosted element as foreign code.** Wrap `instantiate` in `try { @try { … } @catch (NSException*) {} } catch (...) {}`. A missing or broken component must give a placeholder, never a crash.
- **Refuse to host yourself.** If the host's own GUID can be instantiated, it recurses forever.
- **The element is a separate dylib.** You can't import its headers or classes. Talk to it with `respondsToSelector:` and `performSelector:` (for example AlbumViewVanced's `setArtistFilter:`), through SDK services, or through header-only code in `shared/`.
- **Objective-C class names are process-global.** Two components that define the same class name collide at load time, and one wins silently. Prefix every class per component (ShellVanced uses `SV…`). Biography already owns `DeezerClient`, `ArtistImageCache` and `RateLimiter`.
- **No tab-switching API.** foobar's `tabs` and `splitter` containers are plain `NSTabViewController`/`NSSplitViewController` subclasses, and the SDK has no API to switch tabs. That is why ShellVanced hosts its pages itself instead of driving foobar's tabs.
- **Key equivalents.** A container view's `performKeyEquivalent:` runs before foobar's main menu. Check `window.isKeyWindow` and `isHiddenOrHasHiddenAncestor`, so a hidden page never steals ⌘F. Only ⌘F collided with foobar's own shortcuts (Find…), and it is taken over on purpose.
- **Active playlist coupling.** SimPlaylist always shows the *active* playlist, so showing a playlist page means calling `set_active_playlist`. Shared playback helpers (`shared/UpNext.h`) must never call it. Only the shell does, and only to show a page.
- **"Playback follows cursor" is incompatible** with the single up-next model. With it on, foobar plays from the focused playlist instead of "Now Playing". Leave it off when using the shell.

## Build note

Xcode 27.2 refuses `MACOSX_DEPLOYMENT_TARGET = 11.0`. Every `generate_xcode_project.rb` now sets 12.0, so after pulling, run `./Scripts/build.sh --regenerate` once per component.
