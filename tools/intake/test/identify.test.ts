// Identify stage tests: fast path with Discogs confirmation, shim hard path
// (fake subprocess), offline degradation. No network.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { identifyRoot, type IdentifyDeps } from "../src/identify.ts";
import { subprocessShim } from "../src/providers.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import type { DiscogsProvider, DiscogsSearchResult } from "../src/providers.ts";
import { cmdScan } from "../src/commands.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const FAKE_SHIM = join(import.meta.dir, "fakes", "fake-shim.ts");

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
