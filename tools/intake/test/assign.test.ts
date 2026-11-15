// Assign engine unit tests: priors, collab/alias matrix, evidence tiers,
// short-circuit, naming — plus the doc 02 accuracy replay harness
// (gate: top-1 >= 0.90). All providers are fakes; no network.

import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  artistPrior, assign, buildTargetPath, similarVote, styleHint, type AssignInput, type AssignRules, type SimilarArtist,
} from "../src/assign.ts";
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

// ---- Various Artists: the artist tier is unavailable, not evidence -----------

const COLL_X = "[Collection X]";
const COLL_Y = "[Collection Y]";
const COLL_Z = "[Collection Z]";

/** Synthetic rules where VA credits hold large priors, as a raw bootstrap left them. */
function vaRules(): AssignRules {
  return {
    genre: {
      artists: {
        "Various Artists": { [COLL_X]: 40, [COLL_Y]: 5 },
        VA: { [COLL_X]: 12 },
        "Example Artist": { [COLL_Y]: 3 },
        "Example Mixed": { [COLL_X]: 1, [COLL_Y]: 1 },
      },
      feedback: { "Various Artists": { [COLL_X]: 7 } },
      aliases: {},
      exceptions: [],
    },
    labels: { labels: { "Example Label": { [COLL_Y]: 3, [COLL_Z]: 1 } } },
    styles: { styles: { "Example Style": [COLL_Z] }, genres: {} },
    config: loadAssignConfig(RULES_DIR),
  };
}

function spyProviders(similarResult: SimilarArtist[] | null = [{ name: "Various Artists", match: 1 }]) {
  const calls = { similar: [] as string[], aliases: [] as string[] };
  const providers = {
    similar: async (a: string) => {
      calls.similar.push(a);
      return similarResult;
    },
    aliases: async (a: string) => {
      calls.aliases.push(a);
      return ["Various Artists"];
    },
  };
  return { calls, providers };
}

test("VA input: ranked by label alone, no artist prior, no short-circuit", async () => {
  for (const artist of ["Various Artists", "VA", "Various", "V.A.", "V/A"]) {
    const outcome = await assign(input({ artist, label: "Example Label" }), vaRules());
    expect(outcome.short_circuited).toBe(false);
    const ranked = outcome.proposal!.ranked;
    expect(ranked.map((f) => f.collection)).toEqual([COLL_Y, COLL_Z]);
    for (const f of ranked) expect(f.evidence.artist_prior).toBe(0);
    // Renormalized over the label tier alone: score = P(folder|label).
    expect(ranked[0]!.score).toBe(0.75);
    expect(ranked[1]!.score).toBe(0.25);
    expect(outcome.proposal!.confidence).toBe(0.75);
    expect(outcome.proposal!.structure_slot).toBe("compilations");
  }
});

test("VA input: label and style renormalize over the tiers that spoke", async () => {
  const outcome = await assign(
    input({ artist: "Various Artists", label: "Example Label", styles: ["Example Style"] }),
    vaRules(),
  );
  // label 0.25 + style 0.10 = 0.35; Y = 0.75*0.25/0.35, Z = (0.25*0.25 + 1*0.10)/0.35.
  expect(outcome.proposal!.ranked.map((f) => [f.collection, f.score])).toEqual([[COLL_Y, 0.54], [COLL_Z, 0.46]]);
});

test("VA input without label or style evidence: no proposal, needs review", async () => {
  for (const artist of ["Various Artists", "VA"]) {
    const outcome = await assign(input({ artist }), vaRules());
    expect(outcome.proposal).toBeNull();
    expect(outcome.needs_review).toBe(true);
    expect(outcome.short_circuited).toBe(false);
  }
});

test("VA input: similar and alias providers are never called", async () => {
  for (const artist of ["Various Artists", "Various", "V/A"]) {
    const { calls, providers } = spyProviders();
    const outcome = await assign(input({ artist, label: "Example Label" }), vaRules(), providers);
    expect(calls).toEqual({ similar: [], aliases: [] });
    expect(outcome.learned_aliases).toEqual({});
    expect(outcome.proposal!.ranked.every((f) => f.evidence.similar_vote === 0)).toBe(true);
  }
});

