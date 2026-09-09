// Golden test: fixture tree -> expected sidecar set, plus the P1 acceptance
// gate: >=90% of fixture roots correctly bounded, zero file mutations.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cmdScan } from "../src/commands.ts";
import { collectSidecars, normalizeSidecar, setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const EXPECTED: Record<string, Record<string, unknown>> = JSON.parse(
  readFileSync(join(import.meta.dir, "expected", "sidecars.json"), "utf8"),
);

let corpus: Corpus;
let hashBefore: string;

beforeAll(async () => {
  corpus = setupCorpus();
  hashBefore = treeHash(corpus.income);
  const result = await cmdScan([], { json: true, dryRun: false, force: false, all: true, filters: {} });
  expect(result.errors).toEqual([]);
  expect(result.exitCode).toBe(0);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("zero file mutations (tree hash unchanged)", () => {
  expect(treeHash(corpus.income)).toBe(hashBefore);
});

test("acceptance gate: >=90% of fixture roots correctly bounded", () => {
  const produced = new Map(collectSidecars(corpus.income).map(([rel, doc]) => [rel, doc]));
  const expectedKeys = Object.keys(EXPECTED);

  let correct = 0;
  const misses: string[] = [];
  for (const key of expectedKeys) {
    const doc = produced.get(key);
    const want = EXPECTED[key]!;
    const fileSet = (d: Record<string, unknown>) =>
      ((d.files as { path: string }[]) ?? []).map((f) => f.path).join("\n");
    if (doc && fileSet(doc) === fileSet(want)) correct++;
    else misses.push(key);
  }
  const extras = [...produced.keys()].filter((k) => !(k in EXPECTED));
  const accuracy = correct / expectedKeys.length;
  console.log(
    `root bounding accuracy: ${(accuracy * 100).toFixed(1)}% ` +
      `(${correct}/${expectedKeys.length} correct, ${extras.length} extra)` +
      (misses.length ? `; missed: ${misses.join(", ")}` : ""),
  );
  expect(extras).toEqual([]);
  expect(accuracy).toBeGreaterThanOrEqual(0.9);
});

test("sidecar contents match golden expectations exactly", () => {
  const produced = collectSidecars(corpus.income);
  expect(produced.map(([rel]) => rel)).toEqual(Object.keys(EXPECTED).sort());
  for (const [rel, doc] of produced) {
    expect(normalizeSidecar(doc)).toEqual(EXPECTED[rel]!);
  }
});

test("FLAC with unset STREAMINFO MD5: fsha1 fallback + flac_md5_unset issue", () => {
  const key = "todo/Bluetech [2011] Cosmic Dubwise/.intake.json";
  const doc = new Map(collectSidecars(corpus.income)).get(key);
  expect(doc).toBeDefined();
  const files = doc!.files as { path: string; audio_hash: string }[];
  const hashOf = (p: string) => files.find((f) => f.path.startsWith(p))!.audio_hash;

  // Unset signature -> whole-file SHA1 fallback; resolve never repairs the file
  // (doc 01; whether execute repairs it is CR-001.4, open).
  expect(hashOf("01")).toStartWith("fsha1:");
  expect(hashOf("02")).toStartWith("fsha1:");
  // Same release, signature intact -> normal algorithm.
  expect(hashOf("03")).toStartWith("flacmd5:");

  // The issue is recorded once for the root, not once per affected file.
  expect((doc!.quality as { issues: string[] }).issues).toEqual(["flac_md5_unset"]);
  // A missing signature is a metadata defect, not a quality downgrade.
  expect((doc!.quality as { tier_eligible: string }).tier_eligible).toBe("hq");
  expect(doc!.status).toBe("resolved");
});

test("junk files are never referenced by any sidecar", () => {
  for (const [, doc] of collectSidecars(corpus.income)) {
    for (const f of (doc.files as { path: string }[]) ?? []) {
      expect(f.path).not.toMatch(/(^|\/)(\.DS_Store|Thumbs\.db|@eaDir|\._)/);
    }
  }
});
