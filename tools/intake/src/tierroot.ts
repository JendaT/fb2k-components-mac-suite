// Tier root availability. A placement must never land on a tier root that is
// missing, nor on a stale mount point: when a share is not mounted,
// /Volumes/<share> can still exist as an empty dir on the local disk, and
// execute would write the library copy there (and propose would read every
// collection there as empty). propose and execute refuse such a root with
// E_NO_TARGET, per root.

import { realpathSync, statSync } from "node:fs";
import { resolve } from "node:path";
import type { TierDef } from "./types.ts";

/** The filesystem facts the check needs; injected so tests never touch /Volumes. */
export interface MountFs {
  /** Canonical path of an existing directory; null when it does not exist or is not a directory. */
  realDir(path: string): string | null;
  /** st_dev of a path; null when it cannot be stat'ed. */
  dev(path: string): number | null;
}

export const DISK_MOUNT_FS: MountFs = {
  realDir(p) {
    try {
      const real = realpathSync.native(p);
      return statSync(real).isDirectory() ? real : null;
    } catch {
      return null;
    }
  },
  dev(p) {
    try {
      return statSync(p).dev;
    } catch {
      return null;
    }
  },
};

const VOLUMES = "/Volumes";

/** The configured tier whose root holds `target` (the longest matching root). */
export function tierOf(target: string, tiers: Record<string, TierDef>): { name: string; root: string } | null {
  const t = resolve(target);
  let best: { name: string; root: string } | null = null;
  for (const [name, def] of Object.entries(tiers)) {
    const root = resolve(def.root);
    if ((t === root || t.startsWith(root + "/")) && (!best || root.length > best.root.length)) best = { name, root };
  }
  return best;
}

/**
 * Why tier `name` (root `root`) cannot take placements, or null when it can.
 * Refused: the root does not exist (or is not a directory); or it resolves
 * under /Volumes/<name> and /Volumes/<name> is not a mount point (same st_dev
 * as /Volumes), i.e. a leftover dir on the local disk where a share should be
 * mounted. An empty tier root on a mounted share is fine.
 */
export function tierRootProblem(name: string, root: string, fs: MountFs = DISK_MOUNT_FS): string | null {
  const real = fs.realDir(root);
  if (real === null) return `tier ${name} root not found: ${root}`;
  const m = /^\/Volumes\/([^/]+)(?:\/|$)/.exec(real);
  if (m) {
    const mount = `${VOLUMES}/${m[1]}`;
    const volumesDev = fs.dev(VOLUMES);
    const mountDev = fs.dev(mount);
    if (volumesDev !== null && mountDev !== null && volumesDev === mountDev) {
      return `tier ${name} root ${root} is not on a mounted volume (${mount} is not a mount point)`;
    }
  }
  return null;
}

/** tierRootProblem for the tier holding `target`; null when no configured tier holds it. */
export function targetTierProblem(target: string, tiers: Record<string, TierDef>, fs: MountFs = DISK_MOUNT_FS): string | null {
  const tier = tierOf(target, tiers);
  return tier ? tierRootProblem(tier.name, tier.root, fs) : null;
}
