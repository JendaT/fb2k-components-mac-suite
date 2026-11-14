// Negative cases for the cluster.album rule: a tag album ending in a scene
// source token keeps it unless the dir-name parse gives the album without it.
// Positive case: the golden fixture todo/Artist_Name-Album-(CAT123)-WEB-2011-ExampleGroup.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { copyFileSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { readSidecar } from "../src/sidecar.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = { json: true, dryRun: false, force: false, filters: {} };
const SOURCE = "Artist_Name-Album-(CAT123)-WEB-2011-ExampleGroup";

let corpus: Corpus;
const dirs: Record<string, string> = {};

beforeAll(async () => {
  corpus = setupCorpus();
  const from = join(corpus.income, "todo", SOURCE);
  // Same files (tag album "Album WEB"), dir names that do not confirm "Album".
  for (const name of ["Artist_Name-Other_Album-WEB-2011-ExampleGroup", "unparseable_dir"]) {
    const to = join(corpus.dir, "neg", name);
    mkdirSync(to, { recursive: true });
    for (const n of readdirSync(from)) copyFileSync(join(from, n), join(to, n));
    dirs[name] = to;
    expect((await cmdResolve([to], OPTS)).errors).toEqual([]);
  }
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("dir parse with a different album: tag album kept", () => {
  const sc = readSidecar(join(dirs["Artist_Name-Other_Album-WEB-2011-ExampleGroup"]!, ".intake.json"))!;
  expect(sc.cluster.album).toBe("Album WEB");
});

test("no dir parse: tag album kept", () => {
  const sc = readSidecar(join(dirs["unparseable_dir"]!, ".intake.json"))!;
  expect(sc.cluster.album).toBe("Album WEB");
});
