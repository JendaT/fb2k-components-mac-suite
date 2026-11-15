// Bootstrap over synthetic canonical trees. Bootstrap reads only dir names and
// file existence, so empty dirs plus tiny dummy files stand in for releases.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bootstrapTrees, type BootstrapResult } from "../src/bootstrap.ts";
import { hasVariousArtistsPrefix, isVariousArtists } from "../src/util.ts";

let tree: string;
let result: BootstrapResult;

const COLL_A = "[Collection A]";
const COLL_B = "[Collection B]";
const COLL_C = "[Collection C]";
const COMPILATION = "Compilation Title Vol.XXI-XXVIII";

/** A release dir; `discs` lists disc subdirs, each holding one dummy track. */
function release(path: string, discs: string[] = []): void {
  const dir = join(tree, path);
  mkdirSync(dir, { recursive: true });
  if (discs.length === 0) writeFileSync(join(dir, "01 - Track.flac"), new Uint8Array(4));
  for (const d of discs) {
    mkdirSync(join(dir, d), { recursive: true });
    writeFileSync(join(dir, d, "01 - Track.flac"), new Uint8Array(4));
  }
}

const cds = (n: number) => Array.from({ length: n }, (_, i) => `CD${i + 1}`);

beforeAll(() => {
  tree = mkdtempSync(join(tmpdir(), "intake-bootstrap-"));
  // Normal layout: Collection/Artist/Release[/CDn].
  release(`${COLL_A}/Artist Name/Artist Name [2011] Album Name [WEB, Comp, US, Label #CAT13]`, ["CD1", "CD2"]);
  release(
    `${COLL_A}/Artist Name/Artist Name [2012] Second Album [2CD, Comp, RM, US, Label #CAT290]`,
    ["CD1 - Disc Title", "CD2 Disc Title"],
  );
  release(`${COLL_A}/Other Artist/Other Artist [2011] Album Name (1984; Some Label; CAT01)`);
  release(`${COLL_A}/Other Artist/Other Artist [2013] Third Album [1984, Some Label]`);
  release(`${COLL_A}/Other Artist/Other Artist [2014] Fourth Album [LABEL CD 97]`);
  release(`${COLL_A}/Other Artist/Other Artist [2015] Fifth Album [WEB, FLAC]`);
  release(`${COLL_A}/Other Artist/Other Artist [2016] Sixth Album (Some Label; CAT02)`);
  // No artist level: the release sits directly under the collection, its
  // discs below it; the same release is in two collections.
  release(`${COLL_B}/${COMPILATION}`, cds(8));
  release(`${COLL_C}/${COMPILATION}`, cds(8));
  // No artist level, titled disc dirs plus a non-disc extras dir.
  release(`${COLL_B}/Box Set Title`, ["CD1 - Disc Title", "CD2 Disc Title", "Scans"]);
  // No artist level but the name parses: one release with the parsed artist.
  release(`${COLL_B}/Composer - Work`, ["CD1", "CD2"]);
  release(`${COLL_C}/Composer \u2013 Second Work`, ["CD1", "CD2"]); // en dash
  result = bootstrapTrees([{ path: tree, weight: 1 }]);
});

afterAll(() => {
  rmSync(tree, { recursive: true, force: true });
});

test("bootstrap: label map holds labels only, never years or format/descriptor/country tokens", () => {
  const keys = Object.keys(result.labels.labels).sort();
  expect(keys).toEqual(["Label", "Some Label"]);
  for (const k of keys) {
    expect(k).not.toMatch(/^\d{4}$/);
    expect(["WEB", "CD", "2CD", "7CD", "Cass", "Comp", "RM", "US", "FLAC"]).not.toContain(k);
  }
  // Discogs-style blocks: the field after format/descriptor/country is the label.
  expect(result.labels.labels["Label"]).toEqual({ [COLL_A]: 2 });
  // Year-first blocks and the plain (Label; Cat#) block.
  expect(result.labels.labels["Some Label"]).toEqual({ [COLL_A]: 3 });
});

