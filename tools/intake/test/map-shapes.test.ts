// genre-map.yaml and label-map.yaml are rewritten whole by every save (assign
// --by user feedback, learned aliases, execute's placement count, bootstrap).
// The loader used to drop malformed data silently (a non-mapping entry, a
// non-number or non-positive count, a non-string alias or exceptions item, a
// section of the wrong type), and the next save then lost it, together with
// every top-level key the CLI does not know. Now a malformed entry is
// E_BAD_RULES naming the file and the key, and the command changes nothing;
// a save keeps the unknown top-level keys and the inert entries (zero counts,
// empty distributions) in place; bootstrap output and a saved map load again,
// also with names YAML could read as another type (1999, true, null, ~).

import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ENGINE_VERSION } from "../src/assign.ts";
import { cmdScan } from "../src/commands.ts";
import { cmdAssign, cmdBootstrap, cmdCollections } from "../src/commands-p2.ts";
import { cmdExecute, cmdPropose } from "../src/commands-p3.ts";
import { RulesError } from "../src/config.ts";
import { loadGenreMap, loadLabelMap, recordFeedback, recordPlacement, saveGenreMap, saveLabelMap } from "../src/rules.ts";
import { readSidecar, serializeSidecar } from "../src/sidecar.ts";
import type { Proposal } from "../src/types.ts";
import { FIXTURES, makeTierRoots, setupCorpus, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const PCP = "[Psychill & Chillout & Psydub]";
const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, collection: null, by: null,
  allResolved: false, batch: null, approved: false, resume: false,
};

let corpus: Corpus;
let library: string;
let journal: string;
const genreFile = () => join(corpus.rules, "genre-map.yaml");
const labelFile = () => join(corpus.rules, "label-map.yaml");
const read = (p: string) => readFileSync(p, "utf8");
const FIXTURE_GENRE = read(join(FIXTURES, "rules", "genre-map.yaml"));
const FIXTURE_LABEL = read(join(FIXTURES, "rules", "label-map.yaml"));

const POLLEN = () => join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
const MOVEMENTS = () => join(corpus.income, "slsk", "Solar Fields", "Solar Fields - Movements (2009)");
const LOST_EDEN = () => join(corpus.income, "todo", "Asura [2003] Lost Eden (Ultimae Records; inre010)");
const OTT = () => join(corpus.income, "todo", "Ott - Blumenkraft (2003)");
const BLUETECH = () => join(corpus.income, "todo", "Bluetech [2011] Cosmic Dubwise");
const sidecarOf = (dir: string) => join(dir, ".intake.json");

/** The fixture genre map with Aes Dana's count written as a string. */
const BAD_GENRE = FIXTURE_GENRE.replace(`"${PCP}": 6`, `"${PCP}": "6"`);
/** The fixture label map with Iboga Records' distribution written as a bare number. */
const BAD_LABEL = FIXTURE_LABEL.replace(`Iboga Records:\n    "[Psytrance]": 9`, "Iboga Records: 9");

beforeAll(async () => {
  corpus = setupCorpus();
  library = join(corpus.dir, "library");
  journal = join(corpus.dir, "journal", "intake-journal.ndjson");
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  process.env.INTAKE_BEETS_SHIM = `bun ${join(import.meta.dir, "fakes", "fake-shim.ts")}`;
  delete process.env.FAKE_SHIM_MODE; // shim behaves as unavailable
  writeFileSync(join(corpus.rules, "structure.yaml"), [
    "tiers:",
    `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
    `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
    "journal:",
    `  path: ${journal}`,
    "",
  ].join("\n"));
  makeTierRoots(corpus.rules);
  await cmdScan([], { ...OPTS, all: true });
  expect(BAD_GENRE).not.toBe(FIXTURE_GENRE);
  expect(BAD_LABEL).not.toBe(FIXTURE_LABEL);
});

afterEach(() => {
  writeFileSync(genreFile(), FIXTURE_GENRE);
  writeFileSync(labelFile(), FIXTURE_LABEL);
});

afterAll(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  rmSync(corpus.dir, { recursive: true, force: true });
});

