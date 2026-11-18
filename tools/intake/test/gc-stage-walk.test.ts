// A gc that dies between staging a root's files and deleting them leaves
// `.intake-gc-<id>/` inside the root's dir, holding the root's audio
// (src/commands-p3.ts disposeLocal; a gc rerun finishes the job). Resolve
// must never make a root of that dir, as with a `.unpacked.partial` dir: a
// spurious root of already-placed audio. Temp corpus and fixture audio only.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { walkDirs } from "../src/util.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, collection: null, by: null,
  allResolved: false, batch: null, approved: false, resume: false,
};

let corpus: Corpus;
let release: string;
let stage: string;

beforeAll(() => {
  corpus = setupCorpus();
  // A placed release whose gc died mid-way: its audio sits in the stage dir,
  // disc subdir kept, and the release dir itself holds no audio any more.
  release = join(corpus.income, "todo", "Example Artist - Staged Album (2020)");
  stage = join(release, ".intake-gc-itk_0000abcd");
  const src = join(corpus.income, "todo", "VA_-_Example_Compilation_(Web_Version_2CD)", "cd1");
  mkdirSync(join(stage, "cd1"), { recursive: true });
  for (const n of readdirSync(src).filter((x) => x.endsWith(".mp3"))) copyFileSync(join(src, n), join(stage, "cd1", n));
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

/** Every sidecar file under `dir`. */
function sidecars(dir: string): string[] {
  const out: string[] = [];
  for (const n of readdirSync(dir, { recursive: true }) as string[]) {
    const base = n.split("/").pop()!;
    if (base === ".intake.json" || /^\.intake\..+\.json$/.test(base)) out.push(n);
  }
  return out;
}

test("walkDirs skips a gc stage dir, and a walk rooted inside one yields nothing", () => {
  const paths = walkDirs(release).map((e) => e.path);
  expect(paths).toEqual([release]);
  expect(walkDirs(stage)).toEqual([]);
  expect(walkDirs(join(stage, "cd1"))).toEqual([]);
});

test("resolve makes no root of the staged audio", async () => {
  const result = await cmdResolve([release], OPTS);
  expect(result.errors).toEqual([]);
  expect(JSON.stringify(result.data)).not.toContain(".intake-gc-");
  expect(sidecars(release)).toEqual([]);
  expect(existsSync(join(stage, "cd1"))).toBe(true); // the staged files are left for gc
});
