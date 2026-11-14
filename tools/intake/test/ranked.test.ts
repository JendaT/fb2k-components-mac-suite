// `proposal.ranked` in the status summary (doc 03 v1.1, CR-002.2): the
// engine's candidates in stored order, best first, top 5, `score` reported as
// `confidence`. Present whenever the summary has a proposal object; a
// user-only proposal (no engine run) reports []; a user override on top of an
// engine proposal keeps the engine's list, so the target may be missing.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { ENGINE_VERSION } from "../src/assign.ts";
import { cmdScan } from "../src/commands.ts";
import { cmdAssign } from "../src/commands-p2.ts";
import { readSidecar, serializeSidecar, summarize } from "../src/sidecar.ts";
import type { Proposal, Sidecar } from "../src/types.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const OPTS = { json: true, dryRun: false, force: false, filters: {}, all: false, collection: null, by: null };
const PCP = "[Psychill & Chillout & Psydub]";
const POLLEN_KEY = "downloads/Aes Dana [2012] Pollen (Ultimae Records; inre042)/.intake.json";
const GOLDEN: Record<string, Sidecar> = JSON.parse(
  readFileSync(join(import.meta.dir, "expected", "sidecars.json"), "utf8"),
);

let corpus: Corpus;
const dirOf = (...seg: string[]) => join(corpus.income, ...seg);
const sc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;

/** An engine proposal over synthetic collections, scores already sorted desc. */
function engineProposal(cands: [string, number][]): Proposal {
  const ranked = cands.map(([collection, score]) => ({
    collection, score, evidence: { artist_prior: score, label_prior: 0, similar_vote: 0, style_hint: 0 },
  }));
  return {
    engine_version: ENGINE_VERSION,
    ranked,
    target_collection: ranked[0]!.collection,
    confidence: ranked[0]!.score,
    margin: ranked.length > 1 ? ranked[0]!.score - ranked[1]!.score : ranked[0]!.score,
    target_path: `/library/music.hq/${ranked[0]!.collection}/x`,
    structure_slot: "artist",
    assigned_by: "engine",
    alternates_shown: ranked.length > 1,
  };
}

function withProposal(p: Proposal | null, status: Sidecar["status"] = "proposed"): Sidecar {
  const s = structuredClone(GOLDEN[POLLEN_KEY]!);
  s.proposal = p;
  s.status = status;
  return s;
}

const SEVEN: [string, number][] = [
  ["[C1]", 0.71], ["[C2]", 0.52], ["[C3]", 0.4], ["[C4]", 0.33], ["[C5]", 0.2], ["[C6]", 0.11], ["[C7]", 0.05],
];

