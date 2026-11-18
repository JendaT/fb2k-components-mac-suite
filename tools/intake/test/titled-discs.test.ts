// Resolver pass 2: disc dirs carrying a disc title after the index
// (`CD1 - Disc Title`, `CD2 Disc Title`) merge into one root like bare `CDn`.
// Before the shared disc-dir detector accepted titles, each became its own root.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { collectSidecars, setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = { json: true, dryRun: false, force: false, filters: {} };
const DISC_DIRS = ["CD1 - Disc Title", "CD2 Disc Title"];

let corpus: Corpus;
let release: string;

beforeAll(async () => {
  corpus = setupCorpus();
  // Audio from the corpus's multi-disc fixture (the todo dir with CD1 + CD2):
  // one tag cluster, disc tags 1 and 2.
  const todo = join(corpus.income, "todo");
  // Sorted: on a case-insensitive volume the VA fixture's cd1/cd2 match too.
  const src = readdirSync(todo).sort().find((n) => existsSync(join(todo, n, "CD1")) && existsSync(join(todo, n, "CD2")));
  expect(src).toBeDefined();
  release = join(corpus.dir, "titled", "Artist Name [2011] Album Name");
  DISC_DIRS.forEach((discDir, i) => {
    const from = join(todo, src!, `CD${i + 1}`);
    mkdirSync(join(release, discDir), { recursive: true });
    for (const n of readdirSync(from).filter((f) => f.endsWith(".flac"))) {
      copyFileSync(join(from, n), join(release, discDir, n));
    }
  });
  const result = await cmdResolve([release], OPTS);
  expect(result.errors).toEqual([]);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("titled disc dirs merge into one root at the release dir", () => {
  const sidecars = collectSidecars(release);
  expect(sidecars.map(([rel]) => rel)).toEqual([".intake.json"]);
  const doc = sidecars[0]![1] as {
    discs: { dir: string; disc: number }[];
    files: { path: string }[];
    virtual: boolean;
  };
  expect(doc.virtual).toBe(false);
  expect(doc.discs).toEqual([
    { dir: "CD1 - Disc Title", disc: 1 },
    { dir: "CD2 Disc Title", disc: 2 },
  ]);
  expect(doc.files.length).toBe(6);
  for (const f of doc.files) expect(DISC_DIRS.some((d) => f.path.startsWith(`${d}/`))).toBe(true);
});
