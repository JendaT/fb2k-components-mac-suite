//
//  ImportSorter.cpp
//  foo_simplaylist_mac
//

#include "ImportSorter.h"

#include <algorithm>
#include <map>
#include <numeric>
#include <set>
#include <tuple>

namespace simplaylist {

std::vector<size_t> planImportOrder(const std::vector<ImportSortKey> &keys) {
    // An album is a compilation when its tracks disagree about the album artist.
    std::map<std::string, std::set<std::string>> artistsPerAlbum;
    for (const auto &k : keys) {
        if (k.album.empty()) continue;
        artistsPerAlbum[k.album].insert(k.albumArtist);
    }

    auto isCompilation = [&](const ImportSortKey &k) {
        if (k.album.empty()) return false;
        auto it = artistsPerAlbum.find(k.album);
        return it != artistsPerAlbum.end() && it->second.size() > 1;
    };

    std::vector<size_t> order(keys.size());
    std::iota(order.begin(), order.end(), 0);
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        const ImportSortKey &ka = keys[a];
        const ImportSortKey &kb = keys[b];
        // Dropping the artist from the key collapses a compilation's tracks into
        // one group ordered purely by disc/track.
        const std::string artistA = isCompilation(ka) ? std::string() : ka.albumArtist;
        const std::string artistB = isCompilation(kb) ? std::string() : kb.albumArtist;
        return std::tie(artistA, ka.album, ka.disc, ka.track, ka.path) <
               std::tie(artistB, kb.album, kb.disc, kb.track, kb.path);
    });
    return order;
}

}  // namespace simplaylist
