// gc on read-only income files: deletes all of a root's local files or none.
// A 0444 file in a 0555 disc dir (what an archive or a read-only share
// leaves) made rmSync throw EACCES partway: the root was half-deleted and the
// batch aborted. gc now stages every file by a rename inside the root's dir
// (or, with --relocate-dj, renames it to the dj zone) and reverses the renames
// when one fails; a read-only dir inside the root's dir gets u+w while gc
// works. The forced failure is `chflags uchg` on one file, which makes
// rename and unlink fail even for the owner.
//
// Each test places its own copy of the two-disc fixture, then makes it
// read-only. Cleanup always runs `chflags -R nouchg` first. An
// archive-sourced root shows what gc removes there: the root's own files
// only, never the archive or its `.unpacked` dir.

import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { audioHash } from "../src/audioHash.ts";
import { cmdResolve, cmdScan } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdGc, cmdPropose } from "../src/commands-p3.ts";
import { readJournal } from "../src/journal.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { sha1Hex } from "../src/util.ts";
import { makeTierRoots, makeTreeWritable, setupCorpus, type Corpus } from "./helpers.ts";
import { buildZip } from "./zipbuild.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};
const PCP = "[Psychill & Chillout & Psydub]";
const ASURA = "Asura [2003] Lost Eden (Ultimae Records; inre010)";
const BLOCKED = "CD2/02 - Golden Ocean.flac"; // mid-list: earlier files are staged before it fails

let corpus: Corpus;
let journalPath: string;
let djZone: string;
let release: string;

const sc = (): Sidecar => readSidecar(join(release, ".intake.json"))!;

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
        out[relative(dir, p)] = `file ${mode} ${sha1Hex(new Uint8Array(readFileSync(p)))}`;
      }
    }
  };
  walk(dir);
  return out;
}

const gcRecords = () => readJournal(journalPath).filter((r) => r.event !== "placed");

function uchg(path: string, on: boolean): void {
  const proc = Bun.spawnSync(["/usr/bin/chflags", on ? "uchg" : "nouchg", path]);
  if (proc.exitCode !== 0) throw new Error(`chflags failed: ${proc.stderr.toString()}`);
}

