//
//  IntakeMounts.mm
//  foo_jl_intake
//

#include "IntakeMounts.h"

#include <sys/mount.h>
#include <sys/param.h>
#include <sys/ucred.h>

#include <cstdlib>
#include <cstring>

namespace intake {

namespace {

std::string fixedString(const char *field, size_t capacity) {
    return std::string(field, strnlen(field, capacity));
}

} // anonymous namespace

std::vector<MountEntry> readMountTable() {
    std::vector<MountEntry> mounts;
    struct statfs *table = nullptr;
    const int count = getmntinfo_r_np(&table, MNT_NOWAIT);
    if (count <= 0 || table == nullptr) {
        free(table);
        return mounts;
    }
    mounts.reserve(static_cast<size_t>(count));
    for (int i = 0; i < count; i++) {
        const struct statfs &fs = table[i];
        MountEntry entry;
        entry.mountPoint = fixedString(fs.f_mntonname, sizeof fs.f_mntonname);
        entry.source = fixedString(fs.f_mntfromname, sizeof fs.f_mntfromname);
        entry.fsType = fixedString(fs.f_fstypename, sizeof fs.f_fstypename);
        mounts.push_back(std::move(entry));
    }
    free(table);
    return mounts;
}

} // namespace intake