/** Make `dir` an approved root bound for `collection`, with a fresh target in the temp library. */
function approve(dir: string, collection: string, folder: string): string {
  const s = readSidecar(sidecarOf(dir))!;
  const target = `${library}/music.hq/${collection}/${folder}`;
  const proposal: Proposal = {
    engine_version: ENGINE_VERSION,
    ranked: [{ collection, score: 1, evidence: { artist_prior: 1, label_prior: 0, similar_vote: 0, style_hint: 0 } }],
    target_collection: collection,
    confidence: 1,
    margin: 1,
    target_path: target,
    structure_slot: "artist",
    assigned_by: "user",
    alternates_shown: false,
  };
  s.proposal = proposal;
  s.status = "approved";
  writeFileSync(sidecarOf(dir), serializeSidecar(s));
  return target;
}

/** The RulesError `fn` throws (sync or async). */
async function rulesErrorOf(fn: () => unknown): Promise<RulesError> {
  let thrown: unknown = null;
  try {
    await fn();
  } catch (e) {
    thrown = e;
  }
  expect(thrown).toBeInstanceOf(RulesError);
  return thrown as RulesError;
}

// ---- refused: the command changes nothing --------------------------------------

test("a malformed genre-map entry: assign --by user through the CLI is E_BAD_RULES and writes nothing", () => {
  writeFileSync(genreFile(), BAD_GENRE);
  const sidecarBefore = read(sidecarOf(MOVEMENTS()));
  const proc = Bun.spawnSync(
    [process.execPath, "run", CLI, "assign", MOVEMENTS(), "--collection", "[Ambient]", "--by", "user", "--json"],
    { env: { ...process.env, INTAKE_RULES_DIR: corpus.rules }, timeout: 30_000 },
  );
  expect(proc.exitCode).toBe(2);
  expect(JSON.parse(proc.stdout.toString())).toEqual({
    ok: false,
    data: null,
    errors: [{
      code: "E_BAD_RULES",
      msg: `${genreFile()}: artists."Aes Dana"."${PCP}": count must be a number of 0 or more, got "6"`,
      path: genreFile(),
    }],
  });
  expect(read(genreFile())).toBe(BAD_GENRE);
  expect(read(sidecarOf(MOVEMENTS()))).toBe(sidecarBefore);
  expect(existsSync(join(corpus.rules, "overrides.log.yaml"))).toBe(false);
});

test("a malformed label-map entry: assign and propose refuse before any sidecar or map is written", async () => {
  writeFileSync(labelFile(), BAD_LABEL);
  const before = [MOVEMENTS(), LOST_EDEN()].map((dir) => read(sidecarOf(dir)));
  // Neither is identified yet: propose would identify a root before its assign read the maps.
  for (const dir of [MOVEMENTS(), LOST_EDEN()]) expect(readSidecar(sidecarOf(dir))!.identification).toBeNull();
  for (const run of [
    () => cmdAssign([LOST_EDEN()], OPTS),
    () => cmdPropose([MOVEMENTS(), LOST_EDEN()], OPTS),
  ]) {
    const err = await rulesErrorOf(run);
    expect(err.file).toBe(labelFile());
    expect(err.message).toBe(`${labelFile()}: labels."Iboga Records": must be a mapping of collection to count, got 9`);
  }
  expect(read(labelFile())).toBe(BAD_LABEL);
  expect(read(genreFile())).toBe(FIXTURE_GENRE);
  expect([MOVEMENTS(), LOST_EDEN()].map((dir) => read(sidecarOf(dir)))).toEqual(before);
});

test("a malformed genre-map entry: collections and execute refuse, nothing is placed", async () => {
  writeFileSync(genreFile(), BAD_GENRE);
  expect((await rulesErrorOf(() => cmdCollections())).file).toBe(genreFile());

  const target = approve(BLUETECH(), "[Downtempo & Electronica]", "Bluetech/Bluetech [2011] Cosmic Dubwise");
  expect((await rulesErrorOf(() => cmdExecute([BLUETECH()], OPTS))).file).toBe(genreFile());
  expect(existsSync(target)).toBe(false);
  expect(existsSync(journal)).toBe(false);
  expect(readSidecar(sidecarOf(BLUETECH()))!.status).toBe("approved");
  expect(read(genreFile())).toBe(BAD_GENRE);
});

