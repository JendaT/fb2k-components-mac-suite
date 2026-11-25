// Rules-repo file access (doc 02, appendix A): genre-map.yaml,
// label-map.yaml, styles.yaml, overrides.log.yaml. The real files live in the
// private music-rules repo; this repo only knows the schema. Writes (feedback
// increments, alias cache, bootstrap output) re-serialize the whole file —
// hand comments are not preserved (noted in doc 02). Because of that rewrite,
// the two maps are checked on load: a malformed entry is refused, never
// dropped, and a save keeps the top-level keys the CLI does not know.

import { appendFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseRulesYaml, RulesError, shown } from "./config.ts";
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

/**
 * styles.yaml's top-level mapping; {} when absent. A YAML syntax error throws
 * a RulesError (E_BAD_RULES); its shapes are not checked yet.
 */
function readYamlFile(path: string): Record<string, unknown> {
  const doc = parseRulesYaml(path);
  return typeof doc === "object" && doc !== null ? (doc as Record<string, unknown>) : {};
}

// ---- genre-map.yaml and label-map.yaml ----------------------------------------
//
// A save rewrites the whole file from the typed map, so anything the loader
// left out would be lost at the next feedback, alias or placement write. The
// loader therefore refuses what it cannot represent (a RulesError naming the
// file and the key: E_BAD_RULES) instead of dropping it:
// - a section that is not a mapping (`exceptions:` not a list);
// - an entry that is not a mapping of collection to count;
// - a count that is not a finite number of 0 or more;
// - an alias value or an exceptions item that is not a string.
// An absent section is empty; a null one (`feedback:` with nothing under it)
// is refused like any other wrong type. A count of 0 and an empty
// distribution (`X: {}`) are accepted: they carry no evidence, so they stay
// out of the typed map (assign never sees them), and a save writes them back
// where they were. Keys are always strings: Bun.YAML reads `1999:` or
// `true:` as the key "1999" or "true", and the serializer quotes a key that
// would read back as anything else. (One exception: Bun reads a `<<` key as
// a YAML merge key even when quoted, so an artist or label named `<<` does
// not survive a save.)

/** The parsed file behind a loaded map, for its save: unknown top-level keys and inert entries. */
const loadedDocs = new WeakMap<object, Record<string, unknown>>();

function isMapping(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** `artists."Some Artist"."[Coll]"`: a section name, then quoted keys. */
function keyPath(section: string, ...keys: string[]): string {
  return section + keys.map((k) => `.${JSON.stringify(k)}`).join("");
}

/** A map file's top-level mapping; {} when the file is absent or empty. */
function readMapFile(path: string): Record<string, unknown> {
  const doc = parseRulesYaml(path);
  if (doc === undefined || doc === null) return {};
  if (!isMapping(doc)) throw new RulesError(path, null, `must be a mapping of sections, got ${shown(doc)}`);
  return doc;
}

/** A name -> {collection: count} section, checked; zero counts and empty distributions left out. */
function countsSection(doc: Record<string, unknown>, section: string, file: string): Record<string, FolderCounts> {
  const out: Record<string, FolderCounts> = {};
  const v = doc[section];
  if (v === undefined) return out;
  if (!isMapping(v)) throw new RulesError(file, section, `must be a mapping of name to collection counts, got ${shown(v)}`);
  for (const [name, dist] of Object.entries(v)) {
    if (!isMapping(dist))
      throw new RulesError(file, keyPath(section, name), `must be a mapping of collection to count, got ${shown(dist)}`);
    const counts: FolderCounts = {};
    for (const [collection, n] of Object.entries(dist)) {
      if (typeof n !== "number" || !Number.isFinite(n) || n < 0)
        throw new RulesError(file, keyPath(section, name, collection), `count must be a number of 0 or more, got ${shown(n)}`);
      if (n > 0) counts[collection] = n;
    }
    if (Object.keys(counts).length > 0) out[name] = counts;
  }
  return out;
}

/** The typed counts with the file's inert entries (zero counts, empty distributions) back in place. */
function withInert(fileSection: unknown, typed: Record<string, FolderCounts>): Record<string, FolderCounts> {
  if (!isMapping(fileSection)) return typed;
  const out: Record<string, FolderCounts> = {};
  for (const [name, dist] of Object.entries(fileSection)) out[name] = { ...(dist as FolderCounts), ...typed[name] };
  for (const [name, counts] of Object.entries(typed)) if (!Object.hasOwn(out, name)) out[name] = counts;
  return out;
}

/**
 * The document a save writes: the loaded file's top-level keys in their
 * order, the known sections replaced by `sections` and the unknown ones
 * unchanged, then any known section the file did not have.
 */
function docToWrite(map: object, sections: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(loadedDocs.get(map) ?? {})) out[k] = Object.hasOwn(sections, k) ? sections[k] : v;
  for (const [k, v] of Object.entries(sections)) if (!Object.hasOwn(out, k)) out[k] = v;
  return out;
}

