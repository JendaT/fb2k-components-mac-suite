// Mutation guard: resolve/scan never touch pre-existing files; --dry-run
// writes nothing at all.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve, cmdScan } from "../src/commands.ts";
import { collectSidecars, setupCorpus, treeHash, type Corpus } from "./helpers.ts";

let corpus: Corpus;
let pristine: string;

beforeAll(() => {
  corpus = setupCorpus();
  pristine = treeHash(corpus.income);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("--dry-run scan writes no sidecars and unpacks nothing", async () => {
  const result = await cmdScan([], { json: true, dryRun: true, force: false, all: true, filters: {} });
  expect(result.exitCode).toBe(0);
  const written = (result.data as { written: unknown[] }[]).flatMap((b) => b.written);
  expect(written.length).toBeGreaterThan(0); // it still reports what it would do
  expect(collectSidecars(corpus.income)).toEqual([]);
  expect(existsSync(join(corpus.income, "downloads", "Carbon Based Lifeforms - Derelicts (2017).unpacked"))).toBe(false);
  expect(treeHash(corpus.income)).toBe(pristine);
});

test("--dry-run resolve writes no sidecars", async () => {
  const result = await cmdResolve([join(corpus.income, "todo")], {
    json: true, dryRun: true, force: false, filters: {},
  });
  expect(result.exitCode).toBe(0);
  expect(collectSidecars(corpus.income)).toEqual([]);
  expect(treeHash(corpus.income)).toBe(pristine);
});

test("real scan only adds sidecars and .unpacked output — zero mutations", async () => {
  const result = await cmdScan([], { json: true, dryRun: false, force: false, all: true, filters: {} });
  expect(result.exitCode).toBe(0);
  // treeHash excludes exactly the two legal additions (sidecars, *.unpacked);
  // any change to a pre-existing byte would alter it.
  expect(treeHash(corpus.income)).toBe(pristine);
});

test("resolve alone never unpacks archives", async () => {
  const zipDir = join(corpus.dir, "income", "downloads");
  rmSync(join(zipDir, "Carbon Based Lifeforms - Derelicts (2017).unpacked"), { recursive: true, force: true });
  const result = await cmdResolve([zipDir], { json: true, dryRun: false, force: true, filters: {} });
  expect(result.exitCode).toBe(0);
  expect(existsSync(join(zipDir, "Carbon Based Lifeforms - Derelicts (2017).unpacked"))).toBe(false);
});