test("each malformed shape is refused with the file and the key path", async () => {
  const cases: [file: "genre-map.yaml" | "label-map.yaml", text: string, key: string | null, detail: string][] = [
    ["genre-map.yaml", "- Aes Dana\n", null, "must be a mapping of sections, got a list"],
    ["genre-map.yaml", "artists:\n  - Aes Dana\n", "artists", "must be a mapping of name to collection counts, got a list"],
    ["genre-map.yaml", "artists:\nfeedback: {}\n", "artists", "must be a mapping of name to collection counts, got null"],
    ["genre-map.yaml", "artists: {}\nfeedback: 3\n", "feedback", "must be a mapping of name to collection counts, got 3"],
    ["genre-map.yaml", "artists:\n  Aes Dana: 6\n", 'artists."Aes Dana"', "must be a mapping of collection to count, got 6"],
    ["genre-map.yaml", "artists:\n  Aes Dana:\n", 'artists."Aes Dana"', "must be a mapping of collection to count, got null"],
    ["genre-map.yaml", "artists:\n  Aes Dana: [\"[Ambient]\"]\n", 'artists."Aes Dana"', "must be a mapping of collection to count, got a list"],
    ["genre-map.yaml", 'artists:\n  Aes Dana:\n    "[Ambient]": "6"\n', 'artists."Aes Dana"."[Ambient]"', 'count must be a number of 0 or more, got "6"'],
    ["genre-map.yaml", 'artists:\n  Aes Dana:\n    "[Ambient]": -1\n', 'artists."Aes Dana"."[Ambient]"', "count must be a number of 0 or more, got -1"],
    ["genre-map.yaml", 'artists:\n  Aes Dana:\n    "[Ambient]": .inf\n', 'artists."Aes Dana"."[Ambient]"', "count must be a number of 0 or more, got Infinity"],
    ["genre-map.yaml", 'artists:\n  Aes Dana:\n    "[Ambient]": .nan\n', 'artists."Aes Dana"."[Ambient]"', "count must be a number of 0 or more, got NaN"],
    ["genre-map.yaml", 'artists:\n  Aes Dana:\n    "[Ambient]": true\n', 'artists."Aes Dana"."[Ambient]"', "count must be a number of 0 or more, got true"],
    ["genre-map.yaml", 'feedback:\n  Aes Dana:\n    "[Ambient]":\n', 'feedback."Aes Dana"."[Ambient]"', "count must be a number of 0 or more, got null"],
    ["genre-map.yaml", "aliases:\n  - CBL\n", "aliases", "must be a mapping of alias to artist name, got a list"],
    ["genre-map.yaml", "aliases:\n  CBL: 3\n", 'aliases."CBL"', "must be an artist name, got 3"],
    ["genre-map.yaml", "aliases:\n  CBL:\n", 'aliases."CBL"', "must be an artist name, got null"],
    ["genre-map.yaml", "exceptions:\n  Nadja: Vampillia\n", "exceptions", "must be a list of artist names, got a mapping"],
    ["genre-map.yaml", "exceptions:\n  - Nadja & Vampillia\n  - 1999\n", "exceptions[1]", "must be an artist name, got 1999"],
    ["label-map.yaml", "- Iboga Records\n", null, "must be a mapping of sections, got a list"],
    ["label-map.yaml", "labels: []\n", "labels", "must be a mapping of name to collection counts, got a list"],
    ["label-map.yaml", "labels:\n  Iboga Records: 9\n", 'labels."Iboga Records"', "must be a mapping of collection to count, got 9"],
    ["label-map.yaml", 'labels:\n  Iboga Records:\n    "[Psytrance]": 9x\n', 'labels."Iboga Records"."[Psytrance]"', 'count must be a number of 0 or more, got "9x"'],
  ];
  for (const [file, text, key, detail] of cases) {
    const path = join(corpus.rules, file);
    writeFileSync(path, text);
    const err = await rulesErrorOf(() => (file === "genre-map.yaml" ? loadGenreMap : loadLabelMap)(corpus.rules));
    expect({ text, file: err.file, key: err.key, message: err.message })
      .toEqual({ text, file: path, key, message: `${path}: ${key === null ? "" : `${key}: `}${detail}` });
  }
});

