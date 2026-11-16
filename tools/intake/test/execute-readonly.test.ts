// Execute with read-only income files, and a failing tag write.
// - copyFileSync keeps a 0444 original's mode: `metaflac --set-tag` on the
//   copy failed ("ERROR: writing FLAC file"), so did the mp3 writer, and then
//   the fsync's open for writing failed the root with EACCES. Execute adds u+w
//   to each copy (never to the original).
// - A failed tag write (metaflac_failed, metaflac_missing,
//   provenance_write_failed) fails the root before the commit point: no
//   target, no temp dir, no journal record, status back to `approved`, a
//   per-root E_VERIFY. On a writable copy it used to be an issue on a root
//   that was placed.
//
// The failing runs go through a CLI subprocess, because Bun.which() reads
// PATH at process start and ignores later changes to process.env.PATH: one
// PATH holds a fake `metaflac` that exits 1, the other no metaflac at all.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { audioHash } from "../src/audioHash.ts";
import { cmdResolve } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdPropose } from "../src/commands-p3.ts";
import { readJournal } from "../src/journal.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { sha1Hex } from "../src/util.ts";
import { makeTierRoots, setupCorpus, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const SYS_PATH = "/usr/bin:/bin";
const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};

let corpus: Corpus;
let journalPath: string;
let fakeBin: string;
let pollen: string; // FLAC root, every file 0444
let koan: string; // mp3 root, every file 0444
let sync24: string; // FLAC root for the failing tag writes

const sc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;
const mode = (p: string) => statSync(p).mode & 0o777;

/** relpath -> [mode, sha1] of every file in `dir` except the sidecar. */
function snapshot(dir: string): Record<string, [number, string]> {
  const out: Record<string, [number, string]> = {};
  for (const n of readdirSync(dir).sort()) {
    if (n === ".intake.json") continue;
    out[n] = [mode(join(dir, n)), sha1Hex(new Uint8Array(readFileSync(join(dir, n))))];
  }
  return out;
}

async function toApproved(dir: string): Promise<void> {
  expect((await cmdResolve([dir], OPTS)).errors).toEqual([]);
  expect((await cmdPropose([dir], OPTS)).errors).toEqual([]);
  expect(cmdApprove([dir], OPTS).errors).toEqual([]);
}

function cliExecute(path: string, ref: string): { code: number | null; envelope: Record<string, any> } {
  const env = { PATH: path, INTAKE_RULES_DIR: corpus.rules, HOME: process.env.HOME ?? "/tmp" };
  const proc = Bun.spawnSync([process.execPath, "run", CLI, "execute", ref, "--json"], {
    env, stdout: "pipe", stderr: "pipe", timeout: 30_000,
  });
  const out = proc.stdout.toString();
  if (!out.trim()) throw new Error(`no stdout; stderr: ${proc.stderr.toString()}`);
  return { code: proc.exitCode, envelope: JSON.parse(out) };
}

beforeAll(async () => {
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

  fakeBin = join(corpus.dir, "bin-fake-metaflac");
  mkdirSync(fakeBin, { recursive: true });
  writeFileSync(join(fakeBin, "metaflac"), "#!/bin/sh\necho 'ERROR: writing FLAC file' >&2\nexit 1\n");
  chmodSync(join(fakeBin, "metaflac"), 0o755);
  expect(Bun.which("metaflac", { PATH: `${fakeBin}:${SYS_PATH}` })).toBe(join(fakeBin, "metaflac"));
  expect(Bun.which("metaflac", { PATH: SYS_PATH })).toBeNull();

  pollen = join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  koan = join(corpus.income, "todo", "Koan-Condemned-(MKL033)-WEB-2016-KOAN");
  sync24 = join(corpus.income, "downloads", "Sync24 [2024] Omnimotion Remixed");
  for (const dir of [pollen, koan]) {
    for (const n of readdirSync(dir)) chmodSync(join(dir, n), 0o444);
  }
  for (const dir of [pollen, koan, sync24]) await toApproved(dir);
});

