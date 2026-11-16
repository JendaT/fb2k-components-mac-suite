// The user-immutable flag (uchg). On the Synology SMB share chmod 0444 has no
// effect; the read-only marker there is the DOS read-only attribute, which
// macOS shows as uchg, and it makes rename, unlink and chmod fail with EPERM
// even for the owner. gc used to fail every root holding such a file
// (correctly closed: nothing deleted). gc now clears uchg on the files it
// renames and on the dirs inside the root's dir it goes through, reports the
// files on the row, and sets the flag back when it fails. Nothing outside the
// root's files and dirs is touched, and no other flag is cleared (uappnd still
// fails the root; test/gc-readonly.test.ts).
//
// Execute: copyFileSync clones a file over 128 KiB on APFS, flags included,
// so a uchg original gave a uchg copy that could not be chmodded or tagged,
// and the temp dir holding it could not be removed. Execute clears uchg on its
// copies, never on the original.
//
// Every test that sets a flag clears it in `finally`; cleanup clears again
// before removing the tree.

import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { audioHash } from "../src/audioHash.ts";
import { cmdResolve } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdGc, cmdPropose } from "../src/commands-p3.ts";
import { readJournal } from "../src/journal.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { sha1Hex } from "../src/util.ts";
import { makeTierRoots, makeTreeWritable, setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};
const ASURA = "Asura [2003] Lost Eden (Ultimae Records; inre010)";
const FIRST = "CD1/01 - Lost Eden.flac"; // first in the root's file list
const BLOCKED = "CD2/02 - Golden Ocean.flac"; // mid-list
const UCHG = 0x2;
const UAPPND = 0x4;
const FLAG_MASK = UCHG | UAPPND | 0x20000 | 0x40000; // uchg, uappnd, schg, sappnd

let corpus: Corpus;
let journalPath: string;
let asura: string;

const sc = (path: string): Sidecar => readSidecar(path)!;
const sha1 = (p: string) => sha1Hex(new Uint8Array(readFileSync(p)));

/** The immutable and append-only flags on `p` itself (a symlink not followed). */
function flags(p: string): number {
  const proc = Bun.spawnSync(["/usr/bin/stat", "-f", "%f", p]);
  if (proc.exitCode !== 0) throw new Error(`stat failed: ${proc.stderr.toString()}`);
  return Number(proc.stdout.toString().trim()) & FLAG_MASK;
}

function setFlag(p: string, flag: "uchg" | "uappnd"): void {
  const proc = Bun.spawnSync(["/usr/bin/chflags", flag, p]);
  if (proc.exitCode !== 0) throw new Error(`chflags failed: ${proc.stderr.toString()}`);
}

const clearFlags = () => Bun.spawnSync(["/usr/bin/chflags", "-R", "nouchg,nouappnd", corpus.dir]);

/** Every entry under `dir`: relpath -> "dir <mode>" or "file <mode> <sha1>". */
function snapshot(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (d: string) => {
    for (const n of readdirSync(d).sort()) {
      const p = join(d, n);
      const st = lstatSync(p);
      const mode = (st.mode & 0o777).toString(8);
      if (st.isDirectory()) {
        out[relative(dir, p)] = `dir ${mode}`;
        walk(p);
      } else {
        out[relative(dir, p)] = `file ${mode} ${sha1(p)}`;
      }
    }
  };
  walk(dir);
  return out;
}

const gcRecords = () => readJournal(journalPath).filter((r) => r.event !== "placed");

