#import "ShellPlaylistCallbacks.h"
#include "../fb2k_sdk.h"
#include "../Core/ShellCore.h"

NSNotificationName const SVPlaylistsDidChangeNotification      = @"SVPlaylistsDidChangeNotification";
NSNotificationName const SVPlaylistRenamedNotification         = @"SVPlaylistRenamedNotification";
NSNotificationName const SVActivePlaylistDidChangeNotification = @"SVActivePlaylistDidChangeNotification";

namespace {

bool g_changePending = false;
bool g_activePending = false;

// Renames wait here and are posted, in order, right before the next
// structure-change post (same turn), so the shell never sees a stale change
// first and mistakes a renamed playlist for a deleted one.
NSMutableArray<NSDictionary*>* g_pendingRenames = nil;

void drainRenames() {
    if (g_pendingRenames.count == 0) return;
    NSArray<NSDictionary*>* renames = [g_pendingRenames copy];
    [g_pendingRenames removeAllObjects];
    for (NSDictionary* info in renames) {
        [[NSNotificationCenter defaultCenter] postNotificationName:SVPlaylistRenamedNotification
                                                            object:nil
                                                          userInfo:info];
    }
}

void schedulePost(bool& pending, NSNotificationName name) {
    if (pending) return;
    pending = true;
    bool* flag = &pending;
    dispatch_async(dispatch_get_main_queue(), ^{
        *flag = false;
        if ([name isEqualToString:SVPlaylistsDidChangeNotification]) drainRenames();
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil];
    });
}

NSString* toNS(const std::string& s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

// One shared observer for every shell instance. Keeps a snapshot of playlist
// names so renames can report the old name and item-count changes on the
// hidden "Now Playing" playlist (which churns on every play action) are
// ignored.
class SVPlaylistObserver : public playlist_callback_impl_base {
public:
    SVPlaylistObserver()
        : playlist_callback_impl_base(flag_on_items_added | flag_on_items_removed |
                                      flag_on_playlist_activate | flag_on_playlist_created |
                                      flag_on_playlists_reorder | flag_on_playlists_removed |
                                      flag_on_playlist_renamed) {
        snapshot();
    }

    void on_items_added(t_size p_playlist, t_size, metadb_handle_list_cref, const bit_array&) override {
        countChanged(p_playlist);
    }
    void on_items_removed(t_size p_playlist, const bit_array&, t_size, t_size) override {
        countChanged(p_playlist);
    }
    void on_playlist_activate(t_size, t_size) override {
        schedulePost(g_activePending, SVActivePlaylistDidChangeNotification);
    }
    void on_playlist_created(t_size, const char*, t_size) override { structureChanged(); }
    void on_playlists_reorder(const t_size*, t_size) override { structureChanged(); }
    void on_playlists_removed(const bit_array&, t_size, t_size) override { structureChanged(); }

    void on_playlist_renamed(t_size p_index, const char* p_new_name, t_size p_new_name_len) override {
        std::string oldName = p_index < m_names.size() ? m_names[p_index] : std::string();
        std::string newName(p_new_name, strnlen(p_new_name, p_new_name_len));
        if (!oldName.empty() && oldName != newName) {
            NSDictionary* info = @{ @"old": toNS(oldName), @"new": toNS(newName) };
            if (!g_pendingRenames) g_pendingRenames = [NSMutableArray array];
            [g_pendingRenames addObject:info];
        }
        structureChanged();   // always follows, so the queued rename is drained before it posts
    }

private:
    void snapshot() {
        auto pm = playlist_manager::get();
        const t_size n = pm->get_playlist_count();
        m_names.clear();
        m_names.reserve(n);
        pfc::string8 name;
        for (t_size i = 0; i < n; ++i) {
            name.reset();
            pm->playlist_get_name(i, name);
            m_names.emplace_back(name.c_str());
        }
    }

    void structureChanged() {
        snapshot();
        schedulePost(g_changePending, SVPlaylistsDidChangeNotification);
    }

    void countChanged(t_size playlist) {
        if (playlist < m_names.size() && m_names[playlist] == shellcore::kNowPlayingPlaylistName) return;
        schedulePost(g_changePending, SVPlaylistsDidChangeNotification);
    }

    std::vector<std::string> m_names;
};

// Raw pointer, not a static unique_ptr: a static destructor runs from exit() after foobar's
// services are gone, and the base destructor's playlist_manager::get() then crashes on quit.
SVPlaylistObserver *g_observer = nullptr;
int g_refs = 0;
bool g_shutDown = false;

} // namespace

void SVPlaylistCallbacksRetain(void) {
    if (g_refs++ == 0 && !g_shutDown) {
        try {
            g_observer = new SVPlaylistObserver();
        } catch (...) {
            console::info("[ShellVanced] failed to register playlist callback");
        }
    }
}

void SVPlaylistCallbacksRelease(void) {
    if (g_refs <= 0) return;
    if (--g_refs == 0) {
        delete g_observer;
        g_observer = nullptr;
    }
}

void SVPlaylistCallbacksShutdown(void) {
    g_shutDown = true;
    delete g_observer;
    g_observer = nullptr;
}
