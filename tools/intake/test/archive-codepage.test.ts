// Zips whose entry names are raw Windows code-page bytes (UTF-8 flag unset,
// not valid UTF-8): the names are decoded with cp1252 or cp437 and land as
// UTF-8. Real-world shape (names here are synthetic):
//   "El B\xfaho [2021] Natura sonora [FLAC]/01  Sierra Nevada de Santa Marta.flac"
// where 0xFA is "u acute" in cp1252. Zips are built in the test with exact
// name bytes (test/zipbuild.ts); member data are fixture FLACs, so the
// result also resolves.

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdScan } from "../src/commands.ts";
import { chooseCodePage, decodeCodePage, needsCodePage, readCentralDirectory } from "../src/zipnames.ts";
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

beforeAll(() => {
  corpus = setupCorpus();
  income = join(corpus.dir, "arc");
  writeFileSync(
    join(corpus.rules, "income.yaml"),
    ["income:", "  - name: arc", `    path: ${income}`, "    source_type: web", ""].join("\n"),
  );
});

beforeEach(() => {
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

// cp1252 bytes: e9 = é, f3 = ó, 93/94 = curly double quotes. The quotes are
// outside 0xC0-0xFF, so only the archive-name rule picks cp1252 here.
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

test("archive-name rule: a cp1252 top-level dir equal to the zip's own name picks cp1252, names land as UTF-8", async () => {
  const zip = join(income, `${CP1252_TOP_TEXT}.zip`);
  writeFileSync(zip, cp1252Zip());
  const parsed = readCentralDirectory(zip)!;
  expect(needsCodePage(parsed)).toBe(true);
  expect(chooseCodePage(parsed, zip)).toEqual({ cp: 1252, rule: 1 });

  const r = await cmdScan(["arc"], opts);
  expect(r.errors).toEqual([]);
  const block = (r.data as { archives: { action: string }[]; written: { root_path: string }[] }[])[0]!;
  expect(block.archives.map((a) => a.action)).toEqual(["unpacked"]);
  const unpacked = join(income, `${CP1252_TOP_TEXT}.unpacked`);
  expect(utf8Tree(unpacked)).toEqual(
    [CP1252_TOP_TEXT, ...CP1252_ENTRIES.map(([, text]) => `${CP1252_TOP_TEXT}/${text}`), `${CP1252_TOP_TEXT}/.intake.json`].sort(),
  );
  // Member data unchanged by the renamed copy.
  const albumDir = readdirSync(unpacked)[0]!;
  const tracks = readdirSync(join(unpacked, albumDir)).filter((n) => n.endsWith(".flac")).sort();
  expect(tracks.map((t) => new Uint8Array(readFileSync(join(unpacked, albumDir, t))))).toEqual(FLACS);
  expect(block.written.map((w) => w.root_path)).toEqual([join(unpacked, albumDir)]);
});

test("archive-name rule compares NFC: an NFD archive name still matches", () => {
  const parsed = cd(CP1252_ENTRIES.map(([raw], i) => ({ name: new Uint8Array([...CP1252_TOP, 0x2f, ...raw]), data: FLACS[i]! })));
  expect(chooseCodePage(parsed, `/x/${CP1252_TOP_TEXT.normalize("NFD")}.zip`)).toEqual({ cp: 1252, rule: 1 });
  // Without the name match the quotes (0x93/0x94) rule cp1252 out.
  expect(chooseCodePage(parsed, "/x/unrelated.zip")).toEqual({ cp: 437, rule: 3 });
});

// cp437 bytes: 81 = ü, 8e = Ä, e1 = ß, c9 cd bb = box drawing ╔═╗. 0x81 and
// 0x8E are outside 0xC0-0xFF (and 0x81 is undefined in cp1252).
const CP437_TOP = rawName("M", [0x81], "ller ", [0x8e], "rger ", [0xc9, 0xcd, 0xbb]);
const CP437_TOP_TEXT = "Müller Ärger ╔═╗";
const CP437_ENTRIES: [Uint8Array, string][] = [
  [rawName("01 Gr", [0x81, 0xe1], "e.flac"), "01 Grüße.flac"],
  [rawName("02 ", [0x8e], "ra.flac"), "02 Ära.flac"],
];

test("cp437 fallback: bytes that are not cp1252 letters pick cp437, names land as UTF-8", async () => {
  const zip = join(income, "Synthetic - Box Tones (1994).zip");
  writeFileSync(
    zip,
    buildZip(CP437_ENTRIES.map(([raw], i) => ({ name: new Uint8Array([...CP437_TOP, 0x2f, ...raw]), data: FLACS[i]! }))),
  );
  const parsed = readCentralDirectory(zip)!;
  expect(chooseCodePage(parsed, zip)).toEqual({ cp: 437, rule: 3 });

  const r = await cmdScan(["arc"], opts);
  expect(r.errors).toEqual([]);
  const unpacked = join(income, "Synthetic - Box Tones (1994).unpacked");
  expect(utf8Tree(unpacked)).toEqual(
    [CP437_TOP_TEXT, ...CP437_ENTRIES.map(([, text]) => `${CP437_TOP_TEXT}/${text}`), `${CP437_TOP_TEXT}/.intake.json`].sort(),
  );
});

test("Latin rule: only 0xC0-0xFF non-ASCII bytes and no name match pick cp1252", () => {
  const parsed = cd([{ name: rawName("Synthetic/01 Caf", [0xe9], ".flac"), data: FLACS[0]! }]);
  expect(chooseCodePage(parsed, "/x/Other Name.zip")).toEqual({ cp: 1252, rule: 2 });
  // An ASCII top-level dir equal to the archive name decodes the same in both
  // code pages, so it decides nothing: 0x81 still picks cp437.
  const ascii = cd([{ name: rawName("Synthetic/01 M", [0x81], "ller.flac"), data: FLACS[0]! }]);
  expect(chooseCodePage(ascii, "/x/Synthetic.zip")).toEqual({ cp: 437, rule: 3 });
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
  expect(decodeCodePage(rawName("plain ascii/"), 437)).toBe("plain ascii/");
});

/** scan as a subprocess; PATH defaults to /usr/bin:/bin (unzip, no 7-Zip). */
function scanWithPath(path = "/usr/bin:/bin"): { code: number | null; envelope: { errors: { code: string; msg: string; path: string }[]; data: any[] } } {
  const env = { PATH: path, INTAKE_RULES_DIR: corpus.rules, HOME: process.env.HOME ?? "/tmp" };
  const proc = Bun.spawnSync([process.execPath, "run", CLI, "scan", "arc", "--json"], { env, timeout: 60_000 });
  const out = proc.stdout.toString();
  if (!out.trim()) throw new Error(`no stdout; stderr: ${proc.stderr.toString()}`);
  return { code: proc.exitCode, envelope: JSON.parse(out) };
}

test("a UTF-8-flagged zip takes the normal unzip path (works with no 7-Zip on PATH)", () => {
  for (const t of ["7zz", "7z"]) expect(Bun.which(t, { PATH: "/usr/bin:/bin" })).toBeNull();
  // Host byte Unix: macOS unzip leaves UTF-8 names of Unix-made entries alone.
  const zip = join(income, "Synthetic - Flagged (2023).zip");
  writeFileSync(zip, buildZip([{ name: "Sinfonía Ñ/01 Café.flac", data: FLACS[0]!, utf8Flag: true, host: 3 }]));
  const { code, envelope } = scanWithPath();
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(envelope.data[0].archives[0].action).toBe("unpacked");
  expect(utf8Tree(join(income, "Synthetic - Flagged (2023).unpacked"))).toEqual(
    ["Sinfonía Ñ", "Sinfonía Ñ/.intake.json", "Sinfonía Ñ/01 Café.flac"],
  );
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
