// Assignment engine (doc 02): ranked evidence scorer deciding which
// genre-collection folder a release belongs to. Pure library export —
// consumed by intake, the Tidal cache feature, and future downloaders.
// Network tiers (similar-artist votes, alias expansion) are injected
// providers; null providers degrade gracefully to prior-only scoring.

import type { AssignConfig, Proposal, RankedFolder, StructureSlot, Tier } from "./types.ts";
import type { FolderCounts, GenreMap, LabelMap, StyleMap } from "./rules.ts";
import { findKey } from "./rules.ts";
import { normKey, round2 } from "./util.ts";

export const ENGINE_VERSION = "0.1.0";

export interface AssignRules {
  genre: GenreMap;
  labels: LabelMap;
  styles: StyleMap;
  config: AssignConfig;
}

export interface AssignInput {
  artist: string | null;
  album: string | null;
  year: string | null;
  label: string | null;
  catno: string | null;
  styles: string[];
  genres: string[];
  tier_eligible: Tier;
  singles: boolean;
}

export interface SimilarArtist {
  name: string;
  match: number; // 0..1
}

export interface AssignProviders {
  similar?: ((artist: string) => Promise<SimilarArtist[] | null>) | null;
  aliases?: ((artist: string) => Promise<string[] | null>) | null;
}

export interface AssignOutcome {
  proposal: Proposal | null; // null when there is no evidence at all
  needs_review: boolean;
  learned_aliases: Record<string, string>; // alias -> canonical map key
  short_circuited: boolean;
}

const SEPARATOR_RE = /\s+(?:&|,|feat\.?|ft\.?|vs\.?|x|meets|with)\s+/i;

function mergedArtistCounts(genre: GenreMap, key: string): FolderCounts {
  const out: FolderCounts = { ...(genre.artists[key] ?? {}) };
  const fbKey = findKey(genre.feedback, key);
  if (fbKey) for (const [f, n] of Object.entries(genre.feedback[fbKey]!)) out[f] = (out[f] ?? 0) + n;
  return out;
}

function normalizeDist(counts: FolderCounts): { dist: FolderCounts; total: number } {
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  if (total === 0) return { dist: {}, total: 0 };
  const dist: FolderCounts = {};
  for (const [f, n] of Object.entries(counts)) dist[f] = n / total;
  return { dist, total };
}

interface ArtistPrior {
  dist: FolderCounts; // P(folder|artist), sums to 1
  releases: number; // evidence strength
  matched: string[]; // map keys that contributed (for alias learning bookkeeping)
}

/**
 * Tier 1 — artist prior with normalized matching, alias expansion, and collab
 * splitting per doc 02. Returns null when nothing matches.
 */
export async function artistPrior(
  name: string,
  genre: GenreMap,
  aliasProvider: AssignProviders["aliases"],
  learned: Record<string, string>,
): Promise<ArtistPrior | null> {
  const direct = async (n: string): Promise<{ key: string; counts: FolderCounts } | null> => {
    let key = findKey(genre.artists, n) ?? findKey(genre.feedback, n);
    if (!key) {
      const aliasKey = findKey(genre.aliases, n);
      if (aliasKey) key = findKey(genre.artists, genre.aliases[aliasKey]!) ?? findKey(genre.feedback, genre.aliases[aliasKey]!);
    }
    if (!key && aliasProvider) {
      for (const alias of (await aliasProvider(n)) ?? []) {
        const hit = findKey(genre.artists, alias) ?? findKey(genre.feedback, alias);
        if (hit) {
          learned[n] = hit;
          key = hit;
          break;
        }
      }
    }
    return key ? { key, counts: mergedArtistCounts(genre, key) } : null;
  };

  // Full string first — the exceptions list covers names containing separators.
  const full = await direct(name);
  if (full) {
    const { dist, total } = normalizeDist(full.counts);
    return { dist, releases: total, matched: [full.key] };
  }
  if (genre.exceptions.some((e) => normKey(e) === normKey(name))) return null;
  if (!SEPARATOR_RE.test(name)) return null;

  // Collab: each known member votes with its own prior, averaged.
  const members = name.split(SEPARATOR_RE).map((m) => m.trim()).filter(Boolean);
  const hits: { key: string; counts: FolderCounts }[] = [];
  for (const m of members) {
    const hit = await direct(m);
    if (hit) hits.push(hit);
  }
  if (hits.length === 0) return null;
  const dist: FolderCounts = {};
  let releases = 0;
  for (const h of hits) {
    const { dist: d, total } = normalizeDist(h.counts);
    releases += total;
    for (const [f, p] of Object.entries(d)) dist[f] = (dist[f] ?? 0) + p / hits.length;
  }
  return { dist, releases, matched: hits.map((h) => h.key) };
}

