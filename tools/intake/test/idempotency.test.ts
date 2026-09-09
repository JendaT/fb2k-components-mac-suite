// Property: resolver is idempotent — a second run without --force is a no-op
// (no new sidecars, existing sidecar bytes untouched, no file mutations).

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve, cmdScan } from "../src/commands.ts";
import { collectSidecars, setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const OPTS = { json: true, dryRun: false, force: false, all: true, filters: {} };

let corpus: Corpus;

beforeAll(async () => {
  corpus = setupCorpus();
  await cmdScan([], OPTS);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("second scan without --force writes nothing", async () => {
  const bytesBefore = new Map(
    collectSidecars(corpus.income).map(([rel]) => [rel, readFileSync(join(corpus.income, rel), "utf8")]),
  );
  const hashBefore = treeHash(corpus.income);

  const second = await cmdScan([], OPTS);
  expect(second.exitCode).toBe(0);
  const written = (second.data as { written: unknown[] }[]).flatMap((b) => b.written);
  expect(written).toEqual([]);

  const after = collectSidecars(corpus.income);
  expect(after.map(([rel]) => rel)).toEqual([...bytesBefore.keys()]);
  for (const [rel] of after) {
    expect(readFileSync(join(corpus.income, rel), "utf8")).toBe(bytesBefore.get(rel)!);
  }
  expect(treeHash(corpus.income)).toBe(hashBefore);
});

test("re-resolve with --force preserves sidecar id and appends history", async () => {
  const target = join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  const before = JSON.parse(readFileSync(join(target, ".intake.json"), "utf8"));

  const result = await cmdResolve([target], { ...OPTS, force: true });
  expect(result.exitCode).toBe(0);

  const after = JSON.parse(readFileSync(join(target, ".intake.json"), "utf8"));
  expect(after.id).toBe(before.id);
  expect(after.history.length).toBe(before.history.length + 1);
  expect(after.history.at(-1).event).toBe("re-resolved");
});

test("pre-existing foreign sidecar is trusted without --force", async () => {
  const target = join(corpus.income, "downloads", "Sync24 [2024] Omnimotion Remixed");
  const path = join(target, ".intake.json");
  const original = readFileSync(path, "utf8");

  const result = await cmdResolve([target], OPTS);
  expect(result.exitCode).toBe(0);
  expect((result.data as { written: unknown[] }).written).toEqual([]);
  expect((result.data as { kept: string[] }).kept).toEqual([target]);
  expect(readFileSync(path, "utf8")).toBe(original);
});