afterAll(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("roots of 0444 FLACs and mp3s are placed with tags written; the originals keep mode and bytes", async () => {
  const before = { pollen: snapshot(pollen), koan: snapshot(koan) };
  expect(Object.values(before.pollen).every(([m]) => m === 0o444)).toBe(true);
  expect(Object.values(before.koan).every(([m]) => m === 0o444)).toBe(true);

  const result = await cmdExecute([pollen, koan], OPTS);
  expect(result.errors).toEqual([]);
  const rows = result.data as { root_path: string; issues: string[] }[];
  expect(rows.map((r) => [r.root_path, r.issues])).toEqual([[pollen, []], [koan, []]]);

  for (const dir of [pollen, koan]) {
    const doc = sc(dir);
    expect(doc.status).toBe("placed");
    const target = doc.placed!.target_path;
    for (const f of doc.files) {
      const copy = join(target, f.path);
      expect((await audioHash(copy)).hash).toBe(f.audio_hash);
      expect(mode(copy) & 0o200).toBe(0o200);
      if (f.path.endsWith(".flac")) {
        const tags = Bun.spawnSync(["metaflac", "--export-tags-to=-", copy]).stdout.toString();
        expect(tags).toContain("INTAKE_DATE=");
        expect(tags).toContain("INTAKE_BATCH=b");
      } else {
        const head = readFileSync(copy).subarray(0, 512).toString("latin1");
        expect(head.startsWith("ID3")).toBe(true);
        expect(head).toContain("INTAKE_BATCH");
      }
    }
  }
  expect(mode(join(sc(pollen).placed!.target_path, "cover.jpg")) & 0o200).toBe(0o200);
  expect(snapshot(pollen)).toEqual(before.pollen);
  expect(snapshot(koan)).toEqual(before.koan);
});

/** The failed root: back to approved, nothing in the library, no journal record. */
function expectNotPlaced(): void {
  const doc = sc(sync24);
  expect(doc.status).toBe("approved");
  expect(doc.placed).toBeUndefined();
  expect(doc.history.slice(-2).map((h) => h.event)).toEqual(["placing", "execute_failed"]);
  const target = doc.proposal!.target_path!;
  expect(existsSync(target)).toBe(false);
  const parent = dirname(target);
  expect(existsSync(parent) ? readdirSync(parent).filter((n) => n.startsWith(".intake-tmp-")) : []).toEqual([]);
  const journal = existsSync(journalPath) ? readJournal(journalPath) : [];
  expect(journal.filter((r) => r.sidecar_id === doc.id)).toEqual([]);
}

test("metaflac failing: the root is not placed, and gets a per-root E_VERIFY", () => {
  const { code, envelope } = cliExecute(`${fakeBin}:${SYS_PATH}`, sync24);
  expect(code).toBe(2);
  expect(envelope.data).toBeNull();
  expect(envelope.errors).toHaveLength(1);
  expect(envelope.errors[0].code).toBe("E_VERIFY");
  expect(envelope.errors[0].path).toBe(sync24);
  expect(envelope.errors[0].msg).toBe("tag write failed: 01 - Omnimotion.flac (metaflac_failed: ERROR: writing FLAC file)");
  expectNotPlaced();
});

test("metaflac missing: the root is not placed either", () => {
  const { code, envelope } = cliExecute(SYS_PATH, sync24);
  expect(code).toBe(2);
  expect(envelope.errors.map((e: { code: string; msg: string; path: string }) => [e.code, e.msg, e.path])).toEqual([
    ["E_VERIFY", "tag write failed: 01 - Omnimotion.flac (metaflac_missing)", sync24],
  ]);
  expectNotPlaced();
});

test("with a working metaflac the same root is placed on the next execute", async () => {
  const result = await cmdExecute([sync24], OPTS);
  expect(result.errors).toEqual([]);
  expect(sc(sync24).status).toBe("placed");
  expect(readJournal(journalPath).filter((r) => r.sidecar_id === sc(sync24).id && r.event === "placed")).toHaveLength(1);
});
