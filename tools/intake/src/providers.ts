// External evidence providers (doc 02). All network access lives here, is
// keyed by env credentials, and degrades to null (unavailable) — the engine
// never requires it. Tests inject fakes; nothing in the test suite touches
// the network.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { IdentCandidate } from "./types.ts";
import type { SimilarArtist } from "./assign.ts";
import { sha1Hex } from "./util.ts";

const USER_AGENT = "jl-intake/0.1 (+https://github.com/jendalen)";

export interface DiscogsSearchQuery {
  artist?: string;
  album?: string;
  catno?: string;
}

export interface DiscogsSearchResult {
  release_id: string;
  artist: string | null;
  album: string | null;
  year: string | null;
  label: string | null;
  catno: string | null;
  styles: string[];
  genres: string[];
}

export interface DiscogsProvider {
  searchRelease(q: DiscogsSearchQuery): Promise<DiscogsSearchResult[] | null>;
  artistAliases(name: string): Promise<string[] | null>;
}

export type SimilarProvider = (artist: string) => Promise<SimilarArtist[] | null>;

export type ShimResult = { candidates: IdentCandidate[] } | { error: string };

export interface ShimProvider {
  identify(dir: string): Promise<ShimResult>;
}

// ---- Discogs ---------------------------------------------------------------

export function httpDiscogs(token: string): DiscogsProvider {
  const get = async (url: string): Promise<Record<string, unknown> | null> => {
    try {
      const res = await fetch(url, {
        headers: { "User-Agent": USER_AGENT, Authorization: `Discogs token=${token}` },
        signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) return null;
      return (await res.json()) as Record<string, unknown>;
    } catch {
      return null;
    }
  };
  return {
    async searchRelease(q) {
      const params = new URLSearchParams({ type: "release", per_page: "5" });
      if (q.artist) params.set("artist", q.artist);
      if (q.album) params.set("release_title", q.album);
      if (q.catno) params.set("catno", q.catno);
      const doc = await get(`https://api.discogs.com/database/search?${params}`);
      const results = doc?.results;
      if (!Array.isArray(results)) return null;
      return results.map((r: Record<string, unknown>) => {
        const title = typeof r.title === "string" ? r.title : "";
        const dash = title.indexOf(" - ");
        return {
          release_id: String(r.id ?? ""),
          artist: dash > 0 ? title.slice(0, dash) : null,
          album: dash > 0 ? title.slice(dash + 3) : title || null,
          year: r.year != null ? String(r.year) : null,
          label: Array.isArray(r.label) && typeof r.label[0] === "string" ? r.label[0] : null,
          catno: typeof r.catno === "string" ? r.catno : null,
          styles: Array.isArray(r.style) ? r.style.filter((x): x is string => typeof x === "string") : [],
          genres: Array.isArray(r.genre) ? r.genre.filter((x): x is string => typeof x === "string") : [],
        };
      });
    },
    async artistAliases(name) {
      const search = await get(
        `https://api.discogs.com/database/search?${new URLSearchParams({ type: "artist", q: name, per_page: "1" })}`,
      );
      const first = Array.isArray(search?.results) ? (search.results[0] as Record<string, unknown>) : null;
      if (!first?.id) return null;
      const artist = await get(`https://api.discogs.com/artists/${first.id}`);
      if (!artist) return null;
      const names: string[] = [];
      for (const k of ["aliases", "groups"]) {
        const list = artist[k];
        if (Array.isArray(list)) {
          for (const a of list) if (typeof a?.name === "string") names.push(a.name);
        }
      }
      const variations = artist.namevariations;
      if (Array.isArray(variations)) for (const v of variations) if (typeof v === "string") names.push(v);
      return names;
    },
  };
}

// ---- Last.fm similar artists, cached ---------------------------------------

const SIMILAR_TTL_MS = 90 * 24 * 3600 * 1000; // 90 days per doc 02

export function cacheDir(): string {
  return process.env.INTAKE_CACHE_DIR ?? join(homedir(), ".cache", "intake");
}

/** Wrap any similar-source with the on-disk cache (deterministic in tests). */
export function cachedSimilar(fetcher: SimilarProvider, dir: string = cacheDir()): SimilarProvider {
  return async (artist) => {
    const file = join(dir, "similar", sha1Hex(artist.toLowerCase()) + ".json");
    if (existsSync(file)) {
      try {
        const doc = JSON.parse(readFileSync(file, "utf8"));
        if (Date.now() - doc.ts < SIMILAR_TTL_MS) return doc.similar as SimilarArtist[];
      } catch {
        // fall through to refetch
      }
    }
    const similar = await fetcher(artist);
    if (similar) {
      mkdirSync(join(dir, "similar"), { recursive: true });
      writeFileSync(file, JSON.stringify({ ts: Date.now(), artist, similar }));
    }
    return similar;
  };
}

export function httpLastfm(apiKey: string): SimilarProvider {
  return async (artist) => {
    try {
      const params = new URLSearchParams({
        method: "artist.getsimilar",
        artist,
        api_key: apiKey,
        format: "json",
        limit: "20",
        autocorrect: "1",
      });
      const res = await fetch(`https://ws.audioscrobbler.com/2.0/?${params}`, {
        headers: { "User-Agent": USER_AGENT },
        signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) return null;
      const doc = (await res.json()) as { similarartists?: { artist?: { name: string; match: string }[] } };
      const list = doc.similarartists?.artist;
      if (!Array.isArray(list)) return null;
      return list.map((a) => ({ name: a.name, match: parseFloat(a.match) || 0 }));
    } catch {
      return null;
    }
  };
}

// ---- beets shim ------------------------------------------------------------

export function shimCommand(): string[] {
  const env = process.env.INTAKE_BEETS_SHIM;
  if (env) return env.split(" ").filter(Boolean);
  return ["python3", join(import.meta.dir, "..", "shim", "beets_identify.py")];
}

export function subprocessShim(cmd: string[] = shimCommand()): ShimProvider {
  return {
    async identify(dir) {
      let proc: Bun.Subprocess<"ignore", "pipe", "pipe">;
      try {
        proc = Bun.spawn([...cmd, dir, "--json"], { stdin: "ignore", stdout: "pipe", stderr: "pipe" });
      } catch {
        return { error: "shim_unavailable" };
      }
      const code = await proc.exited;
      const out = await new Response(proc.stdout).text();
      if (code !== 0) {
        try {
          const doc = JSON.parse(out);
          if (typeof doc?.error === "string") return { error: doc.error };
        } catch {
          // non-JSON failure output
        }
        return { error: `shim_exit_${code}` };
      }
      try {
        const doc = JSON.parse(out);
        if (Array.isArray(doc?.candidates)) return { candidates: doc.candidates as IdentCandidate[] };
        return { error: "shim_bad_output" };
      } catch {
        return { error: "shim_bad_output" };
      }
    },
  };
}

// ---- env-driven factory -----------------------------------------------------

export interface Providers {
  discogs: DiscogsProvider | null;
  similar: SimilarProvider | null;
  shim: ShimProvider | null;
}

export function buildProviders(): Providers {
  const discogsToken = process.env.DISCOGS_TOKEN;
  const lastfmKey = process.env.LASTFM_API_KEY;
  return {
    discogs: discogsToken ? httpDiscogs(discogsToken) : null,
    similar: lastfmKey ? cachedSimilar(httpLastfm(lastfmKey)) : null,
    shim: subprocessShim(),
  };
}