beforeEach(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  process.env.INTAKE_BEETS_SHIM = `bun ${join(import.meta.dir, "fakes", "fake-shim.ts")}`;
  const library = join(corpus.dir, "library");
  journalPath = join(corpus.dir, "journal", "intake-journal.ndjson");
  djZone = join(corpus.dir, "dj");
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${journalPath}`,
      "gc:",
      `  dj_zone: ${djZone}`,
      `  dj_collections: ["${PCP}"]`,
      "",
    ].join("\n"),
  );
  makeTierRoots(corpus.rules);
});

/** Resolve, propose, approve and execute `dir`, then make it read-only: 0444 files, 0555 disc dirs (one with a junk file). */
async function placeReadOnly(dir: string): Promise<void> {
  release = dir;
  expect((await cmdResolve([release], OPTS)).errors).toEqual([]);
  expect((await cmdPropose([release], OPTS)).errors).toEqual([]);
  expect(cmdApprove([release], OPTS).errors).toEqual([]);
  expect((await cmdExecute([release], OPTS)).errors).toEqual([]);
  expect(sc().status).toBe("placed");
  writeFileSync(join(release, "CD1", ".DS_Store"), new Uint8Array([0, 0, 0, 1]));
  for (const disc of ["CD1", "CD2"]) {
    for (const n of readdirSync(join(release, disc))) chmodSync(join(release, disc, n), 0o444);
    chmodSync(join(release, disc), 0o555);
  }
  chmodSync(join(release, "cover.jpg"), 0o444);
}

const placeAsura = () => placeReadOnly(join(corpus.income, "todo", ASURA));

afterEach(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  Bun.spawnSync(["/usr/bin/chflags", "-R", "nouchg", corpus.dir]);
  makeTreeWritable(corpus.dir);
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("gc deletes a read-only layout fully", async () => {
  await placeAsura();
  const result = await cmdGc([release], OPTS);
  expect(result.errors).toEqual([]);
  expect((result.data as { action: string }[])[0]!.action).toBe("delete");
  expect(readdirSync(release)).toEqual([".intake.json"]);
  expect(sc().status).toBe("gc_done");
  expect(gcRecords().map((r) => r.event)).toEqual(["gc_done"]);
});

test("a file gc cannot delete leaves the whole root in place", async () => {
  await placeAsura();
  uchg(join(release, BLOCKED), true);
  const before = snapshot(release);
  const history = sc().history.length;

  const result = await cmdGc([release], OPTS);
  expect(result.exitCode).toBe(2);
  expect(result.errors).toEqual([{
    code: "E_VERIFY",
    msg: `cannot delete "${BLOCKED}" (EPERM); nothing of the root was deleted`,
    path: join(release, BLOCKED),
  }]);
  expect(snapshot(release)).toEqual(before); // files, bytes, file and dir modes; no stage dir
  expect(sc().status).toBe("placed");
  expect(sc().history.length).toBe(history);
  expect(gcRecords()).toEqual([]);

  // Once the file can go, the same gc completes.
  uchg(join(release, BLOCKED), false);
  expect((await cmdGc([release], OPTS)).errors).toEqual([]);
  expect(readdirSync(release)).toEqual([".intake.json"]);
  expect(sc().status).toBe("gc_done");
});

test("--relocate-dj moves a read-only layout fully", async () => {
  await placeAsura();
  const files = sc().files;
  const result = await cmdGc([release], { ...OPTS, relocateDj: true });
  expect(result.errors).toEqual([]);
  const row = (result.data as { action: string; dj_dest: string }[])[0]!;
  expect(row.action).toBe("relocate_dj");
  expect(readdirSync(row.dj_dest).sort()).toEqual(["CD1", "CD2"]);
  for (const f of files) expect((await audioHash(join(row.dj_dest, f.path))).hash).toBe(f.audio_hash);
  expect(readdirSync(release)).toEqual([".intake.json"]);
  expect(sc().status).toBe("gc_done");
  expect(gcRecords().map((r) => r.event)).toEqual(["gc_relocated"]);
});

test("--relocate-dj with a file it cannot move leaves the root in place and nothing in the dj zone", async () => {
  await placeAsura();
  uchg(join(release, BLOCKED), true);
  const before = snapshot(release);

  const result = await cmdGc([release], { ...OPTS, relocateDj: true });
  expect(result.errors).toEqual([{
    code: "E_VERIFY",
    msg: `cannot relocate "${BLOCKED}" (EPERM); nothing of the root was moved or deleted`,
    path: join(release, BLOCKED),
  }]);
  expect(snapshot(release)).toEqual(before);
  expect(existsSync(djZone)).toBe(false); // the dirs gc created there are gone again
  expect(sc().status).toBe("placed");
  expect(gcRecords()).toEqual([]);
});

test("--relocate-dj onto an existing dj file: E_TARGET_EXISTS, nothing moved or replaced", async () => {
  await placeAsura();
  const dest = join(djZone, ASURA);
  mkdirSync(join(dest, "CD2"), { recursive: true });
  writeFileSync(join(dest, "CD2", "03 - The Prophecy.flac"), "already here\n");
  const before = snapshot(release);
  const djBefore = snapshot(djZone);

  const result = await cmdGc([release], { ...OPTS, relocateDj: true });
  expect(result.errors.map((e) => [e.code, e.path])).toEqual([
    ["E_TARGET_EXISTS", join(release, "CD2", "03 - The Prophecy.flac")],
  ]);
  expect(snapshot(release)).toEqual(before);
  expect(snapshot(djZone)).toEqual(djBefore); // no dir left from the rollback, the file not replaced
  expect(sc().status).toBe("placed");
});

test("archive-sourced root: gc deletes the root's files and keeps the archive and its .unpacked dir", async () => {
  const arc = join(corpus.dir, "arc");
  mkdirSync(arc, { recursive: true });
  writeFileSync(
    join(corpus.rules, "income.yaml"),
    ["income:", "  - name: arc", `    path: ${arc}`, "    source_type: web", ""].join("\n"),
  );
  const src = join(corpus.income, "todo", ASURA);
  const names = ["cover.jpg", ...["CD1", "CD2"].flatMap((d) => readdirSync(join(src, d)).sort().map((n) => `${d}/${n}`))];
  const zip = join(arc, `${ASURA}.zip`);
  writeFileSync(zip, buildZip(names.map((n) => ({ name: `${ASURA}/${n}`, data: new Uint8Array(readFileSync(join(src, n))) }))));
  expect((await cmdScan(["arc"], { ...OPTS, all: false })).errors).toEqual([]);
  const unpacked = join(arc, `${ASURA}.unpacked`);
  await placeReadOnly(join(unpacked, ASURA)); // the modes an unpack before the owner-write fix left
  expect(sc().source.archive).toBe(join("..", "..", `${ASURA}.zip`));
  const zipBytes = sha1Hex(new Uint8Array(readFileSync(zip)));

  const result = await cmdGc([release], OPTS);
  expect(result.errors).toEqual([]);
  expect(readdirSync(release)).toEqual([".intake.json"]);
  expect(readdirSync(arc).sort()).toEqual([`${ASURA}.unpacked`, `${ASURA}.zip`]);
  expect(readdirSync(unpacked)).toEqual([ASURA]);
  expect(sha1Hex(new Uint8Array(readFileSync(zip)))).toBe(zipBytes);
  expect(sc().status).toBe("gc_done");
});
