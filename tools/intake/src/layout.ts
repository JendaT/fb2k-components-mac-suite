// Library layout for new placements (doc 02 "Library layout and credit rules
// (amendment 003)"). Inside a collection dir `<tier root>/<Collection>`:
//   - the artist already has a release in this collection -> `<Artist>/`
//   - otherwise                                            -> `[Releases]/`
//   - a Various Artists release                            -> `[Compilations]/`
// "Already has" is read from the collection dir: an artist dir, or a release
// of that artist in `[Releases]` or loose in the collection dir. Pure: the
// caller supplies the directory listings (LibraryProbe); nothing here touches
// the disk, so assign() stays a pure library export.

import { parseDirName } from "./naming.ts";
import { isJunkDir, isVariousArtists, normKey } from "./util.ts";

/**
 * Immediate subdirectory names of `dir`, or null when it does not exist.
 * Injected so the layout decision stays pure; commands pass a disk-reading
 * probe, library callers default to NO_LIBRARY.
 */
export type LibraryProbe = (dir: string) => string[] | null;

/** No library to read: every collection dir reads as absent. */
export const NO_LIBRARY: LibraryProbe = () => null;

export const RELEASES_DIR = "[Releases]";
export const COMPILATIONS_DIR = "[Compilations]";

/** A path component as intake writes it: no separators, no control chars, no edge dots/spaces. */
export function sanitizeComponent(s: string): string {
  return s.replace(/[/\\:]/g, "-").replace(/[\u0000-\u001f]/g, "").replace(/^[\s.]+|[\s.]+$/g, "");
}

/** A bracketed dir (`[Releases]`, `[Best Of]`): a slot or a curated selection, never an artist. */
export function isBracketedDir(name: string): boolean {
  return /^\[[^\]]*\]$/.test(name.trim());
}

function visible(name: string): boolean {
  return !name.startsWith(".") && !isJunkDir(name);
}

/**
 * Comparison key for artist names: the map-key normalization (normKey) of the
 * name as a path component, so an artist whose name holds a `/` or `:`
 * matches the dir intake created for it.
 */
function artistKey(name: string): string {
  return normKey(sanitizeComponent(name));
}

/** The existing slot dir matching `canonical` ignoring case (`[releases]`), or null. */
export function existingSlotDir(dirs: string[] | null, canonical: string): string | null {
  const want = canonical.toLowerCase();
  return (dirs ?? []).filter((d) => d.toLowerCase() === want).sort()[0] ?? null;
}

export interface CollectionListing {
  /** Immediate subdir names of the collection dir; null when it does not exist. */
  dirs: string[] | null;
  /** Immediate subdir names of its existing `[Releases]` dir; null when there is none. */
  releases: string[] | null;
}

/** Read what libraryLayout needs through `probe`; the `[Releases]` dir only when needed. */
export function readCollection(probe: LibraryProbe, collectionDir: string, va: boolean): CollectionListing {
  const dirs = probe(collectionDir);
  const slot = va ? null : existingSlotDir(dirs, RELEASES_DIR);
  return { dirs, releases: slot ? probe(`${collectionDir}/${slot}`) : null };
}

export interface Layout {
  structure_slot: "artist" | "releases" | "compilations";
  /** The dir inside the collection dir that receives the release folder. */
  parent: string;
  /**
   * The artist's existing releases in `[Releases]` or loose in the collection
   * dir, relative to the collection dir, when they are why the release goes
   * to an artist folder (none exists yet). Never moved here (doc 02 "Existing
   * library folders"); reported so the user can be told.
   */
  restructure_candidates: string[];
}

function releasesOf(key: string, names: string[]): string[] {
  return names.filter((n) => {
    if (!visible(n) || isBracketedDir(n)) return false;
    const artist = parseDirName(n)?.artist;
    return artist != null && artistKey(artist) === key;
  });
}

/**
 * Where a release by `artist` goes inside a collection, from that
 * collection's listing. A subdir named like the artist is the artist dir
 * (reused with its on-disk spelling); otherwise releases parsed from folder
 * names in `[Releases]` or loose in the collection dir count. Other bracketed
 * dirs are never targets and their releases do not count.
 */
export function libraryLayout(artist: string, listing: CollectionListing): Layout {
  const dirs = listing.dirs ?? [];
  if (isVariousArtists(artist)) {
    return {
      structure_slot: "compilations",
      parent: existingSlotDir(dirs, COMPILATIONS_DIR) ?? COMPILATIONS_DIR,
      restructure_candidates: [],
    };
  }
  const key = artistKey(artist);
  const releasesSlot = existingSlotDir(dirs, RELEASES_DIR) ?? RELEASES_DIR;
  if (key !== "") {
    const own = sanitizeComponent(artist);
    const artistDirs = dirs.filter((d) => visible(d) && !isBracketedDir(d) && artistKey(d) === key).sort();
    if (artistDirs.length > 0) {
      // Prefer the exact spelling when variants coexist (case-sensitive volume).
      const parent = artistDirs.includes(own) ? own : artistDirs[0]!;
      return { structure_slot: "artist", parent, restructure_candidates: [] };
    }
    const candidates = [
      ...releasesOf(key, listing.releases ?? []).map((n) => `${releasesSlot}/${n}`),
      ...releasesOf(key, dirs),
    ].sort();
    if (candidates.length > 0) return { structure_slot: "artist", parent: own, restructure_candidates: candidates };
  }
  return { structure_slot: "releases", parent: releasesSlot, restructure_candidates: [] };
}
