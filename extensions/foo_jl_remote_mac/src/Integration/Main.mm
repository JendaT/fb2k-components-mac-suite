//
//  Main.mm
//  foo_jl_remote_mac
//
//  Component registration and SDK integration.
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

#import "RemoteServer.h"

JL_COMPONENT_ABOUT(
    "LAN Remote",
    REMOTE_VERSION,
    "Control foobar2000 from a phone on your local network\n\n"
    "Features:\n"
    "- Web remote: open the address from Preferences > Tools > LAN Remote\n"
    "  in the phone's browser, or scan the QR code\n"
    "- Play, pause, stop, previous, next and seek\n"
    "- Fine volume control in dB with a configurable low-volume range\n"
    "- Playlist browser and the playing playlist: tap a track to play it\n"
    "- Local network only: outside addresses are refused"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_remote.component");

namespace {
    class remote_initquit : public initquit {
    public:
        void on_init() override {
            @autoreleasepool {
                [[RemoteServer shared] applyConfig];
            }
        }

        void on_quit() override {
            @autoreleasepool {
                [[RemoteServer shared] shutdown];
            }
        }
    };

    FB2K_SERVICE_FACTORY(remote_initquit);
}