test("non-VA artist still uses its prior (short-circuit and scored path)", async () => {
  const strong = await assign(input({ artist: "Example Artist" }), vaRules());
  expect(strong.short_circuited).toBe(true);
  expect(strong.proposal?.target_collection).toBe(COLL_Y);
  expect(strong.proposal?.confidence).toBe(0.95);

  const { calls, providers } = spyProviders(null);
  const mixed = await assign(input({ artist: "Example Mixed", label: "Example Label" }), vaRules(), providers);
  expect(mixed.short_circuited).toBe(false);
  expect(calls.similar).toEqual(["Example Mixed"]);
  // artist 0.5 + label 0.25 = 0.75; Y = (0.5*0.5 + 0.75*0.25)/0.75, X = 0.5*0.5/0.75.
  expect(mixed.proposal!.ranked.map((f) => [f.collection, f.score, f.evidence.artist_prior])).toEqual([
    [COLL_Y, 0.58, 0.5],
    [COLL_X, 0.33, 0.5],
    [COLL_Z, 0.08, 0],
  ]);
});

// ---- No-label credits: the label tier is unavailable, not evidence ----------

/** Synthetic rules where no-label credits hold large label priors, as a raw bootstrap left them. */
function noLabelRules(): AssignRules {
  const r = vaRules();
  r.labels = {
    labels: {
      "Self-Released": { [COLL_X]: 60, [COLL_Y]: 5 },
      "Not On Label": { [COLL_X]: 9 },
      "Example Label": { [COLL_Y]: 3, [COLL_Z]: 1 },
    },
  };
  return r;
}

// "Self-Released" exercises the prior lookup (the map holds it); the Discogs
// spelling is not a map key and exercises the denominator.
const NO_LABEL_INPUTS = ["Self-Released", "self released", "Not On Label (Example Artist Self-released)", "No Label"];

test("no-label input label: no label prior, same scores as a null label", async () => {
  for (const label of NO_LABEL_INPUTS) {
    // Scored path: artist plus style evidence.
    const base = { artist: "Example Mixed", styles: ["Example Style"] };
    const withLabel = await assign(input({ ...base, label }), noLabelRules());
    const without = await assign(input({ ...base, label: null }), noLabelRules());
    expect(withLabel.proposal!.ranked.every((f) => f.evidence.label_prior === 0)).toBe(true);
    expect(withLabel.proposal!.ranked).toEqual(without.proposal!.ranked);
    expect(withLabel.proposal!.confidence).toBe(without.proposal!.confidence);
    expect(withLabel.needs_review).toBe(without.needs_review);
    // artist 0.5 + style 0.10 = 0.6; X = Y = 0.5*0.5/0.6, Z = 1*0.10/0.6.
    expect(withLabel.proposal!.ranked.map((f) => [f.collection, f.score])).toEqual([
      [COLL_X, 0.42], [COLL_Y, 0.42], [COLL_Z, 0.17],
    ]);

    // An unknown artist and the no-label credit as the only other evidence:
    // no proposal, as with a null label.
    const alone = await assign(input({ artist: "Nobody Known", label }), noLabelRules());
    expect(alone.proposal).toBeNull();
    expect(alone.needs_review).toBe(true);
  }
});

test("a real label still votes beside no-label keys in the map", async () => {
  const outcome = await assign(input({ artist: "Example Mixed", label: "Example Label" }), noLabelRules());
  // artist 0.5 + label 0.25 = 0.75; Y = (0.5*0.5 + 0.75*0.25)/0.75, X = 0.5*0.5/0.75.
  expect(outcome.proposal!.ranked.map((f) => [f.collection, f.score, f.evidence.label_prior])).toEqual([
    [COLL_Y, 0.58, 0.75],
    [COLL_X, 0.33, 0],
    [COLL_Z, 0.08, 0.25],
  ]);
});

test("no-label input label still appears in the target folder name", async () => {
  const outcome = await assign(
    input({ artist: "Example Artist", album: "Example Album", label: "Self-Released", catno: "none" }),
    noLabelRules(),
  );
  expect(outcome.proposal!.target_path).toContain("Self-Released");
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

  // Various Artists (the resolver's VA credit, or Discogs' "Various"): compilations
  // slot, no target until its layout is decided.
  for (const artist of ["Various Artists", "Various", "VA"]) {
    const comp = buildTargetPath(input({ artist, album: "Y", label: "Some Label", catno: "CAT1" }), AMB, cfg);
    expect(comp).toEqual({ target_path: null, structure_slot: "compilations" });
  }
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