test("bootstrap: normal artist layout counts each release under its artist", () => {
  expect(result.genre.artists["Artist Name"]).toEqual({ [COLL_A]: 2 });
  expect(result.genre.artists["Other Artist"]).toEqual({ [COLL_A]: 5 });
});

test("bootstrap: a release with disc dirs and no artist level is one release, no artist from its dir name", () => {
  const artistKeys = Object.keys(result.genre.artists).sort();
  expect(artistKeys).toEqual(["Artist Name", "Composer", "Other Artist"]);
  expect(result.genre.artists["Composer"]).toEqual({ [COLL_B]: 1, [COLL_C]: 1 });
  // A: 7 releases. B: compilation, box set, composer work. C: compilation, composer work.
  expect(result.stats.releases).toBe(12);
  expect(result.stats.collections).toBe(3);
});

test("bootstrap: disc dirs never appear in the unparsed list", () => {
  const unparsed = result.report
    .split("\n")
    .filter((l) => l.startsWith("- `"))
    .map((l) => l.slice(3, -1));
  expect(unparsed.sort()).toEqual(["Box Set Title", COMPILATION, COMPILATION]);
  expect(result.stats.unparsed).toBe(3);
});

test("bootstrap: Various Artists never becomes an artist entry; VA releases give label evidence only", () => {
  const vaTree = mkdtempSync(join(tmpdir(), "intake-bootstrap-va-"));
  const COLL = "[Collection V]";
  const flat = (path: string) => {
    mkdirSync(join(vaTree, path), { recursive: true });
    writeFileSync(join(vaTree, path, "01 - Track.flac"), new Uint8Array(4));
  };
  try {
    // VA releases in a compilations slot dir, under several spellings.
    flat(`${COLL}/[Compilations]/VA - Example Comp One (2010)`);
    flat(`${COLL}/[Compilations]/V.A. - Example Comp Two`);
    flat(`${COLL}/[Compilations]/Various Artists [2012] Example Comp Three (Synthetic Records; SYN002)`);
    flat(`${COLL}/[Compilations]/va - Example Comp Four`);
    // Scene leftover: the parsed artist is "VA Example Moments (2013) FLAC".
    flat(`${COLL}/[Compilations]/VA  Example Moments (2013) FLAC - Uploader Tag`);
    // An artist dir named VA: its releases still parse for labels.
    flat(`${COLL}/VA/VA [2014] Example Comp Five [WEB, Comp, Other Label #SYN005]`);
    // An unparseable VA-prefixed dir holding flat files (the hasFiles branch).
    flat(`${COLL}/VA  Example Nights (2015) FLAC`);
    // Real artists, one whose name merely starts with "Various ".
    flat(`${COLL}/Example Artist/Example Artist [2011] Example Album (Synthetic Records; SYN010)`);
    flat(`${COLL}/Various Example Band/Various Example Band - Example Album Two (2016)`);

    const r = bootstrapTrees([{ path: vaTree, weight: 1 }]);
    const artistKeys = Object.keys(r.genre.artists).sort();
    expect(artistKeys.filter((k) => isVariousArtists(k) || hasVariousArtistsPrefix(k))).toEqual([]);
    expect(artistKeys).toEqual(["Example Artist", "Various Example Band"]);
    expect(r.genre.artists["Various Example Band"]).toEqual({ [COLL]: 1 });
    expect(r.stats.artists).toBe(2);

    // Labels from VA release names still count: one VA + one artist release,
    // and the release under the VA artist dir.
    expect(r.labels.labels["Synthetic Records"]).toEqual({ [COLL]: 2 });
    expect(r.labels.labels["Other Label"]).toEqual({ [COLL]: 1 });

    // Every VA release still counts as a release and in the grammar table.
    expect(r.stats.releases).toBe(9);
    const grammarTotal = r.report
      .split("\n")
      .map((l) => l.match(/^\| (\w+) \| (\d+) \|$/))
      .filter((m): m is RegExpMatchArray => m !== null)
      .reduce((a, m) => a + Number(m[2]), 0);
    expect(grammarTotal).toBe(8); // all but the flat-files dir, which is not name-parsed
    expect(r.stats.unparsed).toBe(0);
  } finally {
    rmSync(vaTree, { recursive: true, force: true });
  }
});
