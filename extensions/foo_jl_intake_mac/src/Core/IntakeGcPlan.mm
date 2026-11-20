//
//  IntakeGcPlan.mm
//  foo_jl_intake
//

#include "IntakeGcPlan.h"

#include <algorithm>

namespace intake {

namespace {

std::string joinPath(const std::string &directory, const std::string &name) {
    if (!directory.empty() && directory.back() == '/') return directory + name;
    return directory + "/" + name;
}

} // anonymous namespace

std::vector<std::string> gcLocalPaths(const PlacedRootFiles &files) {
    std::vector<std::string> out;
    out.reserve(files.files.size());
    for (const SidecarFile &f : files.files) out.push_back(joinPath(files.rootPath, f.path));
    return out;
}

GcConfirmRoot gcConfirmRoot(const ActionRoot &root, const PlacedRootFiles *files, const std::string &error) {
    GcConfirmRoot c;
    c.root = root;
    if (files != nullptr) {
        c.filesKnown = true;
        c.wholeFolder = files->wholeFolder;
        c.localPaths = gcLocalPaths(*files);
    } else {
        c.filesError = error.empty() ? std::string("its sidecar could not be read") : error;
    }
    return c;
}

std::vector<std::string> gcAllPaths(const std::vector<GcConfirmRoot> &roots) {
    std::vector<std::string> out;
    for (const GcConfirmRoot &r : roots) out.insert(out.end(), r.localPaths.begin(), r.localPaths.end());
    return out;
}

std::string gcConfirmTitle(size_t roots) {
    if (roots == 1) return "Delete the local copy of this album?";
    return "Delete the local copies of " + std::to_string(roots) + " albums?";
}

std::string gcConfirmText(const std::vector<GcConfirmRoot> &roots, const GcIncomeRows &income, size_t maxListed) {
    const std::vector<std::string> paths = gcAllPaths(roots);
    std::string out;
    const size_t listed = std::min(paths.size(), maxListed);
    for (size_t i = 0; i < listed; i++) {
        if (!out.empty()) out += "\n";
        out += paths[i];
    }
    if (paths.size() > listed) {
        if (!out.empty()) out += "\n";
        out += "and " + std::to_string(paths.size() - listed) + " more";
    }
    if (paths.empty()) out = "No local file list could be read.";

    std::string notes;
    const bool anyWhole = std::any_of(roots.begin(), roots.end(), [](const GcConfirmRoot &r) {
        return r.filesKnown && r.wholeFolder;
    });
    if (anyWhole) {
        notes += "\n\nThe other files in these folders that were copied to the library (covers, cues, logs) are "
                 "deleted too.";
    }
    for (const GcConfirmRoot &r : roots) {
        if (r.filesKnown) continue;
        notes += "\n\nThe file list of " + albumLabel(r.root) + " could not be read: " + r.filesError + ".";
    }
    const size_t rows = income.rows;
    if (rows > 0) {
        const std::string where = income.inFirst == rows ? std::string(" in the active playlist")
                                                         : " in " + std::to_string(income.playlists) + " playlists";
        notes += "\n\n" + std::to_string(rows) + (rows == 1 ? " row" : " rows") + where + " still " +
                 (rows == 1 ? "plays" : "play") + " these files.";
        if (income.offerSwap()) {
            notes += std::string(" \"Swap, then delete\" points ") + (rows == 1 ? "it" : "them") +
                     " at the library copies first.";
        } else {
            const size_t k = income.noLibraryCopy;
            notes += " " + std::to_string(k) + (k == 1 ? " of them has" : " of them have") +
                     " no library copy (a quality shadow or a file the sidecar does not list), so Delete leaves " +
                     (k == 1 ? "it as a dead entry." : "them as dead entries.");
        }
    }
    if (income.unchecked > 0) {
        const size_t u = income.unchecked;
        notes += "\n\n" + std::to_string(u) + (u == 1 ? " playlist row" : " playlist rows") +
                 " on a slow volume or under a share link could not be checked.";
        if (income.offerSwap()) notes += " \"Swap, then delete\" deletes nothing while a row is unchecked.";
    }
    notes += "\n\nThe library copies stay. gc checks them against the journal before it deletes anything.";
    return out + notes;
}

std::string gcConfirmSummary(const std::vector<GcConfirmRoot> &roots, const GcIncomeRows &income, size_t maxListed) {
    const std::vector<std::string> paths = gcAllPaths(roots);
    std::string out = std::to_string(paths.size()) + " path(s)";
    const size_t listed = std::min(paths.size(), maxListed);
    for (size_t i = 0; i < listed; i++) out += (i == 0 ? ": " : " | ") + paths[i];
    if (paths.size() > listed) out += " (+" + std::to_string(paths.size() - listed) + " more)";
    size_t unreadable = 0;
    for (const GcConfirmRoot &r : roots) unreadable += r.filesKnown ? 0 : 1;
    if (unreadable > 0) out += "; " + std::to_string(unreadable) + " root(s) without a file list";
    if (income.offerSwap()) {
        out += "; Swap, then delete offered (" + std::to_string(income.rows) + " income row(s)";
        if (income.inFirst != income.rows) out += " in " + std::to_string(income.playlists) + " playlist(s)";
        out += ")";
    } else if (income.rows > 0) {
        out += "; Swap, then delete not offered (" + std::to_string(income.rows) + " income row(s), " +
               std::to_string(income.noLibraryCopy) + " without a library copy)";
    } else {
        out += "; Swap, then delete not offered (no income row)";
    }
    if (income.unchecked > 0) {
        out += "; " + std::to_string(income.unchecked) + " row(s) not checked (slow volume or share link)";
    }
    return out;
}

GcRecheck recheckGcRoots(const std::vector<ActionRoot> &roots,
                         const std::function<const IntakeRecord *(const std::string &id)> &lookup) {
    GcRecheck out;
    for (const ActionRoot &root : roots) {
        const IntakeRecord *now = lookup ? lookup(root.id) : nullptr;
        if (now == nullptr) {
            out.dropped.emplace_back(root.id, "no longer listed by intake status");
        } else if (now->status != IntakeStatus::Placed) {
            out.dropped.emplace_back(root.id, std::string("now ") + intakeStatusName(now->status) + ", not placed");
        } else if (!now->hasPlaced || !now->placedVerified) {
            out.dropped.emplace_back(root.id, "placed.verified is no longer true");
        } else {
            ActionRoot kept = root;
            kept.status = now->status;
            kept.placedVerified = true;
            kept.placedTargetPath = now->placedTargetPath;
            out.keep.push_back(std::move(kept));
        }
    }
    return out;
}

} // namespace intake