beforeEach(() => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  process.env.INTAKE_BEETS_SHIM = `bun ${join(import.meta.dir, "fakes", "fake-shim.ts")}`;
  const library = join(corpus.dir, "library");
  journalPath = join(corpus.dir, "journal", "intake-journal.ndjson");
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${journalPath}`,
      "",
    ].join("\n"),
  );
  makeTierRoots(corpus.rules);
  asura = join(corpus.income, "todo", ASURA);
});

afterEach(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  clearFlags();
  makeTreeWritable(corpus.dir);
  rmSync(corpus.dir, { recursive: true, force: true });
});

/** Propose, approve and execute an already resolved root (path or id). */
async function place(ref: string): Promise<void> {
  expect((await cmdPropose([ref], OPTS)).errors).toEqual([]);
  expect(cmdApprove([ref], OPTS).errors).toEqual([]);
  expect((await cmdExecute([ref], OPTS)).errors).toEqual([]);
}

async function placeAsura(): Promise<void> {
  expect((await cmdResolve([asura], OPTS)).errors).toEqual([]);
  await place(asura);
  expect(sc(join(asura, ".intake.json")).status).toBe("placed");
}

test("gc deletes a uchg file in a placed root and reports it on the row", async () => {
  await placeAsura();
  try {
    setFlag(join(asura, FIRST), "uchg");
    expect(flags(join(asura, FIRST))).toBe(UCHG);
    const id = sc(join(asura, ".intake.json")).id;

    const result = await cmdGc([asura], OPTS);
    expect(result.errors).toEqual([]);
    expect(result.data).toEqual([{
      id, root_path: asura, action: "delete", dj_dest: null, issues: ["cleared_readonly_flag: 1 file(s)"],
    }]);
    expect(readdirSync(asura)).toEqual([".intake.json"]);
    expect(sc(join(asura, ".intake.json")).status).toBe("gc_done");
    expect(gcRecords().map((r) => r.event)).toEqual(["gc_done"]);
  } finally {
    clearFlags();
  }
});

test("gc of a virtual root leaves a uchg neighbour, a uchg sibling and the root dir's uchg as they were", async () => {
  const mix = join(corpus.income, "slsk", "random_mix");
  expect((await cmdResolve([mix], OPTS)).errors).toEqual([]);
  const sidecarName = readdirSync(mix)
    .filter((n) => /^\.intake\..*\.json$/.test(n))
    .find((n) => sc(join(mix, n)).cluster.albumartist === "E-Mantra")!;
  const sidecarPath = join(mix, sidecarName);
  const id = sc(sidecarPath).id;
  await place(id);
  expect(sc(sidecarPath).status).toBe("placed");

  const own = join(mix, "emantra_1_arcana.flac"); // one of the root's files
  const neighbour = join(mix, "koan_1_argonautica.mp3"); // same dir, another root's file
  const sibling = join(corpus.income, "slsk", "notes.txt"); // in the income folder, outside the root's dir
  writeFileSync(sibling, "synthetic\n");
  const neighbourBytes = sha1(neighbour);
  try {
    for (const p of [own, neighbour, sibling, mix]) setFlag(p, "uchg");

    const result = await cmdGc([id], OPTS);
    expect(result.errors).toEqual([]);
    expect((result.data as { issues: string[] }[])[0]!.issues).toEqual(["cleared_readonly_flag: 1 file(s)"]);
    expect(existsSync(own)).toBe(false);
    expect(existsSync(join(mix, "emantra_2_nocturne.flac"))).toBe(false);
    expect(flags(neighbour)).toBe(UCHG);
    expect(sha1(neighbour)).toBe(neighbourBytes);
    expect(flags(sibling)).toBe(UCHG);
    expect(readFileSync(sibling, "utf8")).toBe("synthetic\n");
    // The root's dir gets its flag back, and the tombstone was still written.
    expect(flags(mix)).toBe(UCHG);
    expect(sc(sidecarPath).status).toBe("gc_done");
    expect(readdirSync(mix).filter((n) => n.startsWith(".intake-gc-"))).toEqual([]);
  } finally {
    clearFlags();
  }
});

test("a failed gc sets back the uchg it cleared, after the modes", async () => {
  await placeAsura();
  try {
    setFlag(join(asura, FIRST), "uchg");
    chmodSync(join(asura, "CD1"), 0o555);
    setFlag(join(asura, "CD1"), "uchg");
    setFlag(join(asura, BLOCKED), "uappnd"); // gc never clears it
    const before = snapshot(asura);
    const history = sc(join(asura, ".intake.json")).history.length;

    const result = await cmdGc([asura], OPTS);
    expect(result.exitCode).toBe(2);
    expect(result.errors).toEqual([{
      code: "E_VERIFY",
      msg: `cannot delete "${BLOCKED}" (EPERM); nothing of the root was deleted`,
      path: join(asura, BLOCKED),
    }]);
    expect(snapshot(asura)).toEqual(before); // files, bytes, modes (CD1 0555); no stage dir
    expect(flags(join(asura, FIRST))).toBe(UCHG);
    expect(flags(join(asura, "CD1"))).toBe(UCHG);
    expect(flags(join(asura, BLOCKED))).toBe(UAPPND);
    expect(flags(asura)).toBe(0);
    expect(sc(join(asura, ".intake.json")).status).toBe("placed");
    expect(sc(join(asura, ".intake.json")).history.length).toBe(history);
    expect(gcRecords()).toEqual([]);
  } finally {
    clearFlags();
  }
});

// The bookkeeping after a disposal (the journal line, then the gc_done
// tombstone rewriting the sidecar in place) used to fail only after the
// files were gone: a uchg, 0444 or uappnd sidecar, or a journal that cannot
// be appended to, left a disposal with no journal line or a journal and a
// sidecar that disagree. gc now clears the sidecar's uchg and adds u+w
// before disposing (and puts them back after the tombstone), and checks that
// the sidecar opens read-write and the journal for append.

test("gc of a root whose sidecar has uchg writes the tombstone and the journal line, then sets uchg back", async () => {
  await placeAsura();
  const side = join(asura, ".intake.json");
  try {
    setFlag(side, "uchg");
    const id = sc(side).id;

    const result = await cmdGc([asura], OPTS);
    expect(result.errors).toEqual([]);
    // The sidecar keeps its flag, so it is not counted as cleared.
    expect(result.data).toEqual([{ id, root_path: asura, action: "delete", dj_dest: null, issues: [] }]);
    expect(readdirSync(asura)).toEqual([".intake.json"]);
    expect(sc(side).status).toBe("gc_done");
    expect(sc(side).history.at(-1)!.event).toBe("gc_done");
    expect(gcRecords().map((r) => [r.event, r.sidecar_id])).toEqual([["gc_done", id]]);
    expect(flags(side)).toBe(UCHG);
  } finally {
    clearFlags();
  }
});

test("gc of a root whose sidecar is 0444 writes the tombstone, then puts the mode back", async () => {
  await placeAsura();
  const side = join(asura, ".intake.json");
  try {
    chmodSync(side, 0o444);
    const result = await cmdGc([asura], OPTS);
    expect(result.errors).toEqual([]);
    expect(sc(side).status).toBe("gc_done");
    expect(gcRecords().map((r) => r.event)).toEqual(["gc_done"]);
    expect(statSync(side).mode & 0o777).toBe(0o444);
  } finally {
    chmodSync(side, 0o644);
  }
});

test("a journal that cannot be appended to: gc disposes nothing, the root stays placed, the sidecar keeps its flag", async () => {
  await placeAsura();
  const side = join(asura, ".intake.json");
  try {
    setFlag(side, "uchg");
    setFlag(join(asura, FIRST), "uchg");
    chmodSync(journalPath, 0o444);
    const before = snapshot(asura);
    const journalBefore = readFileSync(journalPath, "utf8");

    const result = await cmdGc([asura], OPTS);
    expect(result.exitCode).toBe(2);
    expect(result.errors).toEqual([{
      code: "E_NO_JOURNAL",
      msg: "cannot append to the journal (EACCES); nothing of the root was deleted",
      path: journalPath,
    }]);
    expect(snapshot(asura)).toEqual(before); // files, bytes, modes; no stage dir
    expect(flags(side)).toBe(UCHG); // restored at once
    expect(flags(join(asura, FIRST))).toBe(UCHG); // never cleared: disposal did not start
    expect(sc(side).status).toBe("placed");
    expect(readFileSync(journalPath, "utf8")).toBe(journalBefore);
  } finally {
    clearFlags();
    chmodSync(journalPath, 0o644);
  }
});

test("an append-only (uappnd) sidecar: gc refuses the root before anything is deleted", async () => {
  await placeAsura();
  const side = join(asura, ".intake.json");
  try {
    setFlag(side, "uappnd"); // gc never clears it
    const before = snapshot(asura);

    const result = await cmdGc([asura], OPTS);
    expect(result.exitCode).toBe(2);
    expect(result.errors).toEqual([{
      code: "E_VERIFY",
      msg: "cannot write the sidecar (EPERM); nothing of the root was deleted",
      path: side,
    }]);
    expect(snapshot(asura)).toEqual(before);
    expect(flags(side)).toBe(UAPPND);
    expect(sc(side).status).toBe("placed");
    expect(gcRecords()).toEqual([]);
  } finally {
    clearFlags();
  }
});

test("execute of a root with a uchg original places it with tags written; the original keeps its flag and bytes", async () => {
  const original = join(asura, FIRST);
  // Over 128 KiB, so copyFileSync clones it on APFS and the clone carries the flag.
  const pad = Bun.spawnSync(["metaflac", "--add-padding=262144", original]);
  expect(pad.exitCode).toBe(0);
  expect(statSync(original).size).toBeGreaterThan(128 * 1024);
  try {
    setFlag(original, "uchg");
    const bytes = sha1(original);
    await placeAsura();

    const doc = sc(join(asura, ".intake.json"));
    const target = doc.placed!.target_path;
    for (const f of doc.files) expect((await audioHash(join(target, f.path))).hash).toBe(f.audio_hash);
    const copy = join(target, FIRST);
    expect(flags(copy)).toBe(0);
    expect(statSync(copy).mode & 0o200).toBe(0o200);
    const tags = Bun.spawnSync(["metaflac", "--export-tags-to=-", copy]).stdout.toString();
    expect(tags).toContain("INTAKE_DATE=");
    expect(tags).toContain("INTAKE_BATCH=");
    expect(flags(original)).toBe(UCHG);
    expect(sha1(original)).toBe(bytes);
    expect(readdirSync(join(target, "..")).filter((n) => n.startsWith(".intake-tmp-"))).toEqual([]);
  } finally {
    clearFlags();
  }
});
