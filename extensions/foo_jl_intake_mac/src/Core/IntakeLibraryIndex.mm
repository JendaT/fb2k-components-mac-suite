//
//  IntakeLibraryIndex.mm
//  foo_jl_intake
//

#include "IntakeLibraryIndex.h"

#include "IntakePath.h"

namespace intake {

std::shared_ptr<const LibraryIndex> LibraryIndex::build(const std::vector<PlacedRootFiles> &roots,
                                                        const LibraryPrefix &prefix, const MountAliases &aliases) {
    auto index = std::make_shared<LibraryIndex>(Token{});
    std::string libraryPath;
    std::string normalized;
    std::string aliased;
    for (const PlacedRootFiles &root : roots) {
        bool any = false;
        for (size_t i = 0; i < root.files.size(); i++) {
            if (root.files[i].shadow) continue;  // not placed: no library copy
            if (!libraryPathFor(root, i, prefix, libraryPath)) continue;
            if (normalizePath(libraryPath, normalized) != PathStatus::Ok) continue;
            const std::string_view key = aliases.rewrite(normalized, aliased);
            index->byPath_.insert(key, root.id,
                                  [](const std::string &existing, const std::string &candidate) {
                                      return candidate < existing;  // the lowest id wins
                                  });
            any = true;
        }
        if (any) index->rootCount_++;
    }
    return index;
}

std::shared_ptr<const LibraryIndex> LibraryIndex::empty() {
    static const std::shared_ptr<const LibraryIndex> none = std::make_shared<LibraryIndex>(Token{});
    return none;
}

const std::string *LibraryIndex::rootForKey(std::string_view key) const {
    return byPath_.find(key);
}

} // namespace intake
