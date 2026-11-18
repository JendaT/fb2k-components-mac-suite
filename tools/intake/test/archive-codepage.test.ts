// Zips whose entry names are raw Windows code-page bytes (UTF-8 flag unset,
// not valid UTF-8): the names are decoded with the code page that scores best
// of cp437, cp852, cp1252 and cp1250 and land as UTF-8. Real-world shapes
// (names here are synthetic):
//   "El B\xfaho [2021] Natura sonora [FLAC]/01  Sierra Nevada de Santa Marta.flac"
// where 0xFA is "u acute" in cp1252, and an OEM one whose track
// "Bia\x88owie\xBEa" is "Białowieża" in cp852 ("Biaêowie╛a" in cp437). Also
// UTF-8 names from Windows tools, which macOS's unzip cannot write: every zip
// with a non-ASCII name goes to 7-Zip. Zips are built in the test with exact
// name bytes (test/zipbuild.ts); member data are fixture FLACs, so the result
// also resolves.

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdScan, type ScanBlock } from "../src/commands.ts";
import { loadIncomeConfig } from "../src/config.ts";
import { readSidecar } from "../src/sidecar.ts";
import { isSidecarName } from "../src/util.ts";
import {
  chooseCodePage, codePagePenalties, decodeCodePage, needsCodePage, readCentralDirectory, tieOrder,
} from "../src/zipnames.ts";
import { FIXTURES, setupCorpus, type Corpus } from "./helpers.ts";
import { buildZip, rawName, type ZipEntry } from "./zipbuild.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const SRC_ALBUM = join(FIXTURES, "income", "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
const FLACS = ["01 - Iliona.flac", "02 - Signs.flac", "03 - Adonai.flac"].map(
  (t) => new Uint8Array(readFileSync(join(SRC_ALBUM, t))),
);

let corpus: Corpus;
let income: string;
const opts = { json: true, dryRun: false, force: false, all: false, filters: {} };

/** income.yaml with the one income folder `arc`, plus any top-level lines (e.g. `archive_code_pages`). */
function writeIncome(...topLevel: string[]): void {
  writeFileSync(
    join(corpus.rules, "income.yaml"),
    [...topLevel, "income:", "  - name: arc", `    path: ${income}`, "    source_type: web", ""].join("\n"),
  );
}

beforeAll(() => {
  corpus = setupCorpus();
  income = join(corpus.dir, "arc");
});

