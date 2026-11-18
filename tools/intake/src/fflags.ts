// BSD file flags on macOS. Node and Bun expose neither st_flags nor
// chflags(2), so flags are read with /usr/bin/stat and changed with
// /usr/bin/chflags.
//
// The one flag intake changes is the user-immutable flag (uchg,
// UF_IMMUTABLE). macOS shows an SMB share's DOS read-only attribute as uchg;
// chmod cannot clear it, and it makes rename, unlink, chmod and a write fail
// with EPERM even for the owner. A clone keeps it too: copyFileSync clones a
// file over 128 KiB on APFS, flags included. uappnd, schg and sappnd are
// never changed. On other platforms every function here does nothing.

import { resolve } from "node:path";

export const UF_IMMUTABLE = 0x2;

const STAT = "/usr/bin/stat";
const CHFLAGS = "/usr/bin/chflags";
/** Path bytes per spawn, well under ARG_MAX (1 MiB on macOS). */
const ARG_BUDGET = 256 * 1024;
const enabled = process.platform === "darwin";

/** `paths` (made absolute, so none reads as an option) split into argv-sized groups. */
function batches(paths: string[]): string[][] {
  const out: string[][] = [];
  let cur: string[] = [];
  let bytes = 0;
  for (const p of paths.map((x) => resolve(x))) {
    const n = Buffer.byteLength(p) + 1;
    if (cur.length > 0 && bytes + n > ARG_BUDGET) {
      out.push(cur);
      cur = [];
      bytes = 0;
    }
    cur.push(p);
    bytes += n;
  }
  if (cur.length > 0) out.push(cur);
  return out;
}

function run(argv: string[]): { ok: boolean; stdout: string } {
  try {
    const proc = Bun.spawnSync(argv, { stdout: "pipe", stderr: "pipe" });
    return { ok: proc.exitCode === 0, stdout: proc.stdout.toString() };
  } catch {
    return { ok: false, stdout: "" };
  }
}

/**
 * The entries of `paths` that carry uchg, read like lstat (a symlink's own
 * flags). One spawn per argv-sized group. A group whose flags cannot all be
 * read (an entry vanished) counts as unflagged: what then fails reports
 * itself.
 */
export function immutablePaths(paths: string[]): string[] {
  if (!enabled || paths.length === 0) return [];
  const out: string[] = [];
  let i = 0;
  for (const batch of batches(paths)) {
    const r = run([STAT, "-f", "%f", ...batch]);
    const lines = r.stdout.split("\n").filter((l) => l !== "");
    if (r.ok && lines.length === batch.length) {
      for (const [j, line] of lines.entries()) if (Number(line) & UF_IMMUTABLE) out.push(paths[i + j]!);
    }
    i += batch.length;
  }
  return out;
}

/**
 * Set (`on`) or clear uchg on each entry of `paths`; a symlink's own flags,
 * never its target's (chflags -h). Returns whether every change worked.
 */
export function setImmutable(paths: string[], on: boolean): boolean {
  if (!enabled || paths.length === 0) return true;
  let ok = true;
  for (const batch of batches(paths)) ok = run([CHFLAGS, "-h", on ? "uchg" : "nouchg", ...batch]).ok && ok;
  return ok;
}

/**
 * Clear uchg on `dir` and everything under it in one spawn. No symlink is
 * followed or changed (chflags -R -P). Returns whether every change worked.
 */
export function clearImmutableTree(dir: string): boolean {
  if (!enabled) return true;
  return run([CHFLAGS, "-R", "-P", "nouchg", resolve(dir)]).ok;
}
