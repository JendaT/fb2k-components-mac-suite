// Assign engine unit tests: priors, collab/alias matrix, evidence tiers,
// short-circuit, naming — plus the doc 02 accuracy replay harness
// (gate: top-1 >= 0.90). All providers are fakes; no network.

import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { artistPrior, assign, buildTargetPath, similarVote, styleHint, type AssignInput, type AssignRules } from "../src/assign.ts";
import { loadAssignConfig, loadConfig } from "../src/config.ts";
import { loadGenreMap, loadLabelMap, loadStyleMap } from "../src/rules.ts";
import { FIXTURES } from "./helpers.ts";

const RULES_DIR = join(FIXTURES, "rules");

function rules(): AssignRules {
  return {
    genre: loadGenreMap(RULES_DIR),
    labels: loadLabelMap(RULES_DIR),
    styles: loadStyleMap(RULES_DIR),
    config: loadAssignConfig(RULES_DIR),
  };
}

function input(partial: Partial<AssignInput>): AssignInput {
  return {
    artist: null, album: "Album", year: "2020", label: null, catno: null,
    styles: [], genres: [], tier_eligible: "hq", singles: false,
    ...partial,
  };
}

const PCP = "[Psychill & Chillout & Psydub]";
const AMB = "[Ambient]";

// Similar-artist fixture: only "Aural Method" has data.
const fakeSimilar = async (artist: string) =>
  artist === "Aural Method"
    ? [{ name: "Solar Fields", match: 0.9 }, { name: "Carbon Based Lifeforms", match: 0.8 }]
    : null;

test("artist prior: direct, alias map, collab split, exceptions", async () => {
  const g = rules().genre;
  const learned: Record<string, string> = {};

  const direct = await artistPrior("aes dana", g, null, learned); // casefold match
  expect(direct?.releases).toBe(6);
  expect(direct?.dist[PCP]).toBe(1);

  const viaAlias = await artistPrior("CBL", g, null, learned);
  expect(viaAlias?.dist[PCP]).toBe(1);

  const collab = await artistPrior("Aes Dana & Miktek", g, null, learned);
  expect(collab?.dist[PCP]).toBe(1);
  expect(collab?.releases).toBe(8);

  // Exception: full name with separator, unknown -> never split into members.
  g.exceptions.push("Cell & Vampillia");
  const exception = await artistPrior("Cell & Vampillia", g, null, learned);
  expect(exception).toBeNull(); // Cell alone would match if it were split

  expect(await artistPrior("Nobody Known", g, null, learned)).toBeNull();
});

test("artist prior: provider alias expansion is learned", async () => {
  const g = rules().genre;
  const learned: Record<string, string> = {};
  const aliasProvider = async (name: string) => (name === "Sync Twentyfour" ? ["Sync24"] : null);
  const prior = await artistPrior("Sync Twentyfour", g, aliasProvider, learned);
  expect(prior?.dist["[Downtempo & Electronica]"]).toBe(1);
  expect(learned["Sync Twentyfour"]).toBe("Sync24");
});

test("similarity vote and style hints", async () => {
  const r = rules();
  const votes = await similarVote("Aural Method", r.genre, fakeSimilar);
  expect(votes[PCP]!).toBeGreaterThan(0.9);
  expect(votes[AMB]!).toBeLessThan(0.1);

  const hint = styleHint(input({ styles: ["Ambient", "Downtempo"] }), r.styles);
  expect(hint[AMB]).toBe(0.5);
  expect(hint["[Downtempo & Electronica]"]).toBe(0.5);
});

test("short-circuit: unique strong artist prior skips network tiers", async () => {
  let similarCalled = false;
  const outcome = await assign(input({ artist: "Ott" }), rules(), {
    similar: async () => {
      similarCalled = true;
      return [];
    },
  });
  expect(outcome.short_circuited).toBe(true);
  expect(similarCalled).toBe(false);
  expect(outcome.proposal?.target_collection).toBe(PCP);
  expect(outcome.proposal?.confidence).toBe(0.95);
  expect(outcome.needs_review).toBe(false);
});

