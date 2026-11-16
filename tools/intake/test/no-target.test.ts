// No target path, no structure slot. A root whose cluster has neither
// albumartist nor album (and no identification) gets `target_path: null`
// from assign; its proposal used to say `structure_slot: "artist"` all the
// same. The slot is now null whenever the target is, in the sidecar and in
// the assign row, and human mode says why on stderr (never in the JSON).
// Synthetic names only; the library is a temp dir.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { cmdAssign } from "../src/commands-p2.ts";
import type { Providers } from "../src/providers.ts";
import { readSidecar, serializeSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, useTempLibrary, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, collection: null, by: null,
};
const OFFLINE: { providers: Providers } = { providers: { discogs: null, similar: null, shim: null } };
const AMB = "[Ambient]";

let corpus: Corpus;
let root: string;
const doc = (): Sidecar => readSidecar(join(root, ".intake.json"))!;

beforeAll(async () => {
  corpus = setupCorpus();
  useTempLibrary(corpus);
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  root = join(corpus.income, "todo", "Asura [2003] Lost Eden (Ultimae Records; inre010)");
  expect((await cmdResolve([root], OPTS)).errors).toEqual([]);
  // A nameless release: no albumartist, no album, nothing identified.
  const sc = doc();
  sc.cluster.albumartist = null;
  sc.cluster.album = null;
  sc.identification = null;
  writeFileSync(join(root, ".intake.json"), serializeSidecar(sc));
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("a nameless root assigned with --collection has neither target_path nor structure_slot", async () => {
  expect(doc().quality.tier_eligible).toBe("hq"); // a configured tier: only the names are missing
  const result = await cmdAssign([root], { ...OPTS, collection: AMB, by: "user" }, OFFLINE);
  expect(result.errors).toEqual([]);
  expect(result.data).toMatchObject([{ target_collection: AMB, assigned_by: "user", target_path: null, structure_slot: null }]);
  expect(doc().proposal).toMatchObject({ target_collection: AMB, target_path: null, structure_slot: null });
  expect(result.notices).toEqual([`no target path for ${root}: the release has no artist or album name`]);
});
