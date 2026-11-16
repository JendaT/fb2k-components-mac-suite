// rar extraction with the real bsdtar (/usr/bin/bsdtar, libarchive), whose
// exit code cannot be trusted for rar: intake reads the headers first and
// refuses what it cannot verify, then checks every extracted data entry
// against its header CRC32 (src/rarheaders.ts). Archives are built in the
// test (test/rarbuild.ts); no `rar` binary.
//
// The CLI runs as a subprocess with PATH = a wrapper dir, /usr/bin and /bin:
// no 7-Zip, so every rar goes to bsdtar. The wrapper logs each call and execs
// /usr/bin/bsdtar, so a test can show that a refused archive never reached
// it. Every run is killed after 20 s (a password prompt would block until
// then); the encrypted cases run under a pseudo-terminal (`script`), where a
// prompt would really wait. Every case checks that neither a `.partial` nor,
// for a failure, an `.unpacked` dir is left.

import { afterAll, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { setupCorpus, type Corpus } from "./helpers.ts";
import { buildRar4, buildRar5 } from "./rarbuild.ts";
import { rawName } from "./zipbuild.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const BSDTAR = "/usr/bin/bsdtar";

let corpus: Corpus;
let income: string;
let callLog: string;
let PATH: string;

const enc = (s: string) => new TextEncoder().encode(s);
const TRACK = enc("synthetic payload\n".repeat(64));
const BIG = Uint8Array.from({ length: 300_000 }, (_, i) => (i * 7919 + (i >> 9)) & 0xff); // several read chunks

beforeAll(() => {
  corpus = setupCorpus();
  income = join(corpus.dir, "arc");
  callLog = join(corpus.dir, "bsdtar.log");
  writeFileSync(
    join(corpus.rules, "income.yaml"),
    ["income:", "  - name: arc", `    path: ${income}`, "    source_type: web", ""].join("\n"),
  );
  const wrap = join(corpus.dir, "wrap");
  mkdirSync(wrap, { recursive: true });
  writeFileSync(
    join(wrap, "bsdtar"),
    `#!/bin/sh\n{ printf bsdtar; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$CALL_LOG"\nexec ${BSDTAR} "$@"\n`,
  );
  chmodSync(join(wrap, "bsdtar"), 0o755);
  PATH = `${wrap}:/usr/bin:/bin`;
  for (const t of ["7z", "7zz"]) {
    if (Bun.which(t, { PATH }) !== null) throw new Error(`${t} found on ${PATH}: rar would not be bsdtar's alone`);
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

const calls = (): string[] => (existsSync(callLog) ? readFileSync(callLog, "utf8").trim().split("\n") : []);
const stem = (name: string) => join(income, name.replace(/\.rar$/, ""));

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

describe.skipIf(!existsSync(BSDTAR))("rar with bsdtar", () => {
  // ---- refused or failed ----

  test("RAR5 stored member with a bad CRC32: bsdtar exits 0, the CRC check fails it", () => {
    place("Synthetic - Bad Crc (2020).rar", buildRar5([
      { name: "Album/01 - Good.txt", data: TRACK },
      { name: "Album/02 - Bad.txt", data: TRACK, badCrc: true },
    ]));
    const run = scan();
    expect(calls()).toHaveLength(1);
    expectFailed(run, [{ file: "Synthetic - Bad Crc (2020).rar", msg: 'rar entry "Album/02 - Bad.txt": CRC32 mismatch' }]);
  });

  test("RAR5 stored and file-encrypted: refused before extraction, nothing written, no prompt", () => {
    place("Synthetic - Locked (2020).rar", buildRar5([{ name: "Album/01 - Track.txt", data: TRACK, encrypted: true }]));
    const run = scan(true);
    expect(calls()).toEqual([]);
    expectFailed(run, [{ file: "Synthetic - Locked (2020).rar", msg: 'rar entry "Album/01 - Track.txt": encrypted' }]);
  }, 30_000);

  test("RAR4 file-encrypted: refused before extraction, no prompt", () => {
    place("Synthetic - Locked Four (2008).rar", buildRar4([{ name: "Album/01 - Track.txt", data: TRACK, encrypted: true }]));
    const run = scan(true);
    expect(calls()).toEqual([]);
    expectFailed(run, [{ file: "Synthetic - Locked Four (2008).rar", msg: 'rar entry "Album/01 - Track.txt": encrypted' }]);
  }, 30_000);

  test("RAR5 BLAKE2-only: refused, it has no CRC32 to verify", () => {
    place("Synthetic - Blake (2020).rar", buildRar5([{ name: "Album/01 - Track.txt", data: TRACK, blake2: new Uint8Array(32).fill(0x5a) }]));
    const run = scan();
    expect(calls()).toEqual([]);
    expectFailed(run, [{ file: "Synthetic - Blake (2020).rar", msg: 'rar entry "Album/01 - Track.txt": BLAKE2 hash only, cannot verify' }]);
  });

  test("RAR4 stored member with a bad CRC: bsdtar exits 0, the CRC check fails it", () => {
    place("Synthetic - Bad Crc Four (2008).rar", buildRar4([{ name: "Album/01 - Track.txt", data: TRACK, badCrc: true }]));
    const run = scan();
    expect(calls()).toHaveLength(1);
    expectFailed(run, [{ file: "Synthetic - Bad Crc Four (2008).rar", msg: 'rar entry "Album/01 - Track.txt": CRC32 mismatch' }]);
  });

  test("RAR4 compressed member with a bad CRC: bsdtar fails it itself", () => {
    place("Synthetic - Bad Crc M3 (2008).rar", buildRar4([{ name: "Album/01 - Track.txt", data: TRACK, badCrc: true, compressed: true }]));
    const run = scan();
    expect(calls()).toHaveLength(1);
    expectFailed(run, [{ file: "Synthetic - Bad Crc M3 (2008).rar", msg: /File CRC error/ }]);
  });

  test("first part of a multi-volume set: refused by RAR5 and RAR4 volume flags and by a .partN.rar name", () => {
    const msg = "multi-volume rar is not supported";
    place("Synthetic - Volume Five (2020).rar", buildRar5([{ name: "Album/01.txt", data: TRACK, splitAfter: true }], { volume: true }));
    place("Synthetic - Volume Four (2008).rar", buildRar4([{ name: "Album/01.txt", data: TRACK, splitAfter: true }], { volume: true }));
    place("Synthetic - Named (2020).part1.rar", buildRar5([{ name: "Album/01.txt", data: TRACK }]));
    const run = scan();
    expect(calls()).toEqual([]);
    expectFailed(run, [
      { file: "Synthetic - Volume Five (2020).rar", msg },
      { file: "Synthetic - Volume Four (2008).rar", msg },
      { file: "Synthetic - Named (2020).part1.rar", msg },
    ]);
  });

  test("header-encrypted RAR5 and RAR4: refused, no prompt", () => {
    const msg = "header-encrypted rar is not supported";
    place("Synthetic - Hidden Five (2020).rar", buildRar5([], { encryptedHeaders: true }));
    place("Synthetic - Hidden Four (2008).rar", buildRar4([], { encryptedHeaders: true }));
    const run = scan(true);
    expect(calls()).toEqual([]);
    expectFailed(run, [
      { file: "Synthetic - Hidden Five (2020).rar", msg },
      { file: "Synthetic - Hidden Four (2008).rar", msg },
    ]);
  }, 30_000);

  test("RAR5 hard link, file copy and junction entries: refused (libarchive writes a link or a 0-byte file)", () => {
    const entry = (type: 3 | 4 | 5) => buildRar5([
      { name: "Album/01.txt", data: TRACK },
      { name: "Album/02.txt", redirect: { type, target: "Album/01.txt" } },
    ]);
    place("A Hardlink.rar", entry(4));
    place("B Copy.rar", entry(5));
    place("C Junction.rar", entry(3));
    const run = scan();
    expect(calls()).toEqual([]);
    expectFailed(run, [
      { file: "A Hardlink.rar", msg: 'rar entry "Album/02.txt": hard link entry, not supported' },
      { file: "B Copy.rar", msg: 'rar entry "Album/02.txt": file copy entry, not supported' },
      { file: "C Junction.rar", msg: 'rar entry "Album/02.txt": junction entry, not supported' },
    ]);
  });

  test("damaged headers, unsafe and duplicate paths: refused", () => {
    const good = buildRar5([{ name: "Album/01.txt", data: TRACK }]);
    const flipped = good.slice();
    flipped[30]! ^= 0x01; // inside the file header (after signature 8 + main header 8)
    place("A Flipped.rar", flipped);
    place("B Truncated.rar", good.slice(0, good.length - 200)); // cut inside the data area
    place("C Dotdot.rar", buildRar5([{ name: "../escape.txt", data: TRACK }]));
    place("D Absolute.rar", buildRar4([{ name: "/abs/x.txt", data: TRACK }]));
    place("E Duplicate.rar", buildRar5([{ name: "Album/01.txt", data: TRACK }, { name: "Album/./01.txt", data: TRACK }]));
    const run = scan();
    expect(calls()).toEqual([]);
    expectFailed(run, [
      { file: "A Flipped.rar", msg: "damaged rar headers: header CRC mismatch at offset 16" },
      { file: "B Truncated.rar", msg: "damaged rar headers: data area runs past the end of the file at offset 16" },
      { file: "C Dotdot.rar", msg: 'rar entry "../escape.txt": unsafe path (..)' },
      { file: "D Absolute.rar", msg: 'rar entry "/abs/x.txt": unsafe path (absolute)' },
      { file: "E Duplicate.rar", msg: 'rar entry "Album/01.txt": duplicate path' },
    ]);
  });

  test("solid RAR4: refused before extraction (libarchive 3.7.4 writes the first member, then fails)", () => {
    const entries = [
      { name: "Album/01.txt", data: TRACK, compressed: true },
      { name: "Album/02.txt", data: TRACK, compressed: true, solid: true },
    ];
    place("A Solid (2008).rar", buildRar4(entries, { solid: true })); // main flags 0x0008
    place("B Solid Locked (2008).rar", buildRar4(entries, { solid: true, locked: true })); // 0x000c
    place("C Solid Entry (2008).rar", buildRar4(entries)); // LHD_SOLID on a non-solid main header
    const run = scan();
    expect(calls()).toEqual([]);
    expectFailed(run, [
      { file: "A Solid (2008).rar", msg: "solid RAR4 is not supported" },
      { file: "B Solid Locked (2008).rar", msg: "solid RAR4 is not supported" },
      { file: "C Solid Entry (2008).rar", msg: 'solid RAR4 is not supported (entry "Album/02.txt" continues a solid stream)' },
    ]);
  });

  test("locked, non-solid RAR4 still extracts", () => {
    const file = "Synthetic - Locked Four (2008).rar";
    place(file, buildRar4([{ name: "Album/01.txt", data: TRACK, compressed: true }], { locked: true }));
    expectUnpacked(scan(), [{ file, files: { "Album/01.txt": TRACK } }]);
  });

  // ---- extracted and verified ----

  test("RAR5 stored and compressed members extract and verify; bsdtar runs with the untrusted-input flags", () => {
    const file = "Synthetic - Five (2020).rar";
    const path = place(file, buildRar5([
      { name: "Album/01 - Stored.txt", data: TRACK },
      { name: "Album/02 - Stored Big.bin", data: BIG },
      { name: "Album/03 - Compressed.txt", data: TRACK, compressed: true },
      { name: "Album/04 - Compressed Big.bin", data: BIG, compressed: true },
    ]));
    const run = scan();
    expect(calls()).toEqual([
      `bsdtar [-x] [-f] [${path}] [-C] [${stem(file)}.unpacked.partial] [--no-same-owner] [--no-same-permissions] ` +
        "[--no-acls] [--no-xattrs] [--no-fflags] [--no-mac-metadata]",
    ]);
    expectUnpacked(run, [{
      file,
      files: {
        "Album/01 - Stored.txt": TRACK,
        "Album/02 - Stored Big.bin": BIG,
        "Album/03 - Compressed.txt": TRACK,
        "Album/04 - Compressed Big.bin": BIG,
      },
    }]);
  });

  test("RAR4 stored and compressed members extract and verify", () => {
    const file = "Synthetic - Four (2008).rar";
    place(file, buildRar4([
      { name: "Album/01 - Stored.txt", data: TRACK },
      { name: "Album/02 - Stored Big.bin", data: BIG },
      { name: "Album/03 - Compressed.txt", data: TRACK, compressed: true },
      { name: "Album/04 - Compressed Big.bin", data: BIG, compressed: true },
    ]));
    const run = scan();
    expectUnpacked(run, [{
      file,
      files: {
        "Album/01 - Stored.txt": TRACK,
        "Album/02 - Stored Big.bin": BIG,
        "Album/03 - Compressed.txt": TRACK,
        "Album/04 - Compressed Big.bin": BIG,
      },
    }]);
  });

  test("RAR4 non-ASCII names: Unicode-flagged, UTF-8 and plain OEM (cp437, cp1252) extract under their names", () => {
    const uni = "Dvořák – ŘŘ Ünïcode/01 Česká píseň ☃.txt"; // every op of RAR's Unicode name encoding
    // cp437 bytes; cp852 reads Ñ as ą and ½ as ź (a letter standing alone):
    // cp437 and cp852 tie, and the order picks cp437.
    const oem437 = "Café Ñandú/01 Über ½.txt";
    // cp1252 bytes; cp1250 reads Ñ as Ń: a tie, and the order picks cp1252.
    const oem1252 = "Café Ñandú/01 Über.txt";
    place("A Unicode (2008).rar", buildRar4([{ name: uni, data: TRACK, names: "unicode", compressed: true }]));
    place("B Utf8 (2008).rar", buildRar4([{ name: "Sinfonía Ñ/01 Über.txt", data: TRACK, names: "utf8" }]));
    place("C Oem437 (2008).rar", buildRar4([{ name: oem437, data: TRACK }]));
    place("D Oem1252 (2008).rar", buildRar4([{ name: oem1252, data: TRACK, codePage: 1252 }]));
    const run = scan();
    const options = calls().map((c) => c.match(/\[--options\] \[([^\]]*)\]/)?.[1] ?? null);
    expect(options).toEqual([null, null, "rar:hdrcharset=CP437", "rar:hdrcharset=CP1252"]);
    expectUnpacked(run, [
      { file: "A Unicode (2008).rar", files: { [uni]: TRACK } },
      { file: "B Utf8 (2008).rar", files: { "Sinfonía Ñ/01 Über.txt": TRACK } },
      { file: "C Oem437 (2008).rar", files: { [oem437]: TRACK } },
      { file: "D Oem1252 (2008).rar", files: { [oem1252]: TRACK } },
    ]);
  });

  test("RAR4 plain OEM names in cp852 (Białowieża) and cp1250 go to bsdtar as CP852 / CP1250 and pass the name and CRC check", () => {
    // Raw name bytes, as in the zip tests (.txt, so no root resolves): a3 = ú
    // (cp437 and cp852), 88 = ł and be = ż (cp852 only); ec = ě, f9 = ů,
    // f2 = ň, b3 = ł (cp1250).
    const buho = rawName("Synthetic B", [0xa3], "ho/06 Bia", [0x88], "owie", [0xbe], "a.txt");
    const czech = rawName("Synthetic M", [0xec], "s", [0xed], "c/02 Bia", [0xb3], "y K", [0xf9, 0xf2], ".txt");
    place("Synthetic Búho.rar", buildRar4([{ name: "", oemName: buho, data: TRACK }]));
    place("Synthetic - Czech ANSI (2003).rar", buildRar4([{ name: "", oemName: czech, data: BIG, compressed: true }]));
    const run = scan();
    const options = calls().map((c) => c.match(/\[--options\] \[([^\]]*)\]/)?.[1] ?? null);
    expect(options).toEqual(["rar:hdrcharset=CP1250", "rar:hdrcharset=CP852"]);
    expectUnpacked(run, [
      { file: "Synthetic Búho.rar", files: { "Synthetic Búho/06 Białowieża.txt": TRACK } },
      { file: "Synthetic - Czech ANSI (2003).rar", files: { "Synthetic Měsíc/02 Biały Kůň.txt": BIG } },
    ]);
  });

  test("RAR5 non-ASCII names (NFC and NFD in the header) extract under their names", () => {
    const nfc = "Dvořák – Ünïcode/01 Česká píseň ☃.txt";
    place("A Nfc (2020).rar", buildRar5([{ name: nfc, data: TRACK, compressed: true }]));
    place("B Nfd (2020).rar", buildRar5([{ name: "Café Ñ/01.txt".normalize("NFD"), data: TRACK }]));
    const run = scan();
    expectUnpacked(run, [
      { file: "A Nfc (2020).rar", files: { [nfc]: TRACK } },
      { file: "B Nfd (2020).rar", files: { "Café Ñ/01.txt": TRACK } },
    ]);
  });

  test("directory and symlink entries carry no data: not verified, the symlinks stripped", () => {
    place("A Five (2020).rar", buildRar5([
      { name: "Album", dir: true },
      { name: "Album/Empty", dir: true },
      { name: "Album/01.txt", data: TRACK },
      { name: "Album/link", redirect: { type: 1, target: "../../outside" } },
    ]));
    place("B Four (2008).rar", buildRar4([
      { name: "Album", dir: true },
      { name: "Album/01.txt", data: TRACK },
      { name: "Album/link", unixSymlink: "../../outside" },
    ]));
    const run = scan();
    expectUnpacked(run, [
      { file: "A Five (2020).rar", files: { "Album/01.txt": TRACK } },
      { file: "B Four (2008).rar", files: { "Album/01.txt": TRACK } },
    ]);
    expect(existsSync(join(`${stem("A Five (2020).rar")}.unpacked`, "Album", "Empty"))).toBe(true);
  });
});