/** Tier 2 — label prior. */
export function labelPrior(label: string | null, labels: LabelMap): FolderCounts {
  if (!label) return {};
  const key = findKey(labels.labels, label);
  return key ? normalizeDist(labels.labels[key]!).dist : {};
}

/** Tier 3a — similarity vote: known similar artists vote for their folders. */
export async function similarVote(
  artist: string | null,
  genre: GenreMap,
  provider: AssignProviders["similar"],
): Promise<FolderCounts> {
  if (!artist || !provider) return {};
  const similars = (await provider(artist)) ?? [];
  const votes: FolderCounts = {};
  let weight = 0;
  for (const s of similars) {
    const key = findKey(genre.artists, s.name);
    if (!key) continue;
    weight += s.match;
    const { dist } = normalizeDist(mergedArtistCounts(genre, key));
    for (const [f, p] of Object.entries(dist)) votes[f] = (votes[f] ?? 0) + s.match * p;
  }
  if (weight === 0) return {};
  for (const f of Object.keys(votes)) votes[f] = votes[f]! / weight;
  return votes;
}

/** Tier 3b — style/genre hints via styles.yaml. */
export function styleHint(input: AssignInput, styles: StyleMap): FolderCounts {
  const wanted = [
    ...input.styles.map((s) => ({ s, map: styles.styles })),
    ...input.genres.map((s) => ({ s, map: styles.genres })),
  ];
  const mapped = wanted
    .map(({ s, map }) => {
      const key = findKey(map, s);
      return key ? map[key]! : null;
    })
    .filter((x): x is string[] => x !== null && x.length > 0);
  if (mapped.length === 0) return {};
  const hint: FolderCounts = {};
  for (const folders of mapped) {
    for (const f of folders) hint[f] = (hint[f] ?? 0) + 1 / mapped.length;
  }
  for (const f of Object.keys(hint)) hint[f] = Math.min(1, hint[f]!);
  return hint;
}

function sanitizeComponent(s: string): string {
  return s.replace(/[/\\:]/g, "-").replace(/[\u0000-\u001f]/g, "").replace(/^[\s.]+|[\s.]+$/g, "");
}

