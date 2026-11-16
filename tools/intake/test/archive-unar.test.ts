// Solid RAR4 extraction with the real unar (The Unarchiver's CLI): libarchive
// 3.7.4 cannot extract a solid RAR4, so intake sends one to unar when it is
// on PATH (src/archive.ts) and checks the result against the headers as for
// bsdtar (src/rarheaders.ts). Archives are built in the test
// (test/rarbuild.ts): each compressed member is one literal-only RAR 2.9
// block with fresh tables, so no back-reference crosses files, and the
// second and later entries carry LHD_SOLID. No `rar` binary.
//
// The CLI runs as a subprocess with PATH = a wrapper dir, /usr/bin and /bin.
// The wrappers log each call and exec the real unar and /usr/bin/bsdtar, so
// a test sees which tool got which archive, and that a refused archive
// reached neither. No 7-Zip on PATH. Every run is killed after 20 s; the
// refusal cases run under a pseudo-terminal (`script`), where a password
// prompt would really wait. The tests skip without unar on PATH.

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { setupCorpus, type Corpus } from "./helpers.ts";
import { buildRar4, type Rar4Entry, type Rar4Options } from "./rarbuild.ts";
import { rawName } from "./zipbuild.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const UNAR = Bun.which("unar");
const BSDTAR = "/usr/bin/bsdtar";
const unarTest = test.skipIf(UNAR === null || !existsSync(BSDTAR));

let corpus: Corpus;
let income: string;
let callLog: string;
let PATH: string;

const enc = (s: string) => new TextEncoder().encode(s);
const TRACK = enc("synthetic payload\n".repeat(64));
const TRACK2 = enc("second synthetic payload, not the first\n".repeat(50));
const BIG = Uint8Array.from({ length: 300_000 }, (_, i) => (i * 7919 + (i >> 9)) & 0xff); // several read chunks

beforeAll(() => {
  corpus = setupCorpus();
  income = join(corpus.dir, "arc");
  callLog = join(corpus.dir, "calls.log");
  writeFileSync(
    join(corpus.rules, "income.yaml"),
    ["income:", "  - name: arc", `    path: ${income}`, "    source_type: web", ""].join("\n"),
  );
  const wrap = join(corpus.dir, "wrap");
  mkdirSync(wrap, { recursive: true });
  for (const [name, real] of [["unar", UNAR], ["bsdtar", BSDTAR]] as const) {
    if (real === null) continue;
    writeFileSync(join(wrap, name), `#!/bin/sh\n{ printf ${name}; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$CALL_LOG"\nexec ${real} "$@"\n`);
    chmodSync(join(wrap, name), 0o755);
  }
  PATH = `${wrap}:/usr/bin:/bin`;
  for (const t of ["7z", "7zz"]) {
    if (Bun.which(t, { PATH }) !== null) throw new Error(`${t} found on ${PATH}: a rar could go to 7-Zip`);
  }
});