beforeAll(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  await cmdScan([], { ...OPTS, all: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

// ---- summarize() ----------------------------------------------------------------

test("engine proposal with more than 5 candidates: top 5, engine order, score as confidence", () => {
  const out = summarize(withProposal(engineProposal(SEVEN)), "/x");
  expect(out.proposal).toEqual({
    target_collection: "[C1]",
    confidence: 0.71,
    ranked: SEVEN.slice(0, 5).map(([collection, confidence]) => ({ collection, confidence })),
  });
});

test("engine proposal with fewer than 5 candidates: all of them, nothing padded", () => {
  const out = summarize(withProposal(engineProposal([["[C1]", 0.6], ["[C2]", 0.3]])), "/x");
  expect(out.proposal!.ranked).toEqual([
    { collection: "[C1]", confidence: 0.6 },
    { collection: "[C2]", confidence: 0.3 },
  ]);
  expect(out.proposal!.ranked[0]!.collection).toBe(out.proposal!.target_collection);
});

test("stored order is kept as-is, never re-sorted", () => {
  const p = engineProposal([["[C1]", 0.6], ["[C2]", 0.3], ["[C3]", 0.1]]);
  p.ranked.reverse(); // whatever the engine stored is the engine's order
  expect(summarize(withProposal(p), "/x").proposal!.ranked.map((r) => r.collection)).toEqual(["[C3]", "[C2]", "[C1]"]);
});

test("user override after engine: ranked unchanged, target not first", () => {
  const p = engineProposal([["[C1]", 0.6], ["[C2]", 0.3], ["[C3]", 0.1]]);
  const overridden: Proposal = { ...p, target_collection: "[C2]", confidence: 1, margin: 1, assigned_by: "user" };
  const out = summarize(withProposal(overridden), "/x").proposal!;
  expect(out.target_collection).toBe("[C2]");
  expect(out.ranked.map((r) => r.collection)).toEqual(["[C1]", "[C2]", "[C3]"]);
});

test("no proposal: proposal is null, so no ranked", () => {
  expect(summarize(withProposal(null, "resolved"), "/x").proposal).toBeNull();
});

// ---- real assign flows ------------------------------------------------------------

test("user override on top of an engine proposal keeps the engine list (target absent)", async () => {
  const pollen = dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  expect((await cmdAssign([pollen], OPTS)).errors).toEqual([]);
  const engine = summarize(sc(pollen), pollen).proposal!;
  expect(engine.target_collection).toBe(PCP);
  expect(engine.ranked[0]).toEqual({ collection: PCP, confidence: engine.confidence });

  expect((await cmdAssign([pollen], { ...OPTS, collection: "[Ambient]" })).errors).toEqual([]);
  const doc = sc(pollen);
  expect(doc.proposal!.assigned_by).toBe("user");
  const user = summarize(doc, pollen).proposal!;
  expect(user.target_collection).toBe("[Ambient]");
  expect(user.ranked).toEqual(engine.ranked);
  expect(user.ranked.some((r) => r.collection === "[Ambient]")).toBe(false);
});

test("user-only proposal (no engine run) reports ranked: []", async () => {
  const movements = dirOf("slsk", "Solar Fields", "Solar Fields - Movements (2009)");
  expect(sc(movements).proposal).toBeNull();
  expect((await cmdAssign([movements], { ...OPTS, collection: "[Ambient]" })).errors).toEqual([]);
  const doc = sc(movements);
  expect(doc.proposal!.engine_version).toBe("user");
  expect(doc.proposal!.ranked.length).toBe(1); // the stored synthetic entry...
  expect(summarize(doc, movements).proposal).toEqual({ target_collection: "[Ambient]", confidence: 1, ranked: [] }); // ...is not reported
});

// ---- status --json envelope -----------------------------------------------------

test("status --json: proposal carries ranked [{collection, confidence}], at most 5", () => {
  // A seven-candidate engine proposal written to disk, as assign would store it.
  const reflective = dirOf("slsk", "Solar Fields", "Solar Fields [2001] Reflective Frequencies");
  const doc = sc(reflective);
  doc.proposal = engineProposal(SEVEN);
  doc.status = "proposed";
  writeFileSync(join(reflective, ".intake.json"), serializeSidecar(doc));

  const proc = Bun.spawnSync([process.execPath, "run", CLI, "status", "--json"], {
    env: { ...process.env, INTAKE_RULES_DIR: corpus.rules },
  });
  expect(proc.exitCode).toBe(0);
  const env = JSON.parse(proc.stdout.toString());
  expect(env.ok).toBe(true);
  expect(env.errors).toEqual([]);

  type Row = {
    root_path: string;
    status: string;
    proposal: { target_collection: string; confidence: number; ranked: { collection: string; confidence: number }[] } | null;
  };
  const rows = env.data as Row[];
  const withProp = rows.filter((r) => r.proposal !== null);
  expect(withProp.length).toBe(3); // Pollen (override), Movements (user-only), Reflective (engine)
  for (const r of withProp) {
    expect(Object.keys(r.proposal!).sort()).toEqual(["confidence", "ranked", "target_collection"]);
    expect(Array.isArray(r.proposal!.ranked)).toBe(true);
    expect(r.proposal!.ranked.length).toBeLessThanOrEqual(5);
    for (const c of r.proposal!.ranked) {
      expect(Object.keys(c).sort()).toEqual(["collection", "confidence"]);
      expect(c.confidence).toBeGreaterThanOrEqual(0);
      expect(c.confidence).toBeLessThanOrEqual(1);
    }
  }
  const byRoot = new Map(rows.map((r) => [r.root_path, r]));
  const engineRow = byRoot.get(reflective)!;
  expect(engineRow.proposal!.ranked.map((c) => c.collection)).toEqual(["[C1]", "[C2]", "[C3]", "[C4]", "[C5]"]);
  expect(engineRow.proposal!.ranked[0]!.collection).toBe(engineRow.proposal!.target_collection);
  // `intake assign` stores a proposal without flipping status: a resolved root
  // can carry one, and its summary reports ranked like any other proposal.
  const pollenRow = byRoot.get(dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)"))!;
  expect(pollenRow.status).toBe("resolved");
  expect(pollenRow.proposal!.ranked.length).toBe(1);
});