function fillTemplate(tpl: string, fields: Record<string, string | null>): string {
  let out = tpl;
  for (const [k, v] of Object.entries(fields)) out = out.replaceAll(`{${k}}`, v ?? "");
  return out
    .replace(/\s*\[\s*\]/g, "")
    .replace(/\s*\(\s*;?\s*\)/g, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

/** Tier routing + naming: compute target_path within the eligible tier. */
export function buildTargetPath(
  input: AssignInput,
  collection: string,
  cfg: AssignConfig,
): { target_path: string | null; structure_slot: StructureSlot } {
  if (input.singles) return { target_path: null, structure_slot: "singles" }; // slot layout is a pending TBD
  if (input.tier_eligible === "reject") return { target_path: null, structure_slot: "artist" };
  const tier = cfg.tiers[`music.${input.tier_eligible}`];
  if (!tier || !input.artist || !input.album) return { target_path: null, structure_slot: "artist" };
  const tpl = input.label && input.catno ? cfg.naming.release : cfg.naming.release_no_label;
  const folder = fillTemplate(tpl, {
    artist: input.artist,
    year: input.year,
    album: input.album,
    label: input.label,
    catno: input.catno,
  });
  const parts = [collection, input.artist, folder].map(sanitizeComponent);
  return { target_path: `${tier.root}/${parts.join("/")}`, structure_slot: "artist" };
}

/**
 * assign(artist, meta, rules) -> ranked folders (doc 02).
 * Lazy: a unique, strong artist prior short-circuits and skips network tiers.
 */
export async function assign(
  input: AssignInput,
  rules: AssignRules,
  providers: AssignProviders = {},
): Promise<AssignOutcome> {
  const cfg = rules.config;
  const learned: Record<string, string> = {};
  const prior = input.artist
    ? await artistPrior(input.artist, rules.genre, providers.aliases ?? null, learned)
    : null;

  const finish = (ranked: RankedFolder[], shortCircuited: boolean): AssignOutcome => {
    if (ranked.length === 0) {
      return { proposal: null, needs_review: true, learned_aliases: learned, short_circuited: false };
    }
    const top = ranked[0]!;
    const margin = round2(ranked.length > 1 ? top.score - ranked[1]!.score : top.score);
    const needsReview = top.score < cfg.needs_review.confidence || margin < cfg.needs_review.margin;
    const { target_path, structure_slot } = buildTargetPath(input, top.collection, cfg);
    const proposal: Proposal = {
      engine_version: ENGINE_VERSION,
      ranked,
      target_collection: top.collection,
      confidence: top.score,
      margin,
      target_path,
      structure_slot,
      assigned_by: "engine",
      alternates_shown: ranked.length > 1,
    };
    return { proposal, needs_review: needsReview, learned_aliases: learned, short_circuited: shortCircuited };
  };

  // Short-circuit: single-folder artist prior with enough releases.
  if (prior && Object.keys(prior.dist).length === 1 && prior.releases >= cfg.short_circuit.min_releases) {
    const collection = Object.keys(prior.dist)[0]!;
    return finish(
      [{
        collection,
        score: cfg.short_circuit.confidence,
        evidence: { artist_prior: 1, label_prior: 0, similar_vote: 0, style_hint: 0 },
      }],
      true,
    );
  }

  const label = labelPrior(input.label, rules.labels);
  const similar = await similarVote(input.artist, rules.genre, providers.similar ?? null);
  const style = styleHint(input, rules.styles);
  const artistDist = prior?.dist ?? {};

  const folders = new Set([
    ...Object.keys(artistDist),
    ...Object.keys(label),
    ...Object.keys(similar),
    ...Object.keys(style),
  ]);
  const w = cfg.weights;
  // Scores are renormalized over the evidence tiers that could speak at all,
  // so absent network tiers do not deflate confidence (doc 02 example: artist
  // 0.95 + label 0.88 -> ~0.9, not 0.7). An artist/label present in the input
  // but unknown to the maps IS evidence of absence and stays in the
  // denominator; similar/style only count when they produced votes.
  const denom =
    (input.artist ? w.artist : 0) +
    (input.label ? w.label : 0) +
    (Object.keys(similar).length > 0 ? w.similar : 0) +
    (Object.keys(style).length > 0 ? w.style : 0);
  const ranked: RankedFolder[] = [...folders]
    .map((collection) => {
      const evidence = {
        artist_prior: round2(artistDist[collection] ?? 0),
        label_prior: round2(label[collection] ?? 0),
        similar_vote: round2(similar[collection] ?? 0),
        style_hint: round2(style[collection] ?? 0),
      };
      const raw =
        evidence.artist_prior * w.artist +
        evidence.label_prior * w.label +
        evidence.similar_vote * w.similar +
        evidence.style_hint * w.style;
      return { collection, score: round2(denom > 0 ? raw / denom : 0), evidence };
    })
    .sort((a, b) => b.score - a.score || (a.collection < b.collection ? -1 : 1));

  return finish(ranked, false);
}