beforeEach(() => {
  writeIncome();
  rmSync(income, { recursive: true, force: true });
  mkdirSync(income, { recursive: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

/** Every path under dir (files and dirs, relative, NFC), failing on any name that is not valid UTF-8. */
function utf8Tree(dir: string): string[] {
  const out: string[] = [];
  const strict = new TextDecoder("utf-8", { fatal: true });
  const visit = (abs: Buffer, rel: string) => {
    for (const raw of readdirSync(abs, { encoding: "buffer" })) {
      const name = strict.decode(raw); // throws on invalid UTF-8
      const r = rel ? `${rel}/${name.normalize("NFC")}` : name.normalize("NFC");
      out.push(r);
      const child = Buffer.concat([abs, Buffer.from("/"), raw]);
      if (lstatSync(child).isDirectory()) visit(child, r);
    }
  };
  visit(Buffer.from(dir), "");
  return out.sort();
}

function cd(entries: ZipEntry[], comment?: Uint8Array) {
  const path = join(income, "probe.zip");
  writeFileSync(path, buildZip(entries, comment));
  const parsed = readCentralDirectory(path);
  rmSync(path);
  if (parsed === null) throw new Error("central directory not read");
  return parsed;
}

// cp1252 bytes: e9 = é, f3 = ó, 93/94 = curly double quotes, f1 = ñ. Every
// one is also a letter or punctuation in cp1250, where f1 is ń: the two tie,
// and the dir name (é only) decodes the same in both, so the tie order
// (cp1252 before cp1250) decides. cp437 and cp852 score worse (Θ, ┴, ˇ, ...).
const CP1252_TOP = rawName("Caf", [0xe9], " Sonor", [0xe9], " [2021] Tonos sint", [0xe9], "ticos [FLAC]");
const CP1252_TOP_TEXT = "Café Sonoré [2021] Tonos sintéticos [FLAC]";
const CP1252_ENTRIES: [Uint8Array, string][] = [
  [rawName("01  R", [0xed], "o ", [0xc1], "rbol.flac"), "01  Río Árbol.flac"],
  [rawName("02 ", [0x93], "Canci", [0xf3], "n", [0x94], ".flac"), "02 “Canción”.flac"],
  [rawName("03 Ma", [0xf1], "ana.flac"), "03 Mañana.flac"],
];

function cp1252Zip(): Uint8Array {
  return buildZip(
    CP1252_ENTRIES.map(([raw], i) => ({
      name: new Uint8Array([...CP1252_TOP, 0x2f, ...raw]),
      data: FLACS[i]!,
    })),
  );
}

/** quality.issues and needs_review of every sidecar in a root dir. */
function sidecarFlags(dir: string): { issues: string[]; needs_review: boolean }[] {
  return readdirSync(dir)
    .filter(isSidecarName)
    .map((n) => readSidecar(join(dir, n))!)
    .map((s) => ({ issues: s.quality.issues, needs_review: s.cluster.needs_review }));
}

test("cp1252 names: cp1252 and cp1250 tie (ñ / ń), the order picks cp1252, names land as UTF-8", async () => {
  const zip = join(income, `${CP1252_TOP_TEXT}.zip`);
  writeFileSync(zip, cp1252Zip());
  const parsed = readCentralDirectory(zip)!;
  expect(needsCodePage(parsed)).toBe(true);
  expect(codePagePenalties(parsed)).toEqual([
    { cp: 437, penalty: 7 }, { cp: 852, penalty: 6 }, { cp: 1252, penalty: 0 }, { cp: 1250, penalty: 0 },
  ]);
  expect(chooseCodePage(parsed, zip)).toEqual({ cp: 1252, by: "order" });

  const r = await cmdScan(["arc"], opts);
  expect(r.errors).toEqual([]);
  const block = (r.data as ScanBlock[])[0]!;
  expect(block.archives.map((a) => [a.action, a.code_page])).toEqual([["unpacked", { cp: "cp1252", by: "order" }]]);
  const unpacked = join(income, `${CP1252_TOP_TEXT}.unpacked`);
  expect(utf8Tree(unpacked)).toEqual(
    [CP1252_TOP_TEXT, ...CP1252_ENTRIES.map(([, text]) => `${CP1252_TOP_TEXT}/${text}`), `${CP1252_TOP_TEXT}/.intake.json`].sort(),
  );
  // Member data unchanged by the renamed copy.
  const albumDir = readdirSync(unpacked)[0]!;
  const tracks = readdirSync(join(unpacked, albumDir)).filter((n) => n.endsWith(".flac")).sort();
  expect(tracks.map((t) => new Uint8Array(readFileSync(join(unpacked, albumDir, t))))).toEqual(FLACS);
  expect(block.written.map((w) => w.root_path)).toEqual([join(unpacked, albumDir)]);
  // A tie broken by order is a guess: the root says so and needs review.
  expect(sidecarFlags(join(unpacked, albumDir))).toEqual([
    { issues: expect.arrayContaining(["archive_name_code_page_guessed:cp1252"]), needs_review: true },
  ]);
  expect(block.written.map((w) => w.needs_review)).toEqual([true]);
});

test("archive-name rule breaks a tie when exactly one tied page gives the archive's own name (NFC compared)", () => {
  // f1 is ñ in cp1252 and ń in cp1250: both letters, a tie only the name breaks.
  const parsed = cd([{ name: rawName("Synthetic Ma", [0xf1], "ana/01 Sol.flac"), data: FLACS[0]! }]);
  expect(chooseCodePage(parsed, `/x/${"Synthetic Mañana".normalize("NFD")}.zip`)).toEqual({ cp: 1252, by: "name_match" });
  expect(chooseCodePage(parsed, "/x/Synthetic Mańana.zip")).toEqual({ cp: 1250, by: "name_match" });
  expect(chooseCodePage(parsed, "/x/unrelated.zip")).toEqual({ cp: 1252, by: "order" });
  // The name only breaks ties: the cp1252 fixture's dir decodes the same in
  // cp1252 and cp1250, so both match and the order decides; with no name
  // match the curly quotes no longer rule cp1252 out (they did before scoring).
  const fixture = cd(CP1252_ENTRIES.map(([raw], i) => ({ name: new Uint8Array([...CP1252_TOP, 0x2f, ...raw]), data: FLACS[i]! })));
  expect(chooseCodePage(fixture, `/x/${CP1252_TOP_TEXT}.zip`)).toEqual({ cp: 1252, by: "order" });
  expect(chooseCodePage(fixture, "/x/unrelated.zip")).toEqual({ cp: 1252, by: "order" });
});

// cp437 bytes: 81 = ü, 8e = Ä, e1 = ß, c9 cd bb = box drawing ╔═╗. cp852
// decodes every one of them the same, so the two are one choice; 0x81 is
// undefined in cp1252 and cp1250, which are out.
const CP437_TOP = rawName("M", [0x81], "ller ", [0x8e], "rger ", [0xc9, 0xcd, 0xbb]);
const CP437_TOP_TEXT = "Müller Ärger ╔═╗";
const CP437_ENTRIES: [Uint8Array, string][] = [
  [rawName("01 Gr", [0x81, 0xe1], "e.flac"), "01 Grüße.flac"],
  [rawName("02 ", [0x8e], "ra.flac"), "02 Ära.flac"],
];

test("cp437 names: cp437 and cp852 decode them the same, cp1252 and cp1250 are out (0x81), names land as UTF-8", async () => {
  const zip = join(income, "Synthetic - Box Tones (1994).zip");
  writeFileSync(
    zip,
    buildZip(CP437_ENTRIES.map(([raw], i) => ({ name: new Uint8Array([...CP437_TOP, 0x2f, ...raw]), data: FLACS[i]! }))),
  );
  const parsed = readCentralDirectory(zip)!;
  expect(codePagePenalties(parsed)).toEqual([
    { cp: 437, penalty: 3 }, { cp: 852, penalty: 3 }, { cp: 1252, penalty: null }, { cp: 1250, penalty: null },
  ]);
  expect(chooseCodePage(parsed, zip)).toEqual({ cp: 437, by: "score" });

  const r = await cmdScan(["arc"], opts);
  expect(r.errors).toEqual([]);
  const unpacked = join(income, "Synthetic - Box Tones (1994).unpacked");
  expect(utf8Tree(unpacked)).toEqual(
    [CP437_TOP_TEXT, ...CP437_ENTRIES.map(([, text]) => `${CP437_TOP_TEXT}/${text}`), `${CP437_TOP_TEXT}/.intake.json`].sort(),
  );
  // Not a guess: the root carries no code page issue.
  expect(sidecarFlags(join(unpacked, CP437_TOP_TEXT))[0]!.issues.filter((i) => i.startsWith("archive_name"))).toEqual([]);
});

test("pages that decode every name the same are one choice: é in cp1252/cp1250, ü in cp437/cp852", () => {
  // cp852 reads e9 as Ú (an uppercase letter after "f" breaks the word's
  // case), cp437 as Θ (its Greek run): both cost 1.
  const parsed = cd([{ name: rawName("Synthetic/01 Caf", [0xe9], ".flac"), data: FLACS[0]! }]);
  expect(chooseCodePage(parsed, "/x/Other Name.zip")).toEqual({ cp: 1252, by: "score" });
  // An ASCII top-level dir equal to the archive name decodes the same in
  // every code page, so it decides nothing.
  const ascii = cd([{ name: rawName("Synthetic/01 M", [0x81], "ller.flac"), data: FLACS[0]! }]);
  expect(chooseCodePage(ascii, "/x/Synthetic.zip")).toEqual({ cp: 437, by: "score" });
});

/** Utf8 tree of an unpacked zip without the sidecars. */
const namesOnly = (dir: string) => utf8Tree(dir).filter((p) => !p.split("/").pop()!.startsWith(".intake"));

// The real-world OEM case: "Búho" is the same in cp437 and cp852 (ú = a3),
// the track is "Białowieża" only in cp852 (88 = ł, be = ż); cp437 gives
// "Biaêowie╛a", cp1252 "Biaˆowie¾a", cp1250 has no 0x88.
const BUHO_TOP = rawName("Synthetic B", [0xa3], "ho");
const BUHO_ENTRIES = [rawName("06 Bia", [0x88], "owie", [0xbe], "a.flac"), rawName("07 Sierra Nevada.flac")];

test("cp852 names: the Białowieża track picks cp852 by score, names land as UTF-8, no issue", async () => {
  const zip = join(income, "Synthetic Búho.zip");
  writeFileSync(zip, buildZip(BUHO_ENTRIES.map((e, i) => ({ name: new Uint8Array([...BUHO_TOP, 0x2f, ...e]), data: FLACS[i]! }))));
  const parsed = readCentralDirectory(zip)!;
  expect(codePagePenalties(parsed)).toEqual([
    { cp: 437, penalty: 1 }, { cp: 852, penalty: 0 }, { cp: 1252, penalty: 3 }, { cp: 1250, penalty: null },
  ]);
  expect(chooseCodePage(parsed, zip)).toEqual({ cp: 852, by: "score" });

  const r = await cmdScan(["arc"], opts);
  expect(r.errors).toEqual([]);
  const block = (r.data as ScanBlock[])[0]!;
  expect(block.archives.map((a) => [a.action, a.code_page])).toEqual([["unpacked", { cp: "cp852", by: "score" }]]);
  const unpacked = join(income, "Synthetic Búho.unpacked");
  expect(namesOnly(unpacked)).toEqual(["Synthetic Búho", "Synthetic Búho/06 Białowieża.flac", "Synthetic Búho/07 Sierra Nevada.flac"]);
  for (const f of sidecarFlags(join(unpacked, "Synthetic Búho")))
    expect(f.issues.filter((i) => i.startsWith("archive_name"))).toEqual([]);
});

test("cp1250 names: Czech ANSI ě/ů/ň with ł (³ in cp1252) pick cp1250 by score", async () => {
  // ec = ě, ed = í, f9 = ů, f2 = ň, b3 = ł in cp1250. cp1252 reads them as
  // ì í ù ò (letters, a tie) but b3 as ³, a superscript; cp852 and cp437 as
  // ý Ý ¨ ˛ │ and ∞ φ ∙ ≥ │.
  const top = rawName("Synthetic M", [0xec], "s", [0xed], "c");
  const entries = [rawName("01 K", [0xf9, 0xf2], ".flac"), rawName("02 Bia", [0xb3], "y.flac")];
  const zip = join(income, "Synthetic - Czech ANSI (2003).zip");
  writeFileSync(zip, buildZip(entries.map((e, i) => ({ name: new Uint8Array([...top, 0x2f, ...e]), data: FLACS[i]! }))));
  const parsed = readCentralDirectory(zip)!;
  expect(codePagePenalties(parsed)).toEqual([
    { cp: 437, penalty: 5 }, { cp: 852, penalty: 4 }, { cp: 1252, penalty: 1 }, { cp: 1250, penalty: 0 },
  ]);
  expect(chooseCodePage(parsed, zip)).toEqual({ cp: 1250, by: "score" });

  const r = await cmdScan(["arc"], opts);
  expect(r.errors).toEqual([]);
  expect(namesOnly(join(income, "Synthetic - Czech ANSI (2003).unpacked"))).toEqual([
    "Synthetic Měsíc", "Synthetic Měsíc/01 Kůň.flac", "Synthetic Měsíc/02 Biały.flac",
  ]);
});

// A real tie: 88 is ê in cp437 and ł in cp852, both letters; cp1252 reads ˆ
// (a modifier letter), cp1250 has no 0x88. The archive's name matches neither.
const TIE_TOP = rawName("Synthetic Bia", [0x88], "a");
const TIE_ENTRIES = [rawName("01 Bia", [0x88], "y.flac"), rawName("02 Bia", [0x88], "e.flac")];
const TIE_ZIP = "Synthetic - Tie (2001).zip";

async function scanTie(): Promise<{ block: ScanBlock; root: string }> {
  writeFileSync(join(income, TIE_ZIP), buildZip(TIE_ENTRIES.map((e, i) => ({ name: new Uint8Array([...TIE_TOP, 0x2f, ...e]), data: FLACS[i]! }))));
  const r = await cmdScan(["arc"], opts);
  expect(r.errors).toEqual([]);
  const unpacked = join(income, "Synthetic - Tie (2001).unpacked");
  return { block: (r.data as ScanBlock[])[0]!, root: join(unpacked, readdirSync(unpacked)[0]!) };
}

test("a tie with no archive_code_pages: the default order picks cp437, the root gets the guessed issue and needs_review", async () => {
  const { block, root } = await scanTie();
  expect(block.archives.map((a) => a.code_page)).toEqual([{ cp: "cp437", by: "order" }]);
  expect(namesOnly(join(income, "Synthetic - Tie (2001).unpacked"))).toEqual([
    "Synthetic Biaêa", "Synthetic Biaêa/01 Biaêy.flac", "Synthetic Biaêa/02 Biaêe.flac",
  ]);
  expect(sidecarFlags(root)).toEqual([
    { issues: expect.arrayContaining(["archive_name_code_page_guessed:cp437"]), needs_review: true },
  ]);
  expect(block.written.map((w) => [w.root_path, w.needs_review])).toEqual([[root, true]]);
});

test("a tie with archive_code_pages: [cp852]: cp852 is picked, and the resolver flags it as cp852 (same preference)", async () => {
  writeIncome("archive_code_pages: [cp852]");
  const { block, root } = await scanTie();
  expect(block.archives.map((a) => a.code_page)).toEqual([{ cp: "cp852", by: "order" }]);
  expect(namesOnly(join(income, "Synthetic - Tie (2001).unpacked"))).toEqual([
    "Synthetic Biała", "Synthetic Biała/01 Biały.flac", "Synthetic Biała/02 Białe.flac",
  ]);
  expect(sidecarFlags(root)).toEqual([
    { issues: expect.arrayContaining(["archive_name_code_page_guessed:cp852"]), needs_review: true },
  ]);
  // The list only orders ties: the Białowieża zip still picks cp852 by score
  // with cp437 first, and the cp437 zip stays cp437 with cp852 first.
  const buho = cd(BUHO_ENTRIES.map((e, i) => ({ name: new Uint8Array([...BUHO_TOP, 0x2f, ...e]), data: FLACS[i]! })));
  expect(chooseCodePage(buho, "/x/a.zip", [437])).toEqual({ cp: 852, by: "score" });
  const box = cd(CP437_ENTRIES.map(([raw], i) => ({ name: new Uint8Array([...CP437_TOP, 0x2f, ...raw]), data: FLACS[i]! })));
  expect(chooseCodePage(box, "/x/a.zip", [852])).toEqual({ cp: 852, by: "score" }); // same names either way
  expect(decodeCodePage(box.entries[0]!.name, 852)).toBe(decodeCodePage(box.entries[0]!.name, 437));
});

test("names that are not text in any candidate (a control char): the unpack fails naming the archive, nothing written", async () => {
  const zip = join(income, "Synthetic - Control (2001).zip");
  writeFileSync(zip, buildZip([{ name: rawName("Synthetic", [0x01], " B", [0x88], "d/01.flac"), data: FLACS[0]! }]));
  const parsed = readCentralDirectory(zip)!;
  expect(codePagePenalties(parsed).map((p) => p.penalty)).toEqual([null, null, null, null]);
  const r = await cmdScan(["arc"], opts);
  expect(r.errors).toEqual([{
    code: "E_ARCHIVE",
    msg: 'entry names of "Synthetic - Control (2001).zip" are not text in any code page tried (cp437, cp852, cp1252, cp1250): each gives a control character or an undefined byte',
    path: zip,
  }]);
  expect((r.data as ScanBlock[])[0]!.archives.map((a) => [a.action, a.code_page])).toEqual([["failed", null]]);
  expect(readdirSync(income)).toEqual(["Synthetic - Control (2001).zip"]);
});

test("archive_code_pages: listed pages first in list order, the rest in the default order; anything else is a config error", () => {
  expect(tieOrder()).toEqual([437, 852, 1252, 1250]);
  expect(tieOrder([852])).toEqual([852, 437, 1252, 1250]);
  expect(tieOrder([1250, 852])).toEqual([1250, 852, 437, 1252]);
  const rules = join(corpus.dir, "rules-cp");
  mkdirSync(rules, { recursive: true });
  const load = (...lines: string[]) => {
    writeFileSync(join(rules, "income.yaml"), [...lines, "income:", "  - name: arc", `    path: ${income}`, ""].join("\n"));
    return loadIncomeConfig(rules);
  };
  expect(load().archiveCodePages).toEqual([]);
  expect(load("archive_code_pages: []").archiveCodePages).toEqual([]);
  expect(load("archive_code_pages: [cp1250, cp852]").archiveCodePages).toEqual([1250, 852]);
  const file = join(rules, "income.yaml");
  const allowed = "(allowed: cp437, cp852, cp1252, cp1250)";
  expect(() => load("archive_code_pages: [cp852, cp999]")).toThrow(`${file}: archive_code_pages: unknown code page "cp999" ${allowed}`);
  expect(() => load("archive_code_pages: [CP852]")).toThrow(`unknown code page "CP852"`);
  expect(() => load("archive_code_pages: [852]")).toThrow("unknown code page 852");
  expect(() => load("archive_code_pages: cp852")).toThrow(`${file}: archive_code_pages: must be a list of code page names ${allowed}`);
  expect(() => load("archive_code_pages:")).toThrow("must be a list");
  expect(() => load("archive_code_pages: [cp852, cp437, cp852]")).toThrow(`${file}: archive_code_pages: cp852 listed twice ${allowed}`);
});

test("needsCodePage: false for UTF-8-flagged names and for unflagged valid UTF-8, true for raw cp bytes", () => {
  expect(needsCodePage(cd([{ name: "Café/01.flac", data: FLACS[0]!, utf8Flag: true }]))).toBe(false);
  expect(needsCodePage(cd([{ name: "Café/01.flac", data: FLACS[0]! }]))).toBe(false);
  expect(needsCodePage(cd([{ name: "Plain/01.flac", data: FLACS[0]! }]))).toBe(false);
  expect(needsCodePage(cd([{ name: rawName("Caf", [0xe9], "/01.flac"), data: FLACS[0]! }]))).toBe(true);
});

test("central directory: read past a zip comment (even one holding an EOCD signature); null for ZIP64 or garbage", () => {
  const fakeEocd = [0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0];
  const comment = new Uint8Array([...new TextEncoder().encode("synthetic comment "), ...fakeEocd, 0x21]);
  const parsed = cd([{ name: rawName("Caf", [0xe9], "/01.flac"), data: FLACS[0]! }], comment);
  expect(parsed.entries.map((e) => [...e.name])).toEqual([[...rawName("Caf", [0xe9], "/01.flac")]]);

  const path = join(income, "bad.zip");
  writeFileSync(path, new Uint8Array(4096).fill(0x41));
  expect(readCentralDirectory(path)).toBeNull();
  // EOCD entry count saturated (0xFFFF): a ZIP64 archive.
  const zip = buildZip([{ name: "a.flac", data: FLACS[0]! }]);
  const eocd = zip.length - 22;
  zip.set([0xff, 0xff, 0xff, 0xff], eocd + 8);
  writeFileSync(path, zip);
  expect(readCentralDirectory(path)).toBeNull();
});

test("decodeCodePage: exact table entries at the edges", () => {
  const hi = new Uint8Array([0x80, 0x81, 0x9f, 0xa0, 0xff]);
  expect([...decodeCodePage(hi, 1252)].map((c) => c.codePointAt(0))).toEqual([0x20ac, 0x81, 0x178, 0xa0, 0xff]);
  expect([...decodeCodePage(hi, 437)].map((c) => c.codePointAt(0))).toEqual([0xc7, 0xfc, 0x192, 0xe1, 0xa0]);
  expect([...decodeCodePage(hi, 852)].map((c) => c.codePointAt(0))).toEqual([0xc7, 0xfc, 0x10d, 0xe1, 0xa0]);
  expect([...decodeCodePage(hi, 1250)].map((c) => c.codePointAt(0))).toEqual([0x20ac, 0x81, 0x17a, 0xa0, 0x2d9]);
  // cp1250's undefined bytes are their C1 controls, so a name with one rules cp1250 out.
  expect([...decodeCodePage(new Uint8Array([0x83, 0x88, 0x90, 0x98]), 1250)].map((c) => c.codePointAt(0))).toEqual([0x83, 0x88, 0x90, 0x98]);
  expect(decodeCodePage(rawName("plain ascii/"), 437)).toBe("plain ascii/");
});

/** scan as a subprocess; PATH defaults to /usr/bin:/bin (unzip, no 7-Zip). */
function scanWithPath(path = "/usr/bin:/bin"): { code: number | null; envelope: { errors: { code: string; msg: string; path: string | null }[]; data: any } } {
  const env = { PATH: path, INTAKE_RULES_DIR: corpus.rules, HOME: process.env.HOME ?? "/tmp" };
  const proc = Bun.spawnSync([process.execPath, "run", CLI, "scan", "arc", "--json"], { env, timeout: 60_000 });
  const out = proc.stdout.toString();
  if (!out.trim()) throw new Error(`no stdout; stderr: ${proc.stderr.toString()}`);
  return { code: proc.exitCode, envelope: JSON.parse(out) };
}

// A zip as Windows tools write it: UTF-8 names with bit 11 set, "version
// made by" host 0 (MS-DOS/FAT) and the archive attribute (0x20) as external
// attributes (buildZip's defaults). The host byte is what breaks macOS's
// unzip: for FAT-host entries it translates the name bytes as OEM text,
// flag or not, and APFS refuses the result. Some tools leave valid UTF-8
// names unflagged; those break the same way.
const UTF8_ENTRIES = ["Sinfonía Ñ/01 Café.flac", "Sinfonía Ñ/02 Ærø — “Grüße”.flac"];

test("a Windows-made zip with non-ASCII UTF-8 names (flagged or not) goes to 7-Zip, names land as UTF-8", async () => {
  const flagged = join(income, "Synthetic - Flagged (2023).zip");
  writeFileSync(flagged, buildZip(UTF8_ENTRIES.map((name, i) => ({ name, data: FLACS[i]!, utf8Flag: true }))));
  const unflagged = join(income, "Synthetic - Unflagged (2023).zip");
  writeFileSync(unflagged, buildZip(UTF8_ENTRIES.map((name, i) => ({ name, data: FLACS[i]! }))));

  const r = await cmdScan(["arc"], opts);
  expect(r.errors).toEqual([]);
  const block = (r.data as { archives: { action: string }[]; written: { root_path: string }[] }[])[0]!;
  expect(block.archives.map((a) => a.action)).toEqual(["unpacked", "unpacked"]);
  for (const zip of [flagged, unflagged]) {
    const unpacked = zip.replace(/\.zip$/, ".unpacked");
    expect(utf8Tree(unpacked)).toEqual(["Sinfonía Ñ", "Sinfonía Ñ/.intake.json", ...UTF8_ENTRIES].sort());
    const album = join(unpacked, readdirSync(unpacked)[0]!);
    const tracks = readdirSync(album).filter((n) => n.endsWith(".flac")).sort();
    expect(tracks.map((t) => new Uint8Array(readFileSync(join(album, t))))).toEqual(FLACS.slice(0, 2));
  }
  expect(block.written).toHaveLength(2);
});

test("non-ASCII UTF-8 names with no 7-Zip on PATH: failed with a clear message, nothing written", () => {
  for (const t of ["7zz", "7z"]) expect(Bun.which(t, { PATH: "/usr/bin:/bin" })).toBeNull();
  const zip = join(income, "Synthetic - Flagged (2023).zip");
  writeFileSync(zip, buildZip(UTF8_ENTRIES.map((name, i) => ({ name, data: FLACS[i]!, utf8Flag: true }))));
  const { code, envelope } = scanWithPath();
  expect(envelope.errors.map((e) => [e.code, e.path, e.msg])).toEqual([
    ["E_ARCHIVE", zip, "zip names are non-ASCII UTF-8: extracting them needs 7zz or 7z on PATH"],
  ]);
  expect(code).toBe(1);
  expect(envelope.data[0].archives[0].action).toBe("failed");
  expect(readdirSync(income)).toEqual(["Synthetic - Flagged (2023).zip"]);
});

test("archive_code_pages: [cp999] fails scan as a malformed income.yaml does (E_BAD_RULES, exit 2), nothing unpacked", () => {
  writeIncome("archive_code_pages: [cp999]");
  const zip = join(income, TIE_ZIP);
  writeFileSync(zip, buildZip(TIE_ENTRIES.map((e, i) => ({ name: new Uint8Array([...TIE_TOP, 0x2f, ...e]), data: FLACS[i]! }))));
  const { code, envelope } = scanWithPath();
  expect(envelope.errors).toEqual([{
    code: "E_BAD_RULES",
    msg: `${join(corpus.rules, "income.yaml")}: archive_code_pages: unknown code page "cp999" (allowed: cp437, cp852, cp1252, cp1250)`,
    path: join(corpus.rules, "income.yaml"),
  }]);
  expect(envelope.data).toBeNull();
  expect(code).toBe(2);
  expect(readdirSync(income)).toEqual([TIE_ZIP]);
});

test("code-page names with no 7-Zip on PATH: failed with a clear message, raw bytes never written", () => {
  const zip = join(income, `${CP1252_TOP_TEXT}.zip`);
  writeFileSync(zip, cp1252Zip());
  const { code, envelope } = scanWithPath();
  expect(envelope.errors.map((e) => [e.code, e.path, e.msg])).toEqual([
    ["E_ARCHIVE", zip, "zip names are cp1252, not UTF-8: extracting them needs 7zz or 7z on PATH"],
  ]);
  expect(code).toBe(1);
  expect(readdirSync(income)).toEqual([`${CP1252_TOP_TEXT}.zip`]);
});

test("with only p7zip (7z) on PATH, code-page names land the same", () => {
  const p7zip = Bun.which("7z");
  if (p7zip === null) throw new Error("this test needs 7z (p7zip) on PATH");
  const bin = join(corpus.dir, "bin-7z");
  rmSync(bin, { recursive: true, force: true });
  mkdirSync(bin);
  symlinkSync(p7zip, join(bin, "7z"));
  const zip = join(income, `${CP1252_TOP_TEXT}.zip`);
  writeFileSync(zip, cp1252Zip());
  const { code, envelope } = scanWithPath(`${bin}:/usr/bin:/bin`);
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(utf8Tree(join(income, `${CP1252_TOP_TEXT}.unpacked`))).toEqual(
    [CP1252_TOP_TEXT, ...CP1252_ENTRIES.map(([, text]) => `${CP1252_TOP_TEXT}/${text}`), `${CP1252_TOP_TEXT}/.intake.json`].sort(),
  );
});
