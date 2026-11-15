// propose reads the library layout at propose time (doc 02 "Library layout
// and credit rules (amendment 003)"), also when an earlier `assign` already
// built a proposal: the collection is kept, the target is rebuilt from the
// collection dir as it is now. Temp library and synthetic names only.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { cmdAssign, cmdIdentify, type P2Deps } from "../src/commands-p2.ts";
import { cmdPropose } from "../src/commands-p3.ts";
import type { Providers } from "../src/providers.ts";
import { readSidecar, serializeSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, collection: null, by: null,
  allResolved: false, batch: null, approved: false, resume: false,
};
const OFFLINE: P2Deps = {
  providers: { discogs: null, similar: null, shim: { identify: async () => ({ candidates: [] }) } } as Providers,
};
const DTE = "[Downtempo & Electronica]";
const PSY = "[Psytrance]";

let corpus: Corpus;
let library: string;
const hq = (...seg: string[]) => join(library, "music.hq", ...seg);
const NAME_ROOT = () => join(corpus.income, "todo", "Artist_Name-Album-(CAT123)-WEB-2011-ExampleGroup");
const VA_ROOT = () => join(corpus.income, "todo", "VA_-_Example_Compilation_(Web_Version_2CD)");
const doc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;

beforeAll(async () => {
  corpus = setupCorpus();
  library = join(corpus.dir, "library");
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "",
    ].join("\n"),
  );
  expect((await cmdResolve([join(corpus.income, "todo")], OPTS)).errors).toEqual([]);
  for (const dir of [NAME_ROOT(), VA_ROOT()]) expect(doc(dir).status).toBe("resolved");
  // Identified up front, so the release folder names (year included) are the
  // same at assign and at propose time; only the layout changes in between.
  expect((await cmdIdentify([NAME_ROOT(), VA_ROOT()], OPTS, OFFLINE)).errors).toEqual([]);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("a target built by an earlier assign is rebuilt from the library at propose time", async () => {
  // Assigned while the collection held nothing by the artist: [Releases].
  expect((await cmdAssign([NAME_ROOT()], OPTS, OFFLINE)).errors).toEqual([]);
  const assigned = doc(NAME_ROOT()).proposal!;
  expect(assigned).toMatchObject({
    target_collection: DTE,
    target_path: hq(DTE, "[Releases]", "Artist Name [2011] Album"),
    structure_slot: "releases",
  });

  // Since then an earlier release by the artist arrived in [releases].
  mkdirSync(hq(DTE, "[releases]", "Artist Name [2009] Older Album"), { recursive: true });
  const result = await cmdPropose([NAME_ROOT()], OPTS, OFFLINE);
  expect(result.errors).toEqual([]);
  const target = hq(DTE, "Artist Name", "Artist Name [2011] Album");
  const candidates = [`${DTE}/[releases]/Artist Name [2009] Older Album`];
  expect(result.data).toMatchObject([{ status: "proposed", target_path: target, restructure_candidates: candidates }]);
  expect(doc(NAME_ROOT()).proposal).toMatchObject({
    target_collection: DTE, target_path: target, structure_slot: "artist", restructure_candidates: candidates,
    assigned_by: "engine",
  });
});

test("a compilation assigned before the layout existed (null target) gets its [Compilations] target", async () => {
  expect((await cmdAssign([VA_ROOT()], { ...OPTS, collection: PSY, by: "user" }, OFFLINE)).errors).toEqual([]);
  // Rewrite the proposal to its pre-amendment-003 shape: no target.
  const file = join(VA_ROOT(), ".intake.json");
  const old = doc(VA_ROOT());
  old.proposal = { ...old.proposal!, target_path: null, structure_slot: "compilations" };
  writeFileSync(file, serializeSidecar(old));

  const result = await cmdPropose([VA_ROOT()], OPTS, OFFLINE);
  expect(result.errors).toEqual([]);
  const target = hq(
    PSY, "[Compilations]", "Various Artists [2011] Example Compilation - An Example Site compilation (2CD Web Edition)",
  );
  expect(result.data).toMatchObject([{ status: "proposed", target_path: target }]);
  expect(doc(VA_ROOT()).proposal).toMatchObject({
    target_collection: PSY, target_path: target, structure_slot: "compilations", assigned_by: "user",
  });
});
