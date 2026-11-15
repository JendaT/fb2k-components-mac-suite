// Library layout for new placements (doc 02 "Library layout and credit rules
// (amendment 003)"): the pure decision from plain collection listings.
// Synthetic names only.

import { expect, test } from "bun:test";
import { existingSlotDir, isBracketedDir, libraryLayout, type CollectionListing } from "../src/layout.ts";

const ARTIST = "Example Artist";
const listing = (dirs: string[] | null, releases: string[] | null = null): CollectionListing => ({ dirs, releases });

test("no collection dir, or an empty one: [Releases]", () => {
  for (const l of [listing(null), listing([])]) {
    expect(libraryLayout(ARTIST, l)).toEqual({ structure_slot: "releases", parent: "[Releases]", restructure_candidates: [] });
  }
});

test("an existing artist dir is the target, with its on-disk spelling", () => {
  const exact = libraryLayout(ARTIST, listing(["Another Artist", ARTIST, "[Releases]"]));
  expect(exact).toEqual({ structure_slot: "artist", parent: ARTIST, restructure_candidates: [] });

  // Case and diacritic variants match the map-key normalization; the dir on
  // disk is reused rather than a near-duplicate created.
  expect(libraryLayout(ARTIST, listing(["EXAMPLE ARTIST"])).parent).toBe("EXAMPLE ARTIST");
  expect(libraryLayout("Exámple Ártist", listing(["example artist"])).parent).toBe("example artist");
  expect(libraryLayout("example  artist", listing(["Éxample Artist"]))).toEqual({
    structure_slot: "artist", parent: "Éxample Artist", restructure_candidates: [],
  });
  // Both spellings on a case-sensitive volume: the exact one wins.
  expect(libraryLayout(ARTIST, listing(["EXAMPLE ARTIST", ARTIST])).parent).toBe(ARTIST);
  // A name with a path separator matches the dir intake writes for it.
  expect(libraryLayout("Example/Artist", listing(["Example-Artist"]))).toEqual({
    structure_slot: "artist", parent: "Example-Artist", restructure_candidates: [],
  });
});

test("artist dir wins over loose and [Releases] releases; none of them is reported", () => {
  const l = listing(
    ["[Releases]", "example artist", `${ARTIST} - Loose Album (2015)`],
    [`${ARTIST} [2019] Old Album`],
  );
  expect(libraryLayout(ARTIST, l)).toEqual({ structure_slot: "artist", parent: "example artist", restructure_candidates: [] });
});

test("artist only in [releases] (lower case): new artist folder, release reported", () => {
  const l = listing(["[releases]", "[compilations]"], [`${ARTIST} [2019] Old Album (Example Label; EX001)`, "Another Artist [2018] X"]);
  expect(libraryLayout("example artist", l)).toEqual({
    structure_slot: "artist",
    parent: "example artist", // the input spelling: no artist dir exists yet
    restructure_candidates: [`[releases]/${ARTIST} [2019] Old Album (Example Label; EX001)`],
  });
});

test("artist only loose in the collection (old flat layout): artist folder, releases reported", () => {
  const l = listing(["Another Artist - Other (2010)", `${ARTIST} - Loose Album (2015)`, `(2012) ${ARTIST} - Early`], null);
  expect(libraryLayout(ARTIST, l)).toEqual({
    structure_slot: "artist",
    parent: ARTIST,
    restructure_candidates: [`(2012) ${ARTIST} - Early`, `${ARTIST} - Loose Album (2015)`],
  });
});

test("loose and [Releases] releases are reported together, sorted", () => {
  const l = listing([`${ARTIST} - Loose Album (2015)`, "[Releases]"], [`${ARTIST} [2019] Old Album`]);
  expect(libraryLayout(ARTIST, l).restructure_candidates).toEqual([
    `${ARTIST} - Loose Album (2015)`,
    `[Releases]/${ARTIST} [2019] Old Album`,
  ]);
});

test("a release only in another bracketed dir does not count: [Releases]", () => {
  // [Best Of] is a curated selection: never a target, and its releases are
  // not read (readCollection lists only the collection and [Releases]).
  const l = listing(["[Best Of]"]);
  expect(libraryLayout(ARTIST, l)).toEqual({ structure_slot: "releases", parent: "[Releases]", restructure_candidates: [] });
});

test("other artists' releases do not count: [Releases]", () => {
  const l = listing(["Another Artist", "Another Artist - Loose (2011)", "[Releases]"], ["Third Artist [2020] Y", `${ARTIST}s [2020] Z`]);
  expect(libraryLayout(ARTIST, l)).toEqual({ structure_slot: "releases", parent: "[Releases]", restructure_candidates: [] });
});

test("hidden and junk dirs never count", () => {
  const l = listing([`.${ARTIST}`, ".intake-tmp-itk_00000000", "@eaDir"]);
  expect(libraryLayout(ARTIST, l).structure_slot).toBe("releases");
  expect(libraryLayout("@eaDir", listing(["@eaDir"])).structure_slot).toBe("releases");
});

test("an existing [releases] dir is reused for the slot whatever its case", () => {
  for (const slot of ["[releases]", "[RELEASES]", "[Releases]"]) {
    expect(libraryLayout(ARTIST, listing(["Another Artist", slot], []))).toEqual({
      structure_slot: "releases", parent: slot, restructure_candidates: [],
    });
  }
});

test("Various Artists: [Compilations], existing [compilations] reused, no artist lookup", () => {
  for (const va of ["Various Artists", "VA", "V/A"]) {
    expect(libraryLayout(va, listing(null))).toEqual({ structure_slot: "compilations", parent: "[Compilations]", restructure_candidates: [] });
    // A dir named like the credit is not an artist dir for a compilation.
    expect(libraryLayout(va, listing(["[compilations]", va, "[Releases]"], [`${va} - Old Comp (2001)`]))).toEqual({
      structure_slot: "compilations", parent: "[compilations]", restructure_candidates: [],
    });
  }
});

test("slot dir and bracket helpers", () => {
  expect(existingSlotDir(null, "[Releases]")).toBeNull();
  expect(existingSlotDir(["[Best Of]", "[releases]"], "[Releases]")).toBe("[releases]");
  expect(existingSlotDir(["[Releases] old"], "[Releases]")).toBeNull();
  expect(isBracketedDir("[Best Of]")).toBe(true);
  expect(isBracketedDir(`${ARTIST} [2019] Old Album`)).toBe(false);
  expect(isBracketedDir("[2019] Old Album")).toBe(false);
});
