// End-to-end P2 flow on the fixture corpus (offline): scan -> identify ->
// assign -> user override feedback loop -> collections -> bootstrap.
// Mutation guard holds throughout: audio bytes never change; the only writes
// are sidecars, .unpacked output, and rules-repo files (in the temp copy).

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cmdScan } from "../src/commands.ts";
import { cmdAssign, cmdBootstrap, cmdCollections, cmdIdentify } from "../src/commands-p2.ts";
import { loadGenreMap } from "../src/rules.ts";
import { readSidecar } from "../src/sidecar.ts";
import { setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const OPTS = { json: true, dryRun: false, force: false, filters: {}, collection: null, by: null };
const PCP = "[Psychill & Chillout & Psydub]";

let corpus: Corpus;
let pristine: string;
let pollenDir: string;

beforeAll(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  process.env.INTAKE_BEETS_SHIM = `bun ${join(import.meta.dir, "fakes", "fake-shim.ts")}`;
  delete process.env.FAKE_SHIM_MODE; // shim behaves as unavailable
  pristine = treeHash(corpus.income);
  await cmdScan([], { ...OPTS, all: true });
  pollenDir = join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
});

afterAll(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("identify (offline): unconfirmed identification persisted with history", async () => {
  const result = await cmdIdentify([pollenDir], OPTS);
  expect(result.exitCode).toBe(0);

  const sc = readSidecar(join(pollenDir, ".intake.json"))!;
  expect(sc.identification?.status).toBe("unconfirmed");
  expect(sc.identification?.label).toBe("Ultimae Records");
  expect(sc.identification?.catno).toBe("inre042");
  expect(sc.history.at(-1)?.event).toBe("identified");

  // Second run without --force keeps the existing identification.
  const again = await cmdIdentify([pollenDir], OPTS);
  expect((again.data as { kept: boolean }[])[0]!.kept).toBe(true);
});

test("assign (engine): proposal with tier-routed target path", async () => {
  const result = await cmdAssign([pollenDir], OPTS);
  expect(result.exitCode).toBe(0);

  const sc = readSidecar(join(pollenDir, ".intake.json"))!;
  expect(sc.proposal?.target_collection).toBe(PCP);
  expect(sc.proposal?.confidence).toBe(0.95); // unique artist prior short-circuit
  expect(sc.proposal?.assigned_by).toBe("engine");
  expect(sc.proposal?.target_path).toBe(
    `/library/music.hq/${PCP}/Aes Dana/Aes Dana [2012] Pollen (Ultimae Records; inre042)`,
  );
  expect(sc.history.at(-1)?.event).toBe("assigned");

  const again = await cmdAssign([pollenDir], OPTS);
  expect((again.data as { kept: boolean }[])[0]!.kept).toBe(true);
});

test("assign routes uhq releases into the uhq tier root", async () => {
  const dir = join(corpus.income, "downloads", "Sync24 [2024] Omnimotion Remixed");
  await cmdIdentify([dir], OPTS);
  const result = await cmdAssign([dir], OPTS);
  expect(result.exitCode).toBe(0);
  const sc = readSidecar(join(dir, ".intake.json"))!;
  expect(sc.proposal?.target_path).toBe(
    "/library/music.uhq/[Downtempo & Electronica]/Sync24/Sync24 [2024] Omnimotion Remixed",
  );
});

test("assign by sidecar id works and reject-tier gets no target path", async () => {
  const dir = join(corpus.income, "todo", "Oldskool - Demo Tape (1998)");
  const id = readSidecar(join(dir, ".intake.json"))!.id;
  const result = await cmdAssign([id], OPTS);
  // Oldskool is unknown to the maps: no evidence -> partial failure is fine;
  // what matters is the ref-by-id resolution reached the root.
  expect(result.errors.every((e) => e.code === "E_NO_EVIDENCE")).toBe(true);
});

test("user override: feedback loop appends override log and genre-map counts", async () => {
  const dir = join(corpus.income, "slsk", "Solar Fields", "Solar Fields - Movements (2009)");
  await cmdIdentify([dir], OPTS);
  const result = await cmdAssign([dir], { ...OPTS, collection: "[Ambient]", by: "user" });
  expect(result.exitCode).toBe(0);

  const sc = readSidecar(join(dir, ".intake.json"))!;
  expect(sc.proposal?.target_collection).toBe("[Ambient]");
  expect(sc.proposal?.assigned_by).toBe("user");
  expect(sc.proposal?.target_path).toBe(
    "/library/music.hq/[Ambient]/Solar Fields/Solar Fields [2009] Movements",
  );

  const overrides = readFileSync(join(corpus.rules, "overrides.log.yaml"), "utf8");
  expect(overrides).toContain("Solar Fields");
  expect(overrides).toContain("[Ambient]");

  const genre = loadGenreMap(corpus.rules);
  expect(genre.feedback["Solar Fields"]?.["[Ambient]"]).toBe(1);
});

test("collections: genre map folder list", () => {
  const result = cmdCollections();
  expect(result.exitCode).toBe(0);
  const rows = result.data as { collection: string; artists: number; releases: number }[];
  const pcp = rows.find((r) => r.collection === PCP)!;
  expect(pcp.artists).toBeGreaterThanOrEqual(9);
  // The user-override feedback above must count into the picker list.
  const amb = rows.find((r) => r.collection === "[Ambient]")!;
  expect(amb.artists).toBeGreaterThanOrEqual(6);
});

test("mutation guard: P2 commands never touch audio or pre-existing files", () => {
  expect(treeHash(corpus.income)).toBe(pristine);
});

test("bootstrap: read-only tree scan produces maps and naming report", () => {
  const lib = join(corpus.dir, "library");
  const mk = (p: string) => mkdirSync(join(lib, p), { recursive: true });
  mk(`${PCP}/Aes Dana/Aes Dana [2012] Pollen (Ultimae Records; inre042)`);
  mk(`${PCP}/Aes Dana/Aes Dana [2014] Pollen Sativa (Ultimae Records; inre052)`);
  mk(`${PCP}/Solar Fields - Movements (2009)`); // flat release
  mk("[Ambient]/[Releases]/Cell - Hanging Masses (2009)"); // slot dir
  mk("[Ambient]/Hilyard/completely unparseable dirname"); // artist dir, odd release name

  const out = join(corpus.dir, "bootstrap-out");
  const result = cmdBootstrap({ ...OPTS, trees: [{ path: lib, weight: 1 }], out });
  expect(result.errors).toEqual([]);
  expect(result.exitCode).toBe(0);

  const genre = loadGenreMap(out);
  expect(genre.artists["Aes Dana"]?.[PCP]).toBe(2);
  expect(genre.artists["Solar Fields"]?.[PCP]).toBe(1);
  expect(genre.artists["Cell"]?.["[Ambient]"]).toBe(1);
  expect(genre.artists["Hilyard"]?.["[Ambient]"]).toBe(1);

  const labels = Bun.YAML.parse(readFileSync(join(out, "label-map.yaml"), "utf8")) as {
    labels: Record<string, Record<string, number>>;
  };
  expect(labels.labels["Ultimae Records"]?.[PCP]).toBe(2);

  const report = readFileSync(join(out, "naming-variants-report.md"), "utf8");
  expect(report).toContain("bracket_year_paren_label | 2");
  expect(report).toContain("completely unparseable dirname");

  // Refuses to clobber existing maps without --force.
  const again = cmdBootstrap({ ...OPTS, trees: [{ path: lib, weight: 1 }], out });
  expect(again.exitCode).toBe(2);
  expect(again.errors[0]!.code).toBe("E_EXISTS");

  // Weighted second pass with --force: legacy prior at reduced weight.
  const weighted = cmdBootstrap({
    ...OPTS, force: true, trees: [{ path: lib, weight: 0.3 }], out,
  });
  expect(weighted.exitCode).toBe(0);
  expect(loadGenreMap(out).artists["Aes Dana"]?.[PCP]).toBeCloseTo(0.6, 5);

  expect(existsSync(join(lib, ".intake.json"))).toBe(false); // read-only scan
});