// ---- accepted ------------------------------------------------------------------

test("zero counts, empty distributions and YAML-typed keys load; the inert entries carry no evidence", () => {
  writeFileSync(genreFile(), [
    "artists:",
    "  Aes Dana:",
    `    "${PCP}": 6`,
    '    "[Ambient]": 0',
    "  Zero Only:",
    '    "[Ambient]": 0',
    "  Empty: {}",
    "  1999:",
    '    "[Ambient]": 0.33',
    "  true:",
    '    "[Ambient]": 2',
    "  null:",
    '    "[Ambient]": 1e-7',
    "feedback: {}",
    "",
  ].join("\n"));
  expect(loadGenreMap(corpus.rules)).toEqual({
    artists: {
      "Aes Dana": { [PCP]: 6 },
      "1999": { "[Ambient]": 0.33 },
      "true": { "[Ambient]": 2 },
      "null": { "[Ambient]": 1e-7 },
    },
    feedback: {},
    aliases: {},
    exceptions: [],
  });
  for (const text of ["", "# nothing yet\n"]) {
    writeFileSync(labelFile(), text);
    expect(loadLabelMap(corpus.rules)).toEqual({ labels: {} });
  }
  rmSync(labelFile());
  expect(loadLabelMap(corpus.rules)).toEqual({ labels: {} });
});

// ---- saves keep what the CLI does not know ----------------------------------------

/** The fixture genre map with an unknown key between sections, one at the end, and inert entries. */
const GENRE_WITH_EXTRAS = FIXTURE_GENRE
  .replace("feedback: {}\n", "notes: keep me\nfeedback: {}\n")
  .replace("artists:\n", 'artists:\n  Zero Only:\n    "[Ambient]": 0\n  Empty: {}\n')
  .replace(`"${PCP}": 6\n`, `"${PCP}": 6\n    "[Ambient]": 0\n`)
  + "extra:\n  list: [1, two]\n  nested: { a: null }\n";

function expectExtrasKept(doc: Record<string, unknown>): void {
  expect(Object.keys(doc)).toEqual(["artists", "notes", "feedback", "aliases", "exceptions", "extra"]);
  expect(doc.notes).toBe("keep me");
  expect(doc.extra).toEqual({ list: [1, "two"], nested: { a: null } });
  const artists = doc.artists as Record<string, Record<string, number>>;
  expect(Object.keys(artists).slice(0, 3)).toEqual(["Zero Only", "Empty", "Aes Dana"]);
  expect(artists["Zero Only"]).toEqual({ "[Ambient]": 0 });
  expect(artists["Empty"]).toEqual({});
  expect(artists["Aes Dana"]).toEqual({ [PCP]: 6, "[Ambient]": 0 });
}

test("an assign --by user feedback save keeps unknown top-level keys and inert entries in place", async () => {
  writeFileSync(genreFile(), GENRE_WITH_EXTRAS);
  const result = await cmdAssign([POLLEN()], { ...OPTS, collection: "[Ambient]", by: "user" });
  expect(result.errors).toEqual([]);
  const doc = Bun.YAML.parse(read(genreFile())) as Record<string, unknown>;
  expectExtrasKept(doc);
  expect((doc.feedback as Record<string, unknown>)["Aes Dana"]).toEqual({ "[Ambient]": 1 });
  expect(loadGenreMap(corpus.rules).feedback["Aes Dana"]).toEqual({ "[Ambient]": 1 });
});

test("an execute placement-count save keeps unknown top-level keys and inert entries in place", async () => {
  writeFileSync(genreFile(), GENRE_WITH_EXTRAS);
  approve(OTT(), PCP, "Ott/Ott [2003] Blumenkraft");
  const result = await cmdExecute([OTT()], OPTS);
  expect(result.errors).toEqual([]);
  expect(readSidecar(sidecarOf(OTT()))!.status).toBe("placed");
  const doc = Bun.YAML.parse(read(genreFile())) as Record<string, unknown>;
  expectExtrasKept(doc);
  expect((doc.artists as Record<string, unknown>)["Ott"]).toEqual({ [PCP]: 4 });
});

// ---- round trip ----------------------------------------------------------------

