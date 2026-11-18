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

test("FLAC with unset STREAMINFO MD5: decoded-audio flacmd5 + flac_md5_unset issue", () => {
  const key = "todo/Bluetech [2011] Cosmic Dubwise/.intake.json";
  const doc = new Map(collectSidecars(corpus.income)).get(key);
  expect(doc).toBeDefined();
  const files = doc!.files as { path: string; audio_hash: string }[];
  const hashOf = (p: string) => files.find((f) => f.path.startsWith(p))!.audio_hash;

  // Unset signature -> MD5 of the decoded audio, the value a correct
  // STREAMINFO holds (doc 03, CR-003); resolve never repairs the file.
  expect(hashOf("01")).toStartWith("flacmd5:");
  expect(hashOf("02")).toStartWith("flacmd5:");
  // Same release, signature intact -> read from STREAMINFO.
  expect(hashOf("03")).toStartWith("flacmd5:");
  expect(new Set(files.map((f) => f.audio_hash)).size).toBe(3);

  // The issue is recorded once for the root, not once per affected file.
  expect((doc!.quality as { issues: string[] }).issues).toEqual(["flac_md5_unset"]);
  // A missing signature is a metadata defect, not a quality downgrade; a
  // decodable file does not need review.
  expect((doc!.quality as { tier_eligible: string }).tier_eligible).toBe("hq");
  expect((doc!.cluster as { needs_review: boolean }).needs_review).toBe(false);
  expect(doc!.status).toBe("resolved");
});

test("scene rip with \"Album WEB\" tags: cluster.album drops the source token the dir name lacks", () => {
  const key = "todo/Artist_Name-Album-(CAT123)-WEB-2011-ExampleGroup/.intake.json";
  const doc = new Map(collectSidecars(corpus.income)).get(key);
  expect(doc).toBeDefined();
  const cluster = doc!.cluster as { albumartist: string; album: string };
  expect(cluster.albumartist).toBe("Artist Name"); // no album_artist tag: the one track artist
  expect(cluster.album).toBe("Album");
  // Per-file tags are recorded as read.
  for (const f of doc!.files as { tags: { album: string } }[]) expect(f.tags.album).toBe("Album WEB");
});

test("2-disc VA web compilation (per-track album artists, disc in track number) is one root", () => {
  const va = "todo/VA_-_Example_Compilation_(Web_Version_2CD)";
  const produced = collectSidecars(corpus.income);
  // One sidecar for the whole release: no per-artist virtual roots or singles.
  expect(produced.map(([rel]) => rel).filter((rel) => rel.startsWith(`${va}/`))).toEqual([`${va}/.intake.json`]);
  const doc = new Map(produced).get(`${va}/.intake.json`)!;
  expect(doc.virtual).toBe(false);
  expect(doc.singles).toBeUndefined();
  expect(doc.discs).toEqual([{ dir: "cd1", disc: 1 }, { dir: "cd2", disc: 2 }]);
  const cluster = doc.cluster as { albumartist: string; signals: { purity: number; seq: number } };
  expect(cluster.albumartist).toBe("Various Artists");
  expect(cluster.signals.purity).toBe(1);
  expect(cluster.signals.seq).toBe(1); // 101..104, 201..205 decoded as discs 1-2, tracks 1..n
  // Per-file tags keep the files' own values: track numbers as read, each
  // track's own album artist (disc filled from the disc dir, as for any disc dir).
  const files = doc.files as { path: string; tags: { albumartist: string; tracknumber: number; disc: number } }[];
  expect(files.length).toBe(9);
  expect(files.map((f) => f.tags.tracknumber)).toEqual([101, 102, 103, 104, 201, 202, 203, 204, 205]);
  expect(files.map((f) => f.tags.disc)).toEqual([1, 1, 1, 1, 2, 2, 2, 2, 2]);
  expect(new Set(files.map((f) => f.tags.albumartist)).size).toBe(8);
});

test("junk files are never referenced by any sidecar", () => {
  for (const [, doc] of collectSidecars(corpus.income)) {
    for (const f of (doc.files as { path: string }[]) ?? []) {
      expect(f.path).not.toMatch(/(^|\/)(\.DS_Store|Thumbs\.db|@eaDir|\._)/);
    }
  }
});
