#import "ElementHost.h"

// ShellVanced's own GUID, defined in Main.mm. Used to refuse self-hosting
// (which would recurse forever).
extern const GUID g_guid_shellvanced;

static NSViewController* SVInstantiateElementUnsafe(const GUID& guid, NSDictionary<NSString*,NSString*>* params) {
    for (auto e : ui_element_mac::enumerate()) {
        if (e->get_guid() != guid) continue;

        NSDictionary<NSString*,NSString*>* arg = params ?: @{};
        service_ptr wrapped = e->instantiate(fb2k::wrapNSObject(arg));
        if (wrapped.is_empty()) {
            console::info("[ShellVanced] instantiate returned null");
            return nil;
        }
        id obj = fb2k::unwrapNSObject(wrapped);
        if (![obj isKindOfClass:[NSViewController class]]) {
            console::info("[ShellVanced] instantiate returned a non-NSViewController object");
            return nil;
        }
        return (NSViewController*)obj;
    }
    return nil;
}

NSViewController* SVInstantiateElement(const GUID& guid, NSDictionary<NSString*,NSString*>* params) {
    if (guid == g_guid_shellvanced) {
        return nil;
    }
    // The hosted element is foreign code: never let any exception escape.
    try {
        @try {
            return SVInstantiateElementUnsafe(guid, params);
        } @catch (NSException* ex) {
            FB2K_console_formatter() << "[ShellVanced] instantiate failed (NSException): "
                                     << (ex.name.UTF8String ?: "?") << ": "
                                     << (ex.reason.UTF8String ?: "");
        }
    } catch (std::exception const& ex) {
        FB2K_console_formatter() << "[ShellVanced] instantiate failed: " << ex.what();
    } catch (...) {
        console::info("[ShellVanced] instantiate failed: unknown exception");
    }
    return nil;
}