/** Artist names the YAML serializer must quote: read back unquoted they would be numbers, booleans or null. */
const TYPED_NAMES = ["1999", "true", "yes", "null", "~", "1e3", "0x1F", "- dash", "Sigur Rós"];
const TYPED_LABELS = ["true", "null", "~", "1e3", "0x1F"];

test("bootstrap output loads, weighted and with names YAML could read as other types", () => {
  const curated = join(corpus.dir, "bootstrap-curated");
  const legacy = join(corpus.dir, "bootstrap-legacy");
  const faint = join(corpus.dir, "bootstrap-faint");
  TYPED_NAMES.forEach((name, i) => {
    const label = TYPED_LABELS[i % TYPED_LABELS.length]!;
    mkdirSync(join(curated, "[Ambient]", name, `${name} [2001] First (${label}; CAT1)`), { recursive: true });
    mkdirSync(join(legacy, "[Ambient]", name, `${name} [1999] Old (${label}; CAT0)`), { recursive: true });
  });
  // round2(0.004) is 0: a faint tree writes zero counts, which load as inert.
  mkdirSync(join(faint, "[Ambient]", "Faint Only", "Faint Only [2001] Ghost"), { recursive: true });
  const out = join(corpus.dir, "bootstrap-out");
  const result = cmdBootstrap({
    ...OPTS,
    trees: [{ path: curated, weight: 1 }, { path: legacy, weight: 0.3 }, { path: faint, weight: 0.004 }],
    out,
  });
  expect(result.errors).toEqual([]);
  expect(read(join(out, "genre-map.yaml"))).toContain("Faint Only:");

  const genre = loadGenreMap(out);
  expect(Object.keys(genre.artists).sort()).toEqual([...TYPED_NAMES].sort());
  for (const name of TYPED_NAMES) expect(genre.artists[name]).toEqual({ "[Ambient]": 1.3 });
  const labels = loadLabelMap(out);
  expect(Object.keys(labels.labels).sort()).toEqual([...TYPED_LABELS].sort());

  // A save of the loaded maps (as feedback, aliases and placements do) loads to the same maps.
  recordFeedback(genre, "1999", "[Ambient]");
  recordPlacement(genre, "true", "[Downtempo & Electronica]");
  recordPlacement(genre, "Faint Only", "[Ambient]");
  genre.aliases["yes alias"] = "yes";
  genre.aliases["null"] = "~";
  genre.exceptions.push("1e3 & 0x1F");
  saveGenreMap(out, genre);
  saveLabelMap(out, labels);
  expect(loadGenreMap(out)).toEqual(genre);
  expect(loadLabelMap(out)).toEqual(labels);
  expect(genre.artists["Faint Only"]).toEqual({ "[Ambient]": 1 });
  expect((Bun.YAML.parse(read(join(out, "genre-map.yaml"))) as { artists: Record<string, unknown> }).artists["Faint Only"])
    .toEqual({ "[Ambient]": 1 });
});

test("the fixture maps survive a load and save unchanged in content", () => {
  saveGenreMap(corpus.rules, loadGenreMap(corpus.rules));
  saveLabelMap(corpus.rules, loadLabelMap(corpus.rules));
  expect(Bun.YAML.parse(read(genreFile()))).toEqual(Bun.YAML.parse(FIXTURE_GENRE));
  expect(Bun.YAML.parse(read(labelFile()))).toEqual(Bun.YAML.parse(FIXTURE_LABEL));
});

test("bootstrap refuses a weight that would write counts the loader refuses", () => {
  const tree = join(corpus.dir, "bootstrap-weights");
  mkdirSync(join(tree, "[Ambient]", "Cell", "Cell [2009] Hanging Masses"), { recursive: true });
  for (const weight of [-1, 0, Number.POSITIVE_INFINITY]) {
    const out = join(corpus.dir, `bootstrap-weight-out-${weight}`);
    const result = cmdBootstrap({ ...OPTS, trees: [{ path: tree, weight }], out });
    expect(result.errors).toEqual([
      { code: "E_BAD_ARGS", msg: `--prior-weight must be a number above 0, got ${weight}`, path: tree },
    ]);
    expect(result.exitCode).toBe(2);
    expect(existsSync(out)).toBe(false);
  }
});