test("scored path: mixed prior gets renormalized confidence, no review when clear", async () => {
  const outcome = await assign(input({ artist: "Solar Fields" }), rules());
  expect(outcome.short_circuited).toBe(false);
  expect(outcome.proposal?.target_collection).toBe(PCP);
  expect(outcome.proposal?.confidence).toBe(0.89);
  expect(outcome.needs_review).toBe(false);
});

test("label-only evidence: right folder, flagged for review", async () => {
  const outcome = await assign(input({ artist: "Zymosis", label: "Ultimae Records" }), rules());
  expect(outcome.proposal?.target_collection).toBe(PCP);
  expect(outcome.needs_review).toBe(true);
});

test("no evidence at all: null proposal", async () => {
  const outcome = await assign(input({ artist: "Nobody Known" }), rules());
  expect(outcome.proposal).toBeNull();
  expect(outcome.needs_review).toBe(true);
});

test("target path: tier routing + naming template (doc 02 example shape)", () => {
  const cfg = loadAssignConfig(RULES_DIR);
  const full = buildTargetPath(
    input({ artist: "Aes Dana", album: "Pollen", year: "2012", label: "Ultimae Records", catno: "inre042" }),
    PCP, cfg,
  );
  expect(full.target_path).toBe(`/library/music.hq/${PCP}/Aes Dana/Aes Dana [2012] Pollen (Ultimae Records; inre042)`);
  expect(full.structure_slot).toBe("artist");

  const uhq = buildTargetPath(
    input({ artist: "Sync24", album: "Omnimotion Remixed", year: "2024", tier_eligible: "uhq" }),
    "[Downtempo & Electronica]", cfg,
  );
  expect(uhq.target_path).toBe("/library/music.uhq/[Downtempo & Electronica]/Sync24/Sync24 [2024] Omnimotion Remixed");

  expect(buildTargetPath(input({ artist: "X", album: "Y", tier_eligible: "reject" }), AMB, cfg).target_path).toBeNull();
  const single = buildTargetPath(input({ artist: "X", album: null, singles: true }), AMB, cfg);
  expect(single.target_path).toBeNull();
  expect(single.structure_slot).toBe("singles");

  const noYear = buildTargetPath(input({ artist: "X", album: "Y", year: null }), AMB, cfg);
  expect(noYear.target_path).toBe(`/library/music.hq/${AMB}/X/X Y`);
});

test("resolver config unaffected by assign sections in structure.yaml", () => {
  expect(loadConfig(RULES_DIR).weights.purity).toBe(0.35);
});

// ---- accuracy replay harness (doc 02 gate: top-1 >= 0.90) --------------------

interface Case {
  artist: string;
  label: string | null;
  styles?: string[];
  similar?: boolean;
  expect: string;
}

test("assign accuracy: top-1 >= 0.90 on the replay corpus", async () => {
  const { cases } = JSON.parse(
    readFileSync(join(import.meta.dir, "expected", "assign-cases.json"), "utf8"),
  ) as { cases: Case[] };
  expect(cases.length).toBeGreaterThanOrEqual(20);

  const r = rules();
  let top1 = 0;
  let top3 = 0;
  const misses: string[] = [];
  for (const c of cases) {
    const outcome = await assign(
      input({ artist: c.artist, label: c.label, styles: c.styles ?? [] }),
      r,
      { similar: c.similar ? fakeSimilar : null },
    );
    const ranked = outcome.proposal?.ranked ?? [];
    if (ranked[0]?.collection === c.expect) top1++;
    else misses.push(`${c.artist} -> ${ranked[0]?.collection ?? "none"} (wanted ${c.expect})`);
    if (ranked.slice(0, 3).some((f) => f.collection === c.expect)) top3++;
  }
  const acc1 = top1 / cases.length;
  const acc3 = top3 / cases.length;
  console.log(
    `assign accuracy: top-1 ${(acc1 * 100).toFixed(1)}% (${top1}/${cases.length}), ` +
      `top-3 ${(acc3 * 100).toFixed(1)}%${misses.length ? `; misses: ${misses.join("; ")}` : ""}`,
  );
  expect(acc1).toBeGreaterThanOrEqual(0.9);
});
