// Execute's genre-map count update (recordPlacement) skips a Various Artists
// credit (doc 02, amendment 003): the count would build the artist prior that
// assign ignores for VA. The test crafts `approved` sidecars with a proposal
// and a target_path, the way execute-resume.test.ts crafts `placing` ones, and
// executes them into a temp library (layout-flow.test.ts takes a VA root
// through propose into [Compilations]).

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ENGINE_VERSION } from "../src/assign.ts";
import { cmdScan } from "../src/commands.ts";
import { cmdExecute } from "../src/commands-p3.ts";
import { loadGenreMap } from "../src/rules.ts";
import { readSidecar, serializeSidecar } from "../src/sidecar.ts";
import type { Identification, Proposal, Sidecar } from "../src/types.ts";
import { isVariousArtists } from "../src/util.ts";
import { makeTierRoots, setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, all: false,
  approved: false, resume: false,
};
const PSY = "[Psytrance]";
const PCP = "[Psychill & Chillout & Psydub]";

let corpus: Corpus;
let library: string;
const dirOf = (...seg: string[]) => join(corpus.income, ...seg);
const VA_COMP = () => dirOf("todo", "VA_-_Example_Compilation_(Web_Version_2CD)");
const BLUETECH = () => dirOf("todo", "Bluetech [2011] Cosmic Dubwise");
const OTT = () => dirOf("todo", "Ott - Blumenkraft (2003)");
const file = (dir: string) => join(dir, ".intake.json");
const doc = (dir: string): Sidecar => readSidecar(file(dir))!;
const genreYaml = () => readFileSync(join(corpus.rules, "genre-map.yaml"), "utf8");

/** Make `dir` an approved root bound for `collection`, with a fresh target. */
function approve(dir: string, collection: string, folder: string, identArtist?: string): void {
  const s = doc(dir);
  const proposal: Proposal = {
    engine_version: ENGINE_VERSION,
    ranked: [{ collection, score: 1, evidence: { artist_prior: 0, label_prior: 0, similar_vote: 0, style_hint: 1 } }],
    target_collection: collection,
    confidence: 1,
    margin: 1,
    target_path: `${library}/music.hq/${collection}/${folder}`,
    structure_slot: "artist",
    assigned_by: "user",
    alternates_shown: false,
  };
  if (identArtist !== undefined) {
    const ident: Identification = {
      status: "unconfirmed", source: null, release_id: null, artist: identArtist, album: s.cluster.album,
      year: null, label: null, catno: null, styles: [], genres: [], distance: null, grammar: null,
      candidates: null, identified_at: "2026-11-15T00:00:00",
    };
    s.identification = ident;
  }
  s.proposal = proposal;
  s.status = "approved";
  writeFileSync(file(dir), serializeSidecar(s));
}

beforeAll(async () => {
  corpus = setupCorpus();
  library = join(corpus.dir, "library");
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${join(corpus.dir, "journal", "intake-journal.ndjson")}`,
      "",
    ].join("\n"),
  );
  makeTierRoots(corpus.rules);
  await cmdScan([], { ...OPTS, all: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("a Various Artists placement leaves genre-map.yaml untouched", async () => {
  // Credit from the resolver's cluster (the VA release rule) ...
  expect(doc(VA_COMP()).cluster.albumartist).toBe("Various Artists");
  expect(doc(VA_COMP()).identification).toBeNull();
  approve(VA_COMP(), PSY, "[Compilations]/VA - Example Compilation");
  // ... and from identification, in another spelling.
  approve(BLUETECH(), PSY, "[Compilations]/V.A. - Cosmic Dubwise", "V.A.");
  const before = genreYaml();

  const result = await cmdExecute([VA_COMP(), BLUETECH()], OPTS);
  expect(result.errors).toEqual([]);
  expect(result.data!.map((r) => r.root_path)).toEqual([VA_COMP(), BLUETECH()]);
  for (const dir of [VA_COMP(), BLUETECH()]) expect(doc(dir).status).toBe("placed");

  expect(genreYaml()).toBe(before);
  expect(Object.keys(loadGenreMap(corpus.rules).artists).filter((k) => isVariousArtists(k))).toEqual([]);
});

test("a non-VA placement still increments the artist's count", async () => {
  const count = () => loadGenreMap(corpus.rules).artists["Ott"]?.[PCP] ?? 0;
  const before = count();
  expect(before).toBeGreaterThan(0);
  approve(OTT(), PCP, "Ott/Ott [2003] Blumenkraft");
  const result = await cmdExecute([OTT()], OPTS);
  expect(result.errors).toEqual([]);
  expect(doc(OTT()).status).toBe("placed");
  expect(count()).toBe(before + 1);
  expect(Object.keys(loadGenreMap(corpus.rules).artists).filter((k) => isVariousArtists(k))).toEqual([]);
});