beforeEach(() => {
  rmSync(income, { recursive: true, force: true });
  mkdirSync(income, { recursive: true });
  rmSync(callLog, { force: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

interface Run {
  killed: boolean;
  code: number | null;
  errors: { code: string; msg: string; path: string }[];
  actions: Record<string, string>; // archive file name -> action
}

function scan(tty = false): Run {
  const env = { PATH, INTAKE_RULES_DIR: corpus.rules, HOME: process.env.HOME ?? "/tmp", CALL_LOG: callLog };
  const cli = [process.execPath, "run", CLI, "scan", "arc", "--json"];
  const argv = tty ? ["/usr/bin/script", "-q", "/dev/null", ...cli] : cli;
  const proc = Bun.spawnSync(argv, { env, stdin: "ignore", timeout: 20_000, killSignal: "SIGKILL" });
  const killed = proc.exitCode === null;
  const out = proc.stdout.toString().replaceAll("\r", "");
  const start = out.indexOf("{");
  const end = out.lastIndexOf("}");
  if (killed) return { killed, code: null, errors: [], actions: {} };
  if (start < 0 || end <= start) throw new Error(`no JSON on stdout; stderr: ${proc.stderr.toString()}`);
  const envelope = JSON.parse(out.slice(start, end + 1));
  const actions: Record<string, string> = {};
  for (const a of envelope.data[0].archives) actions[relative(income, a.archive)] = a.action;
  return { killed, code: proc.exitCode, errors: envelope.errors, actions };
}

function place(name: string, bytes: Uint8Array): string {
  writeFileSync(join(income, name), bytes);
  return join(income, name);
}

/** A solid RAR4: main header solid flag, every member compressed, LHD_SOLID on the second and later ones. */
function solidRar4(entries: Rar4Entry[], opts: Rar4Options = {}): Uint8Array {
  return buildRar4(entries.map((e, i) => ({ compressed: true, ...e, solid: i > 0 })), { solid: true, ...opts });
}

const calls = (): string[] => (existsSync(callLog) ? readFileSync(callLog, "utf8").trim().split("\n") : []);
const stem = (name: string) => join(income, name.replace(/\.rar$/, ""));
const UNAR_FLAGS = "[-D] [-nr] [-k] [skip] [-nq] [-s] [-q]";

/** Every file under `dir` (symlinks included), "/"-separated and NFC, with its bytes (null for a symlink). */
function tree(dir: string): Map<string, Uint8Array | null> {
  const out = new Map<string, Uint8Array | null>();
  const walk = (d: string) => {
    for (const n of readdirSync(d)) {
      const p = join(d, n);
      const st = lstatSync(p);
      if (st.isDirectory()) walk(p);
      else out.set(relative(dir, p).normalize("NFC"), st.isSymbolicLink() ? null : new Uint8Array(readFileSync(p)));
    }
  };
  walk(dir);
  return out;
}

/** The scan refused or failed each archive with its message; nothing is left but the archives. */
function expectFailed(run: Run, cases: { file: string; msg: string | RegExp }[]): void {
  expect(run.killed).toBe(false);
  expect(run.code).toBe(1);
  const byPath = new Map(run.errors.map((e) => [e.path, e]));
  for (const c of cases) {
    const e = byPath.get(join(income, c.file));
    expect(e?.code).toBe("E_ARCHIVE");
    if (typeof c.msg === "string") expect(e?.msg).toBe(c.msg);
    else expect(e?.msg).toMatch(c.msg);
    expect(run.actions[c.file]).toBe("failed");
  }
  expect(run.errors).toHaveLength(cases.length);
  expect(readdirSync(income).sort()).toEqual(cases.map((c) => c.file).sort());
}

/** The scan unpacked each archive to exactly `files` (NFC paths), with no partial dir left. */
function expectUnpacked(run: Run, cases: { file: string; files: Record<string, Uint8Array> }[]): void {
  expect(run.killed).toBe(false);
  expect(run.errors).toEqual([]);
  expect(run.code).toBe(0);
  for (const c of cases) {
    expect(run.actions[c.file]).toBe("unpacked");
    expect(existsSync(`${stem(c.file)}.unpacked.partial`)).toBe(false);
    expect(tree(`${stem(c.file)}.unpacked`)).toEqual(new Map(Object.entries(c.files)));
  }
}

unarTest("solid RAR4 (main flag 0x0008, 0x000c with lock, or LHD_SOLID only) goes to unar and verifies; non-solid RAR4 stays with bsdtar", () => {
  const entries: Rar4Entry[] = [
    { name: "Album/01 - First.txt", data: TRACK },
    { name: "Album/02 - Second.txt", data: TRACK2 },
    { name: "Album/03 - Big.bin", data: BIG },
  ];
  const files = { "Album/01 - First.txt": TRACK, "Album/02 - Second.txt": TRACK2, "Album/03 - Big.bin": BIG };
  const a = place("A Solid (2008).rar", solidRar4(entries));
  const locked = solidRar4(entries, { locked: true });
  expect(locked[10]! | (locked[11]! << 8)).toBe(0x000c); // main header flags: solid + locked
  const b = place("B Solid Locked (2008).rar", locked);
  const c = place("C Solid Entry (2008).rar", buildRar4(entries.map((e, i) => ({ ...e, compressed: true, solid: i > 0 }))));
  const d = place("D Plain (2008).rar", buildRar4(entries.map((e) => ({ ...e, compressed: true }))));
  const run = scan();
  expect(calls()).toEqual([
    ...[a, b, c].map((p) => `unar [-o] [${p.replace(/\.rar$/, "")}.unpacked.partial] ${UNAR_FLAGS} [--] [${p}]`),
    `bsdtar [-x] [-f] [${d}] [-C] [${stem("D Plain (2008).rar")}.unpacked.partial] [--no-same-owner] [--no-same-permissions] ` +
      "[--no-acls] [--no-xattrs] [--no-fflags] [--no-mac-metadata]",
  ]);
  expectUnpacked(run, ["A Solid (2008).rar", "B Solid Locked (2008).rar", "C Solid Entry (2008).rar", "D Plain (2008).rar"].map(
    (file) => ({ file, files }),
  ));
});

unarTest("solid RAR4 with a bad CRC32 on the second member: unar exits 1, failed, no .partial or .unpacked left", () => {
  place("Synthetic - Bad Crc Solid (2008).rar", solidRar4([
    { name: "Album/01 - First.txt", data: TRACK },
    { name: "Album/02 - Second.txt", data: TRACK2, badCrc: true },
  ]));
  const run = scan();
  expect(calls()).toHaveLength(1);
  expectFailed(run, [{ file: "Synthetic - Bad Crc Solid (2008).rar", msg: /^Album\/02 - Second\.txt .*Failed! \(Wrong checksum\)/ }]);
});

unarTest("solid RAR4 plain OEM names: unar gets -e cp437 / cp852 / windows-1252 / windows-1250, names land as UTF-8 and pass the check", () => {
  // cp437 bytes; cp852 reads Ñ as ą and ½ as ź: a tie, the order picks cp437.
  const oem437 = "Café Ñandú/01 Über ½.txt";
  // cp852 bytes 42 69 61 88 6f 77 69 65 be 61: "Białowieża" (cp437 "Biaêowie╛a").
  const bialowieza = (n: string) => rawName(`Synthetic Solid/${n} Bia`, [0x88], "owie", [0xbe], "a.txt");
  // cp1252 bytes; cp1250 reads Ñ as Ń: a tie, the order picks cp1252.
  const oem1252 = "Café Ñandú/01 Über.txt";
  // cp1250 bytes: ě, í, ł, ů, ň.
  const czech = rawName("Synthetic M", [0xec], "s", [0xed], "c/02 Bia", [0xb3], "y K", [0xf9, 0xf2], ".txt");
  const uni = "Dvořák – ŘŘ Ünïcode/01 Česká píseň ☃.txt"; // Unicode-flagged: no -e
  place("A Oem437 (2008).rar", solidRar4([{ name: oem437, data: TRACK }, { name: "Café Ñandú/02 Two.txt", data: TRACK2 }]));
  place("B Oem852 (2008).rar", solidRar4([
    { name: "", oemName: bialowieza("01"), data: TRACK },
    { name: "", oemName: bialowieza("02"), data: TRACK2 },
  ]));
  place("C Oem1252 (2008).rar", solidRar4([
    { name: oem1252, data: TRACK, codePage: 1252 },
    { name: "Café Ñandú/02 Two.txt", data: TRACK2, codePage: 1252 },
  ]));
  place("D Oem1250 (2008).rar", solidRar4([{ name: "", oemName: czech, data: BIG }, { name: "Synthetic Měsíc/03 Two.txt", data: TRACK, codePage: 1250 }]));
  place("E Unicode (2008).rar", solidRar4([
    { name: uni, data: TRACK, names: "unicode" },
    { name: "Sinfonía Ñ/02 Über.txt", data: TRACK2, names: "utf8" },
  ]));
  const run = scan();
  const encodings = calls().map((c) => (c.startsWith("unar ") ? (c.match(/\[-e\] \[([^\]]*)\]/)?.[1] ?? null) : "not unar"));
  expect(encodings).toEqual(["cp437", "cp852", "windows-1252", "windows-1250", null]);
  expectUnpacked(run, [
    { file: "A Oem437 (2008).rar", files: { [oem437]: TRACK, "Café Ñandú/02 Two.txt": TRACK2 } },
    { file: "B Oem852 (2008).rar", files: { "Synthetic Solid/01 Białowieża.txt": TRACK, "Synthetic Solid/02 Białowieża.txt": TRACK2 } },
    { file: "C Oem1252 (2008).rar", files: { [oem1252]: TRACK, "Café Ñandú/02 Two.txt": TRACK2 } },
    { file: "D Oem1250 (2008).rar", files: { "Synthetic Měsíc/02 Biały Kůň.txt": BIG, "Synthetic Měsíc/03 Two.txt": TRACK } },
    { file: "E Unicode (2008).rar", files: { [uni]: TRACK, "Sinfonía Ñ/02 Über.txt": TRACK2 } },
  ]);
});

unarTest("encrypted, unsafe and multi-volume solid RAR4: refused before extraction, unar never runs, no prompt", () => {
  place("A Encrypted (2008).rar", solidRar4([
    { name: "Album/01.txt", data: TRACK, encrypted: true },
    { name: "Album/02.txt", data: TRACK2, encrypted: true },
  ]));
  place("B Dotdot (2008).rar", solidRar4([{ name: "Album/01.txt", data: TRACK }, { name: "../escape.txt", data: TRACK2 }]));
  place("C Volume (2008).rar", solidRar4([{ name: "Album/01.txt", data: TRACK, splitAfter: true }], { volume: true }));
  const run = scan(true);
  expect(calls()).toEqual([]);
  expectFailed(run, [
    { file: "A Encrypted (2008).rar", msg: 'rar entry "Album/01.txt": encrypted' },
    { file: "B Dotdot (2008).rar", msg: 'rar entry "../escape.txt": unsafe path (..)' },
    { file: "C Volume (2008).rar", msg: "multi-volume rar is not supported" },
  ]);
}, 30_000);

unarTest("solid RAR4 symlink entries: a link is stripped and the rest verifies; unar does not write through a link, so that archive fails", () => {
  const outside = join(corpus.dir, "outside");
  rmSync(outside, { recursive: true, force: true });
  mkdirSync(outside);
  // Names with backslashes (oemName), as rar 4.x writes them on Unix too;
  // unar reads a "/" in a RAR4 name as part of the file name.
  const link = (name: string, target: string): Rar4Entry => ({ name: "", oemName: enc(name), unixSymlink: target });
  place("A Link (2008).rar", solidRar4([{ name: "Album/01.txt", data: TRACK }, link("Album/link", "../../outside")]));
  place("B Through Link (2008).rar", solidRar4([
    { name: "Album/01.txt", data: TRACK },
    link("Album/up", outside),
    { name: "Album/up/escaped.txt", data: TRACK2 },
  ]));
  const run = scan();
  expect(calls()).toHaveLength(2);
  expect(run.code).toBe(1);
  expect(run.actions).toEqual({ "A Link (2008).rar": "unpacked", "B Through Link (2008).rar": "failed" });
  expect(run.errors.map((e) => [e.code, e.path])).toEqual([["E_ARCHIVE", join(income, "B Through Link (2008).rar")]]);
  expect(run.errors[0]!.msg).toMatch(/^Album\/up\/escaped\.txt .*Failed! \(Could not create directory\)/);
  expect(tree(`${stem("A Link (2008).rar")}.unpacked`)).toEqual(new Map([["Album/01.txt", TRACK]]));
  expect(readdirSync(income).sort()).toEqual(["A Link (2008).rar", "A Link (2008).unpacked", "B Through Link (2008).rar"]);
  expect(readdirSync(outside)).toEqual([]);
});