export function loadGenreMap(rulesDir: string): GenreMap {
  const file = join(rulesDir, "genre-map.yaml");
  const doc = readMapFile(file);
  const aliases: Record<string, string> = {};
  if (doc.aliases !== undefined) {
    if (!isMapping(doc.aliases))
      throw new RulesError(file, "aliases", `must be a mapping of alias to artist name, got ${shown(doc.aliases)}`);
    for (const [k, v] of Object.entries(doc.aliases)) {
      if (typeof v !== "string") throw new RulesError(file, keyPath("aliases", k), `must be an artist name, got ${shown(v)}`);
      aliases[k] = v;
    }
  }
  const exceptions: string[] = [];
  if (doc.exceptions !== undefined) {
    if (!Array.isArray(doc.exceptions))
      throw new RulesError(file, "exceptions", `must be a list of artist names, got ${shown(doc.exceptions)}`);
    for (const [i, x] of doc.exceptions.entries()) {
      if (typeof x !== "string") throw new RulesError(file, `exceptions[${i}]`, `must be an artist name, got ${shown(x)}`);
      exceptions.push(x);
    }
  }
  const map: GenreMap = {
    artists: countsSection(doc, "artists", file),
    feedback: countsSection(doc, "feedback", file),
    aliases,
    exceptions,
  };
  loadedDocs.set(map, doc);
  return map;
}

export function saveGenreMap(rulesDir: string, map: GenreMap): void {
  const loaded = loadedDocs.get(map) ?? {};
  const doc = docToWrite(map, {
    artists: withInert(loaded.artists, map.artists),
    feedback: withInert(loaded.feedback, map.feedback),
    aliases: map.aliases,
    exceptions: map.exceptions,
  });
  writeFileSync(join(rulesDir, "genre-map.yaml"), Bun.YAML.stringify(doc, null, 2) + "\n");
}

export function loadLabelMap(rulesDir: string): LabelMap {
  const file = join(rulesDir, "label-map.yaml");
  const doc = readMapFile(file);
  const map: LabelMap = { labels: countsSection(doc, "labels", file) };
  loadedDocs.set(map, doc);
  return map;
}

export function saveLabelMap(rulesDir: string, map: LabelMap): void {
  const doc = docToWrite(map, { labels: withInert(loadedDocs.get(map)?.labels, map.labels) });
  writeFileSync(join(rulesDir, "label-map.yaml"), Bun.YAML.stringify(doc, null, 2) + "\n");
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
  const existing = findKey(map.feedback, artist) ?? artist;
  const counts = map.feedback[existing] ?? {};
  counts[collection] = (counts[collection] ?? 0) + 1;
  map.feedback[existing] = counts;
  keyIndex.delete(map.feedback);
}

/** Record an executed placement: increment the artist's real release count. */
export function recordPlacement(map: GenreMap, artist: string, collection: string): void {
  const existing = findKey(map.artists, artist) ?? artist;
  const counts = map.artists[existing] ?? {};
  counts[collection] = (counts[collection] ?? 0) + 1;
  map.artists[existing] = counts;
  keyIndex.delete(map.artists);
}

/**
 * Normalized-key index per map object. `assign` calls findKey up to ~8 times
 * per release (artists, feedback, aliases, labels, styles, plus one per similar
 * artist), and a linear scan over a real genre map made that O(artists) each
 * time. Keys only ever get ADDED to these objects, by recordPlacement /
 * recordFeedback, and both drop their entry here — so the index cannot go
 * stale. Anything that removes or renames keys must do the same.
 */
const keyIndex = new WeakMap<object, Map<string, string>>();

/** Case/diacritic-insensitive lookup helper for map keys. */
export function findKey<T>(obj: Record<string, T>, name: string): string | null {
  let index = keyIndex.get(obj);
  if (!index) {
    index = new Map<string, string>();
    // First key wins, matching the previous scan order (Object.keys order).
    for (const k of Object.keys(obj)) {
      const nk = normKey(k);
      if (!index.has(nk)) index.set(nk, k);
    }
    keyIndex.set(obj, index);
  }
  return index.get(normKey(name)) ?? null;
}
