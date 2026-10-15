//
//  BpmMenu.mm
//  foo_jl_bpm_mac
//
//  "BPM" context menu: Analyze BPM..., Double BPM, Halve BPM. Registered as
//  a regular context menu item, so it appears in every playlist view that
//  builds its menu from foobar2000's context menu (SimPlaylist included).
//

#include "../fb2k_sdk.h"

#include "BpmAnalysis.h"
#include "BpmTagWriter.h"

namespace {

// {6F1C2B8A-4D3E-4A71-9C5B-2E8D7F104A63}
const GUID g_bpmGroupGUID =
    { 0x6f1c2b8a, 0x4d3e, 0x4a71, { 0x9c, 0x5b, 0x2e, 0x8d, 0x7f, 0x10, 0x4a, 0x63 } };
// {A3E95C17-6B20-4F8D-B41A-7C3D9E25F810}
const GUID g_analyzeGUID =
    { 0xa3e95c17, 0x6b20, 0x4f8d, { 0xb4, 0x1a, 0x7c, 0x3d, 0x9e, 0x25, 0xf8, 0x10 } };
// {5D7B0E42-91C6-4E3A-8F27-0B6A4C9D1E85}
const GUID g_doubleGUID =
    { 0x5d7b0e42, 0x91c6, 0x4e3a, { 0x8f, 0x27, 0x0b, 0x6a, 0x4c, 0x9d, 0x1e, 0x85 } };
// {C82F4A69-3E15-4B07-A6D8-95E1F0273B4C}
const GUID g_halveGUID =
    { 0xc82f4a69, 0x3e15, 0x4b07, { 0xa6, 0xd8, 0x95, 0xe1, 0xf0, 0x27, 0x3b, 0x4c } };

contextmenu_group_popup_factory g_bpmGroup(g_bpmGroupGUID, contextmenu_groups::root, "BPM", 0);

class BpmMenu : public contextmenu_item_simple {
public:
    enum { cmdAnalyze, cmdDouble, cmdHalve, cmdTotal };

    GUID get_parent() override { return g_bpmGroupGUID; }
    unsigned get_num_items() override { return cmdTotal; }

    void get_item_name(unsigned index, pfc::string_base &out) override {
        switch (index) {
            case cmdAnalyze: out = "Analyze BPM..."; break;
            case cmdDouble: out = "Double BPM"; break;
            case cmdHalve: out = "Halve BPM"; break;
            default: uBugCheck();
        }
    }

    GUID get_item_guid(unsigned index) override {
        switch (index) {
            case cmdAnalyze: return g_analyzeGUID;
            case cmdDouble: return g_doubleGUID;
            case cmdHalve: return g_halveGUID;
            default: uBugCheck();
        }
    }

    bool get_item_description(unsigned index, pfc::string_base &out) override {
        switch (index) {
            case cmdAnalyze:
                out = "Finds the tempo of the selected tracks (from TIDAL when it has the exact "
                      "track, otherwise by analysing the audio) and shows the results for review "
                      "before writing the BPM tag.";
                return true;
            case cmdDouble: out = "Multiplies the BPM tag of the selected tracks by two."; return true;
            case cmdHalve: out = "Divides the BPM tag of the selected tracks by two."; return true;
            default: return false;
        }
    }

    void context_command(unsigned index, metadb_handle_list_cref data, const GUID &) override {
        switch (index) {
            case cmdAnalyze: bpm::startAnalysis(data); break;
            case cmdDouble: bpm::scaleBpmTags(data, 2.0); break;
            case cmdHalve: bpm::scaleBpmTags(data, 0.5); break;
            default: uBugCheck();
        }
    }
};

FB2K_SERVICE_FACTORY(BpmMenu);

} // namespace
