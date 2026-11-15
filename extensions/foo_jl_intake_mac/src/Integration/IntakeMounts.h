//
//  IntakeMounts.h
//  foo_jl_intake
//
//  Reads the mount table for IntakeMountAliases (PLAN.md B3).
//
//  getmntinfo_r_np(MNT_NOWAIT): the kernel's cached statfs data, so no call
//  reaches a server and an unreachable share cannot block it. It is the
//  thread-safe form of getmntinfo (which returns a shared static buffer
//  that another caller may overwrite). Never statfs/MNT_WAIT or realpath on
//  a share path.
//
//  MountEntry::local is MNT_LOCAL from f_flags (IntakeWatchSet uses it to
//  keep lstat/readlink off network paths).
//
//  Called on the loader queue at the first load, after
//  NSWorkspaceDidMount/DidUnmount notifications, and before every watch set
//  build. Unit tests feed synthetic
//  lists to IntakeMountAliases instead; nothing here runs in them.
//
//  Thread-safety: reentrant.
//

#pragma once

#include <vector>

#include "../Core/IntakeMountAliases.h"

namespace intake {

// Every mounted filesystem, in mount order; empty when the table cannot be
// read.
std::vector<MountEntry> readMountTable();

} // namespace intake
