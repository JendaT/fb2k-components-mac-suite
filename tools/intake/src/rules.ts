// Rules-repo file access (doc 02, appendix A): genre-map.yaml,
// label-map.yaml, styles.yaml, overrides.log.yaml. The real files live in the
// private music-rules repo; this repo only knows the schema. Writes (feedback
// increments, alias cache, bootstrap output) re-serialize the whole file —
// hand comments are not preserved (noted in doc 02).

import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { normKey } from "./util.ts";

export type FolderCounts = Record<string, number>; // collection -> count

export interface GenreMap {
  artists: Record<string, FolderCounts>;
  feedback: Record<string, FolderCounts>;
  aliases: Record<string, string>; // alias -> canonical artist
  exceptions: string[]; // full-string artist names that contain separators
}

export interface LabelMap {
  labels: Record<string, FolderCounts>;
}

export interface StyleMap {
  styles: Record<string, string[]>; // discogs style -> collection hints
  genres: Record<string, string[]>;
}

export interface OverrideEvent {
  ts: string;
  sidecar_id: string;
  artist: string | null;
  collection: string;
  by: string;
}

function readYamlFile(path: string): Record<string, unknown> {
  if (!existsSync(path)) return {};
  const doc = Bun.YAML.parse(readFileSync(path, "utf8"));
  return typeof doc === "object" && doc !== null ? (doc as Record<string, unknown>) : {};
}

function asCounts(v: unknown): Record<string, FolderCounts> {
  const out: Record<string, FolderCounts> = {};
  if (typeof v !== "object" || v === null) return out;
  for (const [name, dist] of Object.entries(v)) {
    if (typeof dist !== "object" || dist === null) continue;
    const counts: FolderCounts = {};
    for (const [folder, n] of Object.entries(dist)) if (typeof n === "number" && n > 0) counts[folder] = n;
    if (Object.keys(counts).length > 0) out[name] = counts;
  }
  return out;
}

export function loadGenreMap(rulesDir: string): GenreMap {
  const doc = readYamlFile(join(rulesDir, "genre-map.yaml"));
  const aliases: Record<string, string> = {};
  if (typeof doc.aliases === "object" && doc.aliases !== null) {
    for (const [k, v] of Object.entries(doc.aliases)) if (typeof v === "string") aliases[k] = v;
  }
  return {
    artists: asCounts(doc.artists),
    feedback: asCounts(doc.feedback),
    aliases,
    exceptions: Array.isArray(doc.exceptions) ? doc.exceptions.filter((x): x is string => typeof x === "string") : [],
  };
}

export function saveGenreMap(rulesDir: string, map: GenreMap): void {
  writeFileSync(join(rulesDir, "genre-map.yaml"), Bun.YAML.stringify(map, null, 2) + "\n");
}

export function loadLabelMap(rulesDir: string): LabelMap {
  return { labels: asCounts(readYamlFile(join(rulesDir, "label-map.yaml")).labels) };
}

export function saveLabelMap(rulesDir: string, map: LabelMap): void {
  writeFileSync(join(rulesDir, "label-map.yaml"), Bun.YAML.stringify(map, null, 2) + "\n");
}

export function loadStyleMap(rulesDir: string): StyleMap {
  const doc = readYamlFile(join(rulesDir, "styles.yaml"));
  const lists = (v: unknown): Record<string, string[]> => {
    const out: Record<string, string[]> = {};
    if (typeof v !== "object" || v === null) return out;
    for (const [k, arr] of Object.entries(v)) {
      if (Array.isArray(arr)) out[k] = arr.filter((x): x is string => typeof x === "string");
    }
    return out;
  };
  return { styles: lists(doc.styles), genres: lists(doc.genres) };
}

/** Append one override event (append-only log; one YAML list item per event). */
export function appendOverride(rulesDir: string, ev: OverrideEvent): void {
  const line = Bun.YAML.stringify([ev], null, 2) + "\n";
  appendFileSync(join(rulesDir, "overrides.log.yaml"), line);
}

/** Record user feedback: increment artist's count for a collection. */
export function recordFeedback(map: GenreMap, artist: string, collection: string): void {
  const existing = Object.keys(map.feedback).find((a) => normKey(a) === normKey(artist)) ?? artist;
  const counts = map.feedback[existing] ?? {};
  counts[collection] = (counts[collection] ?? 0) + 1;
  map.feedback[existing] = counts;
}

/** Record an executed placement: increment the artist's real release count. */
export function recordPlacement(map: GenreMap, artist: string, collection: string): void {
  const existing = Object.keys(map.artists).find((a) => normKey(a) === normKey(artist)) ?? artist;
  const counts = map.artists[existing] ?? {};
  counts[collection] = (counts[collection] ?? 0) + 1;
  map.artists[existing] = counts;
}

/** Case/diacritic-insensitive lookup helper for map keys. */
export function findKey<T>(obj: Record<string, T>, name: string): string | null {
  const want = normKey(name);
  for (const k of Object.keys(obj)) if (normKey(k) === want) return k;
  return null;
}
