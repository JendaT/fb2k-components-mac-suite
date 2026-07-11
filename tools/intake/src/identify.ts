// Identify stage (doc 02): establish what a release IS. Fast path first
// (folder-name grammar + tags, Discogs confirmation); beets shim as the hard
// path; graceful offline degradation to "unconfirmed"/"unidentified".

import { basename } from "node:path";
import { parseDirName } from "./naming.ts";
import type { DiscogsProvider, ShimProvider } from "./providers.ts";
import type { IdentCandidate, Identification, Sidecar } from "./types.ts";
import { isoLocal, normKey } from "./util.ts";

export interface IdentifyDeps {
  discogs: DiscogsProvider | null;
  shim: ShimProvider | null;
  acceptDistance: number; // shim distance acceptance threshold (doc 02: 0.15)
  now: () => Date;
}

export interface IdentifyOutcome {
  identification: Identification;
  needs_review: boolean;
  issues: string[]; // e.g. shim_unavailable
}

function majorityDate(sidecar: Sidecar): string | null {
  const counts = new Map<string, number>();
  for (const f of sidecar.files) {
    const d = f.tags.date;
    if (d == null) continue;
    const y = String(d).slice(0, 4);
    counts.set(y, (counts.get(y) ?? 0) + 1);
  }
  let best: string | null = null;
  let n = 0;
  for (const [y, c] of counts) if (c > n) { best = y; n = c; }
  return best;
}

export async function identifyRoot(dir: string, sidecar: Sidecar, deps: IdentifyDeps): Promise<IdentifyOutcome> {
  const ts = isoLocal(deps.now());
  const issues: string[] = [];
  const base: Identification = {
    status: "unidentified",
    source: null,
    release_id: null,
    artist: sidecar.cluster.albumartist,
    album: sidecar.cluster.album,
    year: majorityDate(sidecar),
    label: null,
    catno: null,
    styles: [],
    genres: [],
    distance: null,
    grammar: null,
    candidates: null,
    identified_at: ts,
  };

  // Fast path step 1+2 — folder grammar merged with tags (tags win for
  // artist/album, folder wins for year/label/catno when tags lack them).
  // Virtual roots have no meaningful dir name of their own.
  const parsed = sidecar.virtual ? null : parseDirName(basename(dir));
  if (parsed) {
    base.grammar = parsed.grammar;
    base.artist = base.artist ?? parsed.artist;
    base.album = base.album ?? parsed.album;
    base.year = base.year ?? parsed.year;
    base.label = parsed.label;
    base.catno = parsed.catno;
  }
  if (sidecar.files.length === 0) {
    // iso stubs and the like: nothing to identify until unpacked manually
    return { identification: base, needs_review: true, issues };
  }

  // Fast path step 3 — Discogs confirmation.
  let ambiguous = false;
  if (deps.discogs && base.artist && base.album) {
    const results = await deps.discogs.searchRelease({
      artist: base.artist,
      album: base.album,
      catno: base.catno ?? undefined,
    });
    if (results === null) {
      issues.push("discogs_unreachable");
    } else {
      const matches = results.filter(
        (r) => normKey(r.artist ?? "") === normKey(base.artist!) && normKey(r.album ?? "") === normKey(base.album!),
      );
      const hit = matches.length === 1 ? matches[0]! : results.length === 1 ? results[0]! : null;
      if (hit) {
        return {
          identification: {
            ...base,
            status: "fast_path",
            source: "discogs",
            release_id: hit.release_id,
            artist: hit.artist ?? base.artist,
            album: hit.album ?? base.album,
            year: hit.year ?? base.year,
            label: hit.label ?? base.label,
            catno: hit.catno ?? base.catno,
            styles: hit.styles,
            genres: hit.genres,
          },
          needs_review: false,
          issues,
        };
      }
      ambiguous = results.length > 1;
    }
  }

  // Hard path — beets shim, when fast path failed or confirmation ambiguous.
  if (deps.shim) {
    const result = await deps.shim.identify(dir);
    if ("error" in result) {
      issues.push(result.error);
    } else {
      const candidates = [...result.candidates].sort(
        (a, b) => (a.distance ?? 1) - (b.distance ?? 1),
      );
      const top = candidates[0];
      if (top && top.distance != null && top.distance <= deps.acceptDistance) {
        return {
          identification: {
            ...base,
            status: "shim",
            source: top.source,
            release_id: top.release_id,
            artist: top.artist ?? base.artist,
            album: top.album ?? base.album,
            year: top.year ?? base.year,
            label: top.label ?? base.label,
            catno: top.catno ?? base.catno,
            distance: top.distance,
          },
          needs_review: false,
          issues,
        };
      }
      if (candidates.length > 0) {
        base.candidates = candidates.slice(0, 3) as IdentCandidate[];
      }
    }
  }

  // Degraded outcomes: parse+tags without external confirmation.
  const status = base.artist && base.album && !ambiguous ? "unconfirmed" : "unidentified";
  return { identification: { ...base, status }, needs_review: true, issues };
}
