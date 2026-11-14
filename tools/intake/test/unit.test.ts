import { expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DEFAULT_CONFIG, incomeFor, loadConfig, loadIncome } from "../src/config.ts";
import { albumFromTags, parseDirName } from "../src/naming.ts";
import { parseFilename } from "../src/tags.ts";
import {
  DISC_DIR_RE, decodeDiscInTrack, discNumberFromDirName, isJunkFile, isVariousArtists, mapLimit, normAlbum, normKey,
} from "../src/util.ts";

test("naming: full grammars score 1.0", () => {
  const a = parseDirName("Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  expect(a).toMatchObject({ grammar: "bracket_year_paren_label", score: 1, artist: "Aes Dana", album: "Pollen", year: "2012", label: "Ultimae Records", catno: "inre042" });
  const b = parseDirName("Asura [2003] Lost Eden [Ultimae, inre010]");
  expect(b).toMatchObject({ grammar: "bracket_year_bracket_label", score: 1, label: "Ultimae", catno: "inre010" });
  const c = parseDirName("Koan-Condemned-(MKL033)-WEB-2016-KOAN");
  expect(c).toMatchObject({ grammar: "scene", score: 1, artist: "Koan", album: "Condemned", catno: "MKL033", year: "2016" });
});

test("naming: partial grammars score lower", () => {
  expect(parseDirName("Sync24 [2024] Omnimotion Remixed")).toMatchObject({ grammar: "bracket_year", score: 0.75 });
  expect(parseDirName("Ott - Blumenkraft (2003)")).toMatchObject({ grammar: "dash_year", score: 0.75, artist: "Ott", album: "Blumenkraft" });
  expect(parseDirName("Solar Fields - Movements")).toMatchObject({ grammar: "dash", score: 0.5 });
  expect(parseDirName("random_mix")).toBeNull();
});

test("naming: label blocks skip years and format/descriptor/country tokens", () => {
  // Year-first blocks: the year is never the label.
  expect(parseDirName("Artist Name [2011] Album Name (1984; Some Label; CAT01)")).toMatchObject({
    grammar: "bracket_year_paren_label", album: "Album Name", year: "2011", label: "Some Label", catno: "CAT01",
  });
  expect(parseDirName("Artist Name [2011] Album Name [1984, Some Label]")).toMatchObject({
    grammar: "bracket_year_bracket_label", album: "Album Name", label: "Some Label", catno: null,
  });
  // Plain blocks are unchanged.
  expect(parseDirName("Artist Name [2011] Album Name (Some Label; CAT01)")).toMatchObject({
    label: "Some Label", catno: "CAT01",
  });
  expect(parseDirName("Artist Name [2011] Album Name [Some Label, CAT01]")).toMatchObject({
    label: "Some Label", catno: "CAT01",
  });
  // Discogs-style blocks: format, descriptors, country, then "Label #CAT".
  expect(parseDirName("Artist Name [2011] Album Name [WEB, Comp, US, Label #CAT13]")).toMatchObject({
    grammar: "bracket_year_bracket_label", album: "Album Name", label: "Label", catno: "CAT13",
  });
  expect(parseDirName("Artist Name [2011] Album Name [2CD, Comp, RM, US, Label #CAT290]")).toMatchObject({
    label: "Label", catno: "CAT290",
  });
  expect(parseDirName("Artist Name [2011] Album Name [7CD, Ltd, Europe, Some Label]")).toMatchObject({
    label: "Some Label", catno: null,
  });
  expect(parseDirName("Artist Name [2011] Album Name (Cass; Some Label; CAT01)")).toMatchObject({
    label: "Some Label", catno: "CAT01",
  });
  // Nothing but tokens: no label at all.
  expect(parseDirName("Artist Name [2011] Album Name [WEB, FLAC]")).toMatchObject({
    grammar: "bracket_year_bracket_label", album: "Album Name", label: null, catno: null,
  });
  expect(parseDirName("Artist Name [2011] Album Name (1984; CD)")).toMatchObject({ label: null, catno: null });
  // Single-field block: cannot be split safely, stays in the title.
  expect(parseDirName("Artist Name [2011] Album Name [LABEL CD 97]")).toMatchObject({
    grammar: "bracket_year", album: "Album Name [LABEL CD 97]", label: null, catno: null,
  });
});

test("naming: en/em dash separators, paren-year prefix, whitespace collapse", () => {
  expect(parseDirName("Artist Name \u2013 Album Name")).toMatchObject({
    grammar: "dash", artist: "Artist Name", album: "Album Name", year: null,
  });
  expect(parseDirName("Artist Name \u2013 Album Name (2011)")).toMatchObject({
    grammar: "dash_year", artist: "Artist Name", album: "Album Name", year: "2011",
  });
  expect(parseDirName("Artist Name \u2014 Album Name")).toMatchObject({ grammar: "dash", artist: "Artist Name", album: "Album Name" });
  // Discography-dump shapes: (YYYY) Artist <dash> Album.
  expect(parseDirName("(2010) Artist \u2013 Album")).toMatchObject({
    grammar: "paren_year_dash", score: 0.75, artist: "Artist", album: "Album", year: "2010",
  });
  expect(parseDirName("(2009) Artist A & Artist B \u2013 Album")).toMatchObject({
    grammar: "paren_year_dash", artist: "Artist A & Artist B", album: "Album", year: "2009",
  });
  expect(parseDirName("(2010) Artist \u2013 Title A  Title B")).toMatchObject({ artist: "Artist", album: "Title A Title B" });
  expect(parseDirName("(2010) Artist - Album")).toMatchObject({ grammar: "paren_year_dash", artist: "Artist" });
  // No artist in the name: loose album + year.
  expect(parseDirName("(2000) Album Title")).toMatchObject({
    grammar: "paren_year", score: 0.5, artist: null, album: "Album Title", year: "2000",
  });
  // Whitespace runs collapse in every grammar.
  expect(parseDirName("Artist  Name [2011] Album   Name")).toMatchObject({ artist: "Artist Name", album: "Album Name" });
});

test("naming: underscore-spaced VA dir and scene names", () => {
  expect(parseDirName("VA_-_Compilation_Title_(Web_Version_2CD)")).toMatchObject({
    grammar: "dash", artist: "VA", album: "Compilation Title (Web Version 2CD)",
  });
  expect(parseDirName("VA_-_Compilation_Title_(2011)")).toMatchObject({
    grammar: "dash_year", artist: "VA", album: "Compilation Title", year: "2011",
  });
  // Scene: "-" separates fields, "_" separates words; catno optional.
  expect(parseDirName("Artist_Name-Album-WEB-2011-GROUP")).toMatchObject({
    grammar: "scene", artist: "Artist Name", album: "Album", year: "2011", catno: null,
  });
  expect(parseDirName("Artist_Name-Album_Title-WEB-2011-eXaMpLeGrOuP")).toMatchObject({
    grammar: "scene", artist: "Artist Name", album: "Album Title", year: "2011", catno: null,
  });
  expect(parseDirName("Artist_Name-Album-(CAT123)-WEB-2011-GROUP")).toMatchObject({
    grammar: "scene", artist: "Artist Name", album: "Album", year: "2011", catno: "CAT123",
  });
  expect(parseDirName("Artist_Name-Album-(CAT123)-WEB-FLAC-2011-GROUP")).toMatchObject({
    grammar: "scene", album: "Album", catno: "CAT123", year: "2011",
  });
  // A scene name containing "_-_" stays a scene parse.
  expect(parseDirName("Artist_Name_-_Album_Title-WEB-2011-GROUP")).toMatchObject({
    grammar: "scene", artist: "Artist Name", album: "Album Title", year: "2011",
  });
});

test("naming: shapes that keep their current parse", () => {
  for (const name of [
    "Artist Name-Album Name", // unspaced hyphen
    "Artist_Name-Album_Title", // underscores without "_-_", no scene tail
    "Collection Title (1997)", // year suffix without artist
    "(2000)",
    "random_mix",
  ]) {
    expect(parseDirName(name)).toBeNull();
  }
  expect(parseDirName("First-Second Name - Album")).toMatchObject({ grammar: "dash", artist: "First-Second Name", album: "Album" });
  expect(parseDirName("Artist Name - Album Name (2011) [FLAC]")).toMatchObject({ grammar: "dash_year", album: "Album Name", year: "2011" });
  expect(parseDirName("Artist Name [2011] Album - Part Two")).toMatchObject({ grammar: "bracket_year", album: "Album - Part Two" });
});

test("album from tags: a trailing source token goes only when the dir parse agrees", () => {
  const scene = parseDirName("Artist_Name-Album-(CAT123)-WEB-2011-GROUP");
  expect(albumFromTags("Album WEB", scene)).toBe("Album");
  expect(albumFromTags("Album", scene)).toBe("Album");
  expect(albumFromTags("Album FLAC", parseDirName("Artist Name - Album"))).toBe("Album");
  // Disagreeing parse, no parse, or the token is part of the dir's title too.
  expect(albumFromTags("Album WEB", parseDirName("Artist_Name-Other_Album-WEB-2011-GROUP"))).toBe("Album WEB");
  expect(albumFromTags("Album WEB", null)).toBe("Album WEB");
  expect(albumFromTags("Spider Web", parseDirName("Artist Name - Spider Web"))).toBe("Spider Web");
  expect(albumFromTags("Album WEB Edition", scene)).toBe("Album WEB Edition");
});

test("filename fallback parse", () => {
  expect(parseFilename("01 - Iliona.flac")).toEqual({ tracknumber: 1, artist: null, title: "Iliona" });
  expect(parseFilename("07. Some Track.mp3")).toEqual({ tracknumber: 7, artist: null, title: "Some Track" });
  expect(parseFilename("03 - Aes Dana - Signs.flac")).toEqual({ tracknumber: 3, artist: "Aes Dana", title: "Signs" });
  expect(parseFilename("Zero Cult - Breathe.mp3")).toEqual({ tracknumber: null, artist: "Zero Cult", title: "Breathe" });
});

test("normalization and disc patterns", () => {
  expect(normKey("  Solar  FIELDS ")).toBe("solar fields");
  expect(normKey("Étoile")).toBe("etoile");
  expect(normAlbum("Lost Eden CD1")).toBe("lost eden");
  expect(normAlbum("Lost Eden (Disc 2)")).toBe("lost eden");
  for (const d of ["CD1", "cd 2", "Disc 1", "disk-2", "Side A", "LP 1", "vinyl_1"]) {
    expect(DISC_DIR_RE.test(d)).toBe(true);
  }
  expect(DISC_DIR_RE.test("Aes Dana [2012] Pollen")).toBe(false);
  expect(discNumberFromDirName("CD2")).toBe(2);
  expect(discNumberFromDirName("Disc 07")).toBe(7);
  expect(discNumberFromDirName("Side A")).toBeNull();
});

test("disc dirs: titled forms after a numeric index match, other words do not", () => {
  const titled: [string, number][] = [
    ["CD1 - Disc Title", 1],
    ["CD1 Disc Title", 1],
    ["Disc 2 - X", 2],
    ["CD2 \u2013 Disc Title", 2],
    ["CD3_Disc_Title", 3],
    ["CD1 (Disc Title)", 1],
    ["cd10", 10],
    ["Disc One", 1],
  ];
  for (const [name, n] of titled) {
    expect(DISC_DIR_RE.test(name)).toBe(true);
    expect(discNumberFromDirName(name)).toBe(n);
  }
  for (const name of [
    "Disk Jockey", "Side Projects", "Discography", "CDs", "LPs", "Sideline", "Vinyl Days",
    "Disc A Title", "Disc 1984", "CD", "Artist Name - Album Name", "Compilation Title Vol.XXI-XXVIII",
  ]) {
    expect(DISC_DIR_RE.test(name)).toBe(false);
    expect(discNumberFromDirName(name)).toBeNull();
  }
});

test("disc in track number: 1xx/2xx decode to disc + track", () => {
  expect(decodeDiscInTrack([101, 102, 103, 201, 202])).toEqual([
    { disc: 1, track: 1 }, { disc: 1, track: 2 }, { disc: 1, track: 3 }, { disc: 2, track: 1 }, { disc: 2, track: 2 },
  ]);
  expect(decodeDiscInTrack([201, 101, 112])).toEqual([{ disc: 2, track: 1 }, { disc: 1, track: 1 }, { disc: 1, track: 12 }]);
  expect(decodeDiscInTrack([101, 102])).toEqual([{ disc: 1, track: 1 }, { disc: 1, track: 2 }]); // one disc
});

test("disc in track number: plain, mixed and odd numberings stay untouched", () => {
  expect(decodeDiscInTrack([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])).toBeNull();
  expect(decodeDiscInTrack([101, 102, 3, 4])).toBeNull(); // mixed 1xx and plain
  expect(decodeDiscInTrack([101, 102, null])).toBeNull(); // a file without a track number
  expect(decodeDiscInTrack([201, 202])).toBeNull(); // no disc 1
  expect(decodeDiscInTrack([101, 301])).toBeNull(); // gap: disc 2 missing
  expect(decodeDiscInTrack([100, 101])).toBeNull(); // x00 is not a position
  expect(decodeDiscInTrack([])).toBeNull();
});

test("various artists names", () => {
  for (const n of ["Various Artists", "various artists", "Various", "VA", "V.A.", "V/A", "v. a."]) {
    expect(isVariousArtists(n)).toBe(true);
  }
  for (const n of [null, "", "Artist One", "Vanessa", "Various Artists Tribute Band"]) {
    expect(isVariousArtists(n)).toBe(false);
  }
});

test("junk detection", () => {
  expect(isJunkFile(".DS_Store")).toBe(true);
  expect(isJunkFile("._01 - track.flac")).toBe(true);
  expect(isJunkFile("Thumbs.db")).toBe(true);
  expect(isJunkFile("01 - track.flac")).toBe(false);
});

test("config: structure.yaml overrides merge over defaults", () => {
  const dir = mkdtempSync(join(tmpdir(), "intake-rules-"));
  try {
    writeFileSync(
      join(dir, "structure.yaml"),
      "resolver:\n  weights:\n    purity: 0.5\n  thresholds:\n    resolved: 0.9\n  lossy_tolerance_kbps: 200\n",
    );
    const cfg = loadConfig(dir);
    expect(cfg.weights.purity).toBe(0.5);
    expect(cfg.weights.seq).toBe(DEFAULT_CONFIG.weights.seq); // untouched default
    expect(cfg.thresholds.resolved).toBe(0.9);
    expect(cfg.thresholds.review).toBe(DEFAULT_CONFIG.thresholds.review);
    expect(cfg.lossy_tolerance_kbps).toBe(200);
    // Defaults object must not have been mutated by the merge.
    expect(DEFAULT_CONFIG.weights.purity).toBe(0.35);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("config: missing rules dir yields defaults and no income", () => {
  expect(loadConfig(null)).toEqual(DEFAULT_CONFIG);
  expect(loadIncome(null)).toEqual([]);
});

test("income: relative paths resolve against rules dir; longest match wins", () => {
  const dir = mkdtempSync(join(tmpdir(), "intake-rules-"));
  try {
    writeFileSync(
      join(dir, "income.yaml"),
      "income:\n  - name: a\n    path: ../inc\n    source_type: web\n  - name: b\n    path: ../inc/nested\n    source_type: soulseek\n",
    );
    const income = loadIncome(dir);
    expect(income.length).toBe(2);
    expect(income[0]!.path).toBe(join(dir, "..", "inc"));
    const hit = incomeFor(join(dir, "..", "inc", "nested", "x"), income);
    expect(hit?.name).toBe("b");
    expect(incomeFor("/somewhere/else", income)).toBeNull();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("mapLimit: order preserved, concurrency bounded, rejections propagate", async () => {
  const order: number[] = [];
  let inFlight = 0;
  let peak = 0;
  const out = await mapLimit([10, 3, 7, 1, 5, 2], 2, async (ms, i) => {
    inFlight++;
    peak = Math.max(peak, inFlight);
    await Bun.sleep(ms);
    inFlight--;
    order.push(i);
    return `${i}:${ms}`;
  });
  // Results follow the input, not completion order.
  expect(out).toEqual(["0:10", "1:3", "2:7", "3:1", "4:5", "5:2"]);
  expect(order).not.toEqual([0, 1, 2, 3, 4, 5]); // work really did interleave
  expect(peak).toBeLessThanOrEqual(2);

  expect(await mapLimit([], 4, async () => 1)).toEqual([]);
  expect(
    mapLimit([1, 2], 2, async (n) => {
      if (n === 2) throw new Error("boom");
      return n;
    }),
  ).rejects.toThrow("boom");
});
