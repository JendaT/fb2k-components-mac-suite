// Identify stage tests: fast path with Discogs confirmation, shim hard path
// (fake subprocess), offline degradation. No network.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { identifyRoot, type IdentifyDeps } from "../src/identify.ts";
import { subprocessShim, type ShimProvider, type ShimResult } from "../src/providers.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import type { DiscogsProvider, DiscogsSearchResult } from "../src/providers.ts";
import { cmdScan } from "../src/commands.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const FAKE_SHIM = join(import.meta.dir, "fakes", "fake-shim.ts");
const SHIM = join(import.meta.dir, "..", "shim", "beets_identify.py");
const STUBS = join(import.meta.dir, "fakes");

let corpus: Corpus;
let pollenDir: string;
let pollen: Sidecar;

beforeAll(async () => {
  corpus = setupCorpus();
  await cmdScan([], { json: true, dryRun: false, force: false, all: true, filters: {} });
  pollenDir = join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  pollen = readSidecar(join(pollenDir, ".intake.json"))!;
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

function deps(partial: Partial<IdentifyDeps>): IdentifyDeps {
  return { discogs: null, shim: null, acceptDistance: 0.15, now: () => new Date(), ...partial };
}

function discogsReturning(results: DiscogsSearchResult[] | null): DiscogsProvider {
  return {
    searchRelease: async () => results,
    artistAliases: async () => null,
  };
}

const POLLEN_HIT: DiscogsSearchResult = {
  release_id: "3579221",
  artist: "Aes Dana",
  album: "Pollen",
  year: "2012",
  label: "Ultimae Records",
  catno: "inre042",
  styles: ["Downtempo", "Ambient"],
  genres: ["Electronic"],
};

test("fast path: folder grammar + tags confirmed by Discogs", async () => {
  const out = await identifyRoot(pollenDir, pollen, { ...deps({ discogs: discogsReturning([POLLEN_HIT]) }) });
  expect(out.identification.status).toBe("fast_path");
  expect(out.identification.source).toBe("discogs");
  expect(out.identification.release_id).toBe("3579221");
  expect(out.identification.grammar).toBe("bracket_year_paren_label");
  expect(out.identification.label).toBe("Ultimae Records");
  expect(out.identification.catno).toBe("inre042");
  expect(out.identification.styles).toEqual(["Downtempo", "Ambient"]);
  expect(out.needs_review).toBe(false);
});

test("offline (no providers): unconfirmed with merged parse+tags", async () => {
  const out = await identifyRoot(pollenDir, pollen, deps({}));
  expect(out.identification.status).toBe("unconfirmed");
  expect(out.identification.artist).toBe("Aes Dana");
  expect(out.identification.album).toBe("Pollen");
  expect(out.identification.year).toBe("2012");
  expect(out.identification.label).toBe("Ultimae Records"); // folder wins where tags lack
  expect(out.needs_review).toBe(true);
});

test("shim hard path: close candidate accepted (distance <= 0.15)", async () => {
  const prev = process.env.FAKE_SHIM_MODE;
  process.env.FAKE_SHIM_MODE = "match";
  try {
    const shim = subprocessShim(["bun", FAKE_SHIM]);
    const out = await identifyRoot(pollenDir, pollen, deps({ shim }));
    expect(out.identification.status).toBe("shim");
    expect(out.identification.distance).toBe(0.07);
    expect(out.identification.album).toBe("Derelicts"); // shim result is canonical
    expect(out.needs_review).toBe(false);
  } finally {
    process.env.FAKE_SHIM_MODE = prev;
  }
});

test("shim hard path: only distant candidates -> top-3 attached, needs_review", async () => {
  const prev = process.env.FAKE_SHIM_MODE;
  process.env.FAKE_SHIM_MODE = "far";
  try {
    const shim = subprocessShim(["bun", FAKE_SHIM]);
    const out = await identifyRoot(pollenDir, pollen, deps({ shim }));
    expect(out.identification.status).toBe("unconfirmed"); // parse+tags still present
    expect(out.identification.candidates?.length).toBe(2);
    expect(out.identification.candidates![0]!.distance).toBe(0.38);
    expect(out.needs_review).toBe(true);
  } finally {
    process.env.FAKE_SHIM_MODE = prev;
  }
});

test("shim unavailable: degrades with issue recorded", async () => {
  const prev = process.env.FAKE_SHIM_MODE;
  delete process.env.FAKE_SHIM_MODE; // default mode = unavailable
  try {
    const shim = subprocessShim(["bun", FAKE_SHIM]);
    const out = await identifyRoot(pollenDir, pollen, deps({ shim }));
    expect(out.identification.status).toBe("unconfirmed");
    expect(out.issues).toContain("beets_unavailable");
  } finally {
    if (prev !== undefined) process.env.FAKE_SHIM_MODE = prev;
  }
});

test("ambiguous Discogs results fall through to candidates/needs_review", async () => {
  const other = { ...POLLEN_HIT, release_id: "111", album: "Pollen (Remastered)" };
  const anotherArtist = { ...POLLEN_HIT, release_id: "222", artist: "Someone Else" };
  // Two results, neither an exact single match on artist+album -> ambiguous.
  const out = await identifyRoot(pollenDir, pollen, deps({ discogs: discogsReturning([other, anotherArtist]) }));
  expect(out.identification.status).toBe("unconfirmed");
  expect(out.identification.candidates?.map((c) => c.release_id)).toEqual(["111", "222"]);
  expect(out.needs_review).toBe(true);
});

test("iso stub (no files): unidentified, needs_review", async () => {
  const isoSidecarPath = join(corpus.income, "downloads");
  const names = readdirSync(isoSidecarPath).filter((n) => /^\.intake\..*\.json$/.test(n));
  const iso = readSidecar(join(isoSidecarPath, names[0]!))!;
  const out = await identifyRoot(isoSidecarPath, iso, deps({ discogs: discogsReturning([POLLEN_HIT]) }));
  expect(out.identification.status).toBe("unidentified");
  expect(out.needs_review).toBe(true);
});

// ---- what the shim is given: the root's own audio files ---------------------

interface ShimCall {
  dir: string;
  files: string[] | undefined;
  result: ShimResult;
}

/** Wraps a shim (default: one that finds nothing) and records every call. */
function recording(inner: ShimProvider = { identify: async () => ({ candidates: [] }) }) {
  const calls: ShimCall[] = [];
  const shim: ShimProvider = {
    identify: async (dir, files) => {
      const result = await inner.identify(dir, files);
      calls.push({ dir, files, result });
      return result;
    },
  };
  return { shim, calls };
}

const VA_FILES = [
  "cd1/01 Artist One - First Song.mp3",
  "cd1/02 Artist Two - Second Song.mp3",
  "cd1/03 Artist Three - Third Song.mp3",
  "cd1/04 Artist Four - Fourth Song.mp3",
  "cd2/01 Artist Five - Fifth Song.mp3",
  "cd2/02 Artist Two - Sixth Song.mp3",
  "cd2/03 Artist Six - Seventh Song.mp3",
  "cd2/04 Artist Seven - Eighth Song.mp3",
  "cd2/05 Artist Eight - Ninth Song.mp3",
];

test("multi-disc root: the real shim gets both discs' audio and nothing else (stub beets)", async () => {
  // Audio only in cd1/ and cd2/; Artwork/cover.pdf and contest01.htm at the top.
  const dir = join(corpus.income, "todo", "VA_-_Example_Compilation_(Web_Version_2CD)");
  const va = readSidecar(join(dir, ".intake.json"))!;
  const prev = { PYTHONPATH: process.env.PYTHONPATH, PYTHONDONTWRITEBYTECODE: process.env.PYTHONDONTWRITEBYTECODE };
  process.env.PYTHONPATH = join(STUBS, "beets-1.6");
  process.env.PYTHONDONTWRITEBYTECODE = "1";
  try {
    const { shim, calls } = recording(subprocessShim(["python3", "-S", SHIM]));
    const out = await identifyRoot(dir, va, deps({ shim }));
    expect(calls).toHaveLength(1);
    expect(calls[0]!.dir).toBe(dir);
    expect(calls[0]!.files).toEqual(VA_FILES);
    // What reached beets: the stub maps every item it was given.
    const result = calls[0]!.result;
    if (!("candidates" in result)) throw new Error(`shim failed: ${result.error}`);
    expect(Object.keys(result.candidates[0]!.track_mapping!).sort()).toEqual(VA_FILES);
    expect(out.identification.status).toBe("shim");
    expect(out.issues).toEqual([]);
  } finally {
    for (const [k, v] of Object.entries(prev)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
});

test("the shim never gets a quality shadow", async () => {
  const dir = join(corpus.income, "todo", "Ott - Blumenkraft (2003)");
  const ott = readSidecar(join(dir, ".intake.json"))!;
  expect(ott.files.filter((f) => f.quality_shadow).map((f) => f.path)).toEqual([
    "01 - Jack's Cheese and Bread Snack.mp3",
    "02 - Splitting an Atom.mp3",
    "03 - Smoked Glass and Chrome.mp3",
  ]);
  const { shim, calls } = recording();
  await identifyRoot(dir, ott, deps({ shim }));
  expect(calls.map((c) => c.files)).toEqual([
    ["01 - Jack's Cheese and Bread Snack.flac", "02 - Splitting an Atom.flac", "03 - Smoked Glass and Chrome.flac"],
  ]);
});

test("virtual roots: each shim call carries only that root's own cluster", async () => {
  // Three virtual roots share one dir: two clusters and one single.
  const dir = join(corpus.income, "slsk", "random_mix");
  const names = readdirSync(dir).filter((n) => /^\.intake\..*\.json$/.test(n)).sort();
  const roots = names.map((n) => readSidecar(join(dir, n))!);
  expect(roots.map((r) => r.virtual)).toEqual([true, true, true]);
  const { shim, calls } = recording();
  for (const r of roots) await identifyRoot(dir, r, deps({ shim }));
  expect(calls.map((c) => c.dir)).toEqual([dir, dir, dir]);
  expect(calls.map((c) => c.files)).toEqual([
    ["zero_cult_breathe.mp3"],
    ["emantra_1_arcana.flac", "emantra_2_nocturne.flac"],
    ["koan_1_argonautica.mp3", "koan_2_silent_hero.mp3", "koan_3_athena.mp3"],
  ]);
});
