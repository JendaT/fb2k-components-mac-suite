// Archive tool choice and non-interactive runs. The CLI runs as a subprocess
// with a controlled PATH (Bun.which reads PATH at process start):
// - fake bsdtar / 7zz / 7z / unzip shell scripts on a temp PATH show which
//   tool is chosen and with which arguments, that a non-zero exit publishes
//   nothing, that a refused rar never reaches the tool, and that a rar's
//   extracted tree is checked against its headers whichever tool wrote it;
// - the real tools show why 7zz is preferred (a RAR 7 archive p7zip rejects)
//   and that an encrypted archive fails instead of prompting. The prompt only
//   blocks when there is a terminal, so those runs go through `script`, which
//   gives the CLI a pseudo-terminal.
// The real-tool tests need 7zz, 7z (p7zip) and unzip on PATH and fail, not
// skip, without them. The base PATH (SYS_PATH) is /bin plus a dir linking
// unzip: /usr/bin also holds bsdtar, which would take every rar.
// test/archive-rar.test.ts runs the real bsdtar.

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupCorpus, type Corpus } from "./helpers.ts";
import { buildRar4, buildRar5, buildRar5Stored } from "./rarbuild.ts";
import { buildZip } from "./zipbuild.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
let SYS_PATH: string; // sh, mkdir and unzip; no bsdtar, no 7-Zip

let corpus: Corpus;
let income: string;
let bins: string; // temp dirs holding fake tools or links to real ones
let fakeLog: string;

beforeAll(() => {
  corpus = setupCorpus();
  income = join(corpus.dir, "arc");
  bins = join(corpus.dir, "bins");
  fakeLog = join(corpus.dir, "fake.log");
  writeFileSync(
    join(corpus.rules, "income.yaml"),
    ["income:", "  - name: arc", `    path: ${income}`, "    source_type: web", ""].join("\n"),
  );
  const sys = join(bins, "sys");
  mkdirSync(sys, { recursive: true });
  symlinkSync("/usr/bin/unzip", join(sys, "unzip"));
  SYS_PATH = `${sys}:/bin`;
  for (const t of ["7z", "7zz", "bsdtar"]) {
    if (Bun.which(t, { PATH: SYS_PATH }) !== null) throw new Error(`${t} found on ${SYS_PATH}: the PATH isolation below would not hold`);
  }
});

beforeEach(() => {
  rmSync(income, { recursive: true, force: true });
  mkdirSync(income, { recursive: true });
  rmSync(fakeLog, { force: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

/**
 * A fake archive tool: logs its name and each argument in brackets, writes
 * $FAKE_NAME (default Album/fake.txt) holding $FAKE_DATA (default "x") into
 * its output dir (7-Zip's `-o<dir>`, unzip's `-d <dir>`, bsdtar's `-C <dir>`),
 * plus Album/extra.txt when $FAKE_EXTRA is set, and exits $FAKE_EXIT
 * (default 0).
 */
const FAKE = `#!/bin/sh
{ printf '%s ' "\${0##*/}"; for a in "$@"; do printf '[%s]' "$a"; done; echo; } >> "$FAKE_LOG"
out=
prev=
for a in "$@"; do
  case "$a" in -o?*) out="\${a#-o}";; esac
  [ "$prev" = "-d" ] && out="$a"
  [ "$prev" = "-C" ] && out="$a"
  prev="$a"
done
name="\${FAKE_NAME:-Album/fake.txt}"
mkdir -p "$out/\${name%/*}" && printf '%s' "\${FAKE_DATA:-x}" > "$out/$name"
[ -n "$FAKE_EXTRA" ] && printf y > "$out/Album/extra.txt"
exit "\${FAKE_EXIT:-0}"
`;

/** A valid rar listing exactly what FAKE writes by default: Album/fake.txt holding "x". */
const FAKE_RAR = buildRar5([{ name: "Album/fake.txt", data: new TextEncoder().encode("x") }]);

/** A bin dir holding fake tools (`fake`) and symlinks to real ones (`real`). */
function binDir(name: string, fake: string[], real: string[] = []): string {
  const dir = join(bins, name);
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(dir, { recursive: true });
  for (const t of fake) {
    writeFileSync(join(dir, t), FAKE);
    chmodSync(join(dir, t), 0o755);
  }
  for (const t of real) {
    const p = Bun.which(t);
    if (p === null) throw new Error(`this test needs ${t} on PATH`);
    symlinkSync(p, join(dir, t));
  }
  return dir;
}

interface Run {
  code: number | null;
  envelope: { ok: boolean; errors: { code: string; msg: string; path: string }[]; data: any[] };
}

function scan(path: string, extraEnv: Record<string, string> = {}): Run {
  const env = { PATH: path, INTAKE_RULES_DIR: corpus.rules, HOME: process.env.HOME ?? "/tmp", FAKE_LOG: fakeLog, ...extraEnv };
  const proc = Bun.spawnSync([process.execPath, "run", CLI, "scan", "arc", "--json"], { env, timeout: 60_000 });
  const out = proc.stdout.toString();
  if (!out.trim()) throw new Error(`no stdout; stderr: ${proc.stderr.toString()}`);
  return { code: proc.exitCode, envelope: JSON.parse(out) };
}

/** The same scan under a pseudo-terminal, killed if it has not finished in 20 s. */
function scanWithTty(path: string): { code: number | null; killed: boolean; envelope: Run["envelope"] | null } {
  const env = { PATH: path, INTAKE_RULES_DIR: corpus.rules, HOME: process.env.HOME ?? "/tmp" };
  const cli = [process.execPath, "run", CLI, "scan", "arc", "--json"];
  const argv =
    process.platform === "darwin"
      ? ["/usr/bin/script", "-q", "/dev/null", ...cli]
      : ["script", "-qec", cli.map((a) => `'${a.replaceAll("'", "'\\''")}'`).join(" "), "/dev/null"];
  const proc = Bun.spawnSync(argv, { env, timeout: 20_000, killSignal: "SIGKILL" });
  const killed = proc.exitCode === null;
  const out = proc.stdout.toString().replaceAll("\r", "");
  const start = out.indexOf("{");
  const end = out.lastIndexOf("}");
  return { code: proc.exitCode, killed, envelope: start >= 0 && end > start ? JSON.parse(out.slice(start, end + 1)) : null };
}

function placeArchive(name: string, bytes: Uint8Array = new Uint8Array([0x52, 0x61, 0x72, 0x21])): { path: string; stem: string } {
  const path = join(income, name);
  writeFileSync(path, bytes);
  return { path, stem: path.replace(/\.[^.]+$/, "") };
}

function fakeCalls(): string[] {
  return existsSync(fakeLog) ? readFileSync(fakeLog, "utf8").trim().split("\n") : [];
}

// ---- fake tools: which tool, which arguments, failure publishes nothing ----

test("without bsdtar, 7zz is preferred over 7z for .rar and .7z, run with -y, -bd and an empty -p", () => {
  const dir = binDir("both", ["7zz", "7z"]);
  const rar = placeArchive("Synthetic - Tools Rar (2021).rar", FAKE_RAR);
  const sz = placeArchive("Synthetic - Tools 7z (2021).7z");

  const { code, envelope } = scan(`${dir}:${SYS_PATH}`);
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(envelope.data[0].archives.map((a: { action: string }) => a.action)).toEqual(["unpacked", "unpacked"]);
  expect(fakeCalls()).toEqual([
    `7zz [x][-y][-bd][-p][-o${sz.stem}.unpacked.partial][${sz.path}]`,
    `7zz [x][-y][-bd][-p][-o${rar.stem}.unpacked.partial][${rar.path}]`,
  ]);
  expect(readFileSync(join(`${rar.stem}.unpacked`, "Album", "fake.txt"), "utf8")).toBe("x");
});

test("with only 7z on PATH, 7z is used", () => {
  const dir = binDir("only7z", ["7z"]);
  const rar = placeArchive("Synthetic - Tools Rar (2021).rar", FAKE_RAR);
  const { code, envelope } = scan(`${dir}:${SYS_PATH}`);
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(fakeCalls()).toEqual([`7z [x][-y][-bd][-p][-o${rar.stem}.unpacked.partial][${rar.path}]`]);
  expect(existsSync(join(`${rar.stem}.unpacked`, "Album", "fake.txt"))).toBe(true);
});

test("with no bsdtar, 7zz or 7z on PATH: tool_missing, E_ARCHIVE_TOOL, nothing created", () => {
  const rar = placeArchive("Synthetic - Tools Rar (2021).rar", FAKE_RAR);
  const { code, envelope } = scan(SYS_PATH);
  expect(envelope.errors.map((e) => [e.code, e.path])).toEqual([["E_ARCHIVE_TOOL", rar.path]]);
  expect(code).toBe(1);
  expect(envelope.data[0].archives[0].action).toBe("tool_missing");
  expect(readdirSync(income)).toEqual(["Synthetic - Tools Rar (2021).rar"]);
});

test("a tool that writes files and exits 2: failed, E_ARCHIVE, nothing published", () => {
  const dir = binDir("fails", ["7zz"]);
  const rar = placeArchive("Synthetic - Tools Rar (2021).rar", FAKE_RAR);
  const { code, envelope } = scan(`${dir}:${SYS_PATH}`, { FAKE_EXIT: "2" });
  expect(fakeCalls()).toHaveLength(1); // it ran, and wrote Album/fake.txt
  expect(envelope.errors.map((e) => [e.code, e.path])).toEqual([["E_ARCHIVE", rar.path]]);
  expect(code).toBe(1);
  expect(envelope.data[0].archives[0].action).toBe("failed");
  expect(readdirSync(income)).toEqual(["Synthetic - Tools Rar (2021).rar"]);
});

const BSDTAR_FLAGS = "[--no-same-owner][--no-same-permissions][--no-acls][--no-xattrs][--no-fflags][--no-mac-metadata]";

test("rar goes to bsdtar when it is on PATH, before 7zz and 7z, with flags for untrusted input", () => {
  const dir = binDir("rar-bsdtar", ["bsdtar", "7zz", "7z"]);
  const rar = placeArchive("Synthetic - Tools Rar (2021).rar", FAKE_RAR);
  const sz = placeArchive("Synthetic - Tools 7z (2021).7z");
  const { code, envelope } = scan(`${dir}:${SYS_PATH}`);
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(fakeCalls()).toEqual([
    `7zz [x][-y][-bd][-p][-o${sz.stem}.unpacked.partial][${sz.path}]`,
    `bsdtar [-x][-f][${rar.path}][-C][${rar.stem}.unpacked.partial]${BSDTAR_FLAGS}`,
  ]);
  expect(readFileSync(join(`${rar.stem}.unpacked`, "Album", "fake.txt"), "utf8")).toBe("x");
});

test("plain OEM RAR4 names: bsdtar gets the chosen code page as rar:hdrcharset, the names are checked decoded", () => {
  const dir = binDir("rar-oem", ["bsdtar"]);
  const name = "Café Ñandú/fake.txt"; // cp437 bytes 0x82, 0xA5, 0xA3: not all Latin-1 letters, so cp437
  const rar = placeArchive("Synthetic - Oem Names (2009).rar", buildRar4([{ name, data: new TextEncoder().encode("x") }]));
  const { code, envelope } = scan(`${dir}:${SYS_PATH}`, { FAKE_NAME: name });
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(fakeCalls()).toEqual([
    `bsdtar [-x][-f][${rar.path}][-C][${rar.stem}.unpacked.partial]${BSDTAR_FLAGS}[--options][rar:hdrcharset=CP437]`,
  ]);
});

test("a refused rar never reaches the tool: failed, E_ARCHIVE with the reason, nothing created", () => {
  const dir = binDir("rar-refused", ["bsdtar", "7zz"]);
  const data = new TextEncoder().encode("x");
  const cases = [
    { file: "A Encrypted.rar", bytes: buildRar5([{ name: "Album/01.flac", data, encrypted: true }]), msg: 'rar entry "Album/01.flac": encrypted' },
    { file: "B Blake.rar", bytes: buildRar5([{ name: "Album/01.flac", data, blake2: new Uint8Array(32) }]), msg: 'rar entry "Album/01.flac": BLAKE2 hash only, cannot verify' },
    { file: "C Locked Headers.rar", bytes: buildRar5([], { encryptedHeaders: true }), msg: "header-encrypted rar is not supported" },
    { file: "D Volume.rar", bytes: buildRar4([{ name: "Album/01.flac", data, splitAfter: true }], { volume: true }), msg: "multi-volume rar is not supported" },
    { file: "E Junk.rar", bytes: new Uint8Array([0x52, 0x61, 0x72, 0x21]), msg: "not a rar archive: no RAR signature at the start" },
  ];
  for (const c of cases) placeArchive(c.file, c.bytes);
  const { code, envelope } = scan(`${dir}:${SYS_PATH}`);
  expect(fakeCalls()).toEqual([]);
  expect(envelope.errors.map((e) => [e.code, e.msg, e.path])).toEqual(cases.map((c) => ["E_ARCHIVE", c.msg, join(income, c.file)]));
  expect(code).toBe(1);
  expect(readdirSync(income).sort()).toEqual(cases.map((c) => c.file));
});

for (const c of [
  { label: "wrong data", env: { FAKE_DATA: "y" }, msg: 'rar entry "Album/fake.txt": CRC32 mismatch' },
  { label: "wrong size", env: { FAKE_DATA: "xx" }, msg: 'rar entry "Album/fake.txt": size mismatch (header 1, extracted 2)' },
  {
    label: "an extra file",
    env: { FAKE_EXTRA: "1" },
    msg: 'rar extraction wrote "Album/extra.txt", which is not in the archive headers',
  },
  {
    label: "a missing entry",
    env: { FAKE_NAME: "Album/other.txt" },
    msg: 'rar entry "Album/fake.txt": missing after extraction (+1 more)',
  },
] as { label: string; env: Record<string, string>; msg: string }[]) {
  test(`7zz exits 0 but writes ${c.label}: the header check fails the rar, nothing published`, () => {
    const dir = binDir("rar-verify", ["7zz"]);
    const rar = placeArchive("Synthetic - Verify (2021).rar", FAKE_RAR);
    const { code, envelope } = scan(`${dir}:${SYS_PATH}`, c.env);
    expect(fakeCalls()).toHaveLength(1);
    expect(envelope.errors.map((e) => [e.code, e.msg, e.path])).toEqual([["E_ARCHIVE", c.msg, rar.path]]);
    expect(code).toBe(1);
    expect(readdirSync(income)).toEqual(["Synthetic - Verify (2021).rar"]);
  });
}

test("zip routing: ASCII names go to unzip, non-ASCII UTF-8 names to 7zz on the zip itself", () => {
  const dir = binDir("zip-route", ["7zz", "unzip"]);
  const data = new TextEncoder().encode("x");
  const ascii = placeArchive("Synthetic - Ascii Names (2020).zip", buildZip([{ name: "Plain Album/01 Track.flac", data }]));
  const utf8 = placeArchive(
    "Synthetic - Utf8 Names (2020).zip",
    buildZip([{ name: "Café Album/01 Track.flac", data, utf8Flag: true }]),
  );
  const { code, envelope } = scan(`${dir}:${SYS_PATH}`);
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(fakeCalls()).toEqual([
    `unzip [-qq][-o][-P][][${ascii.path}][-d][${ascii.stem}.unpacked.partial]`,
    `7zz [x][-y][-bd][-p][-o${utf8.stem}.unpacked.partial][${utf8.path}]`,
  ]);
  expect(existsSync(join(`${ascii.stem}.unpacked`, "Album", "fake.txt"))).toBe(true);
  expect(existsSync(join(`${utf8.stem}.unpacked`, "Album", "fake.txt"))).toBe(true);
});

test("zip routing: with only 7z on PATH, non-ASCII names go to 7z", () => {
  const dir = binDir("zip-route-7z", ["7z", "unzip"]);
  const utf8 = placeArchive(
    "Synthetic - Utf8 Names (2020).zip",
    buildZip([{ name: "Café Album/01 Track.flac", data: new TextEncoder().encode("x"), utf8Flag: true }]),
  );
  const { code, envelope } = scan(`${dir}:${SYS_PATH}`);
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(fakeCalls()).toEqual([`7z [x][-y][-bd][-p][-o${utf8.stem}.unpacked.partial][${utf8.path}]`]);
});

// ---- real tools ----

test("RAR 7 algorithm version: 7zz extracts it; p7zip alone fails with Unsupported Method", () => {
  const payload = new TextEncoder().encode("synthetic payload\n".repeat(64));
  const rar = placeArchive("Synthetic - Rar Seven (2024).rar", buildRar5Stored("Album/01 - Track.txt", payload, 1));

  const both = scan(`${binDir("real-both", [], ["7zz", "7z"])}:${SYS_PATH}`);
  expect(both.envelope.errors).toEqual([]);
  expect(both.envelope.data[0].archives[0].action).toBe("unpacked");
  expect(new Uint8Array(readFileSync(join(`${rar.stem}.unpacked`, "Album", "01 - Track.txt")))).toEqual(payload);

  rmSync(`${rar.stem}.unpacked`, { recursive: true });
  const p7zip = scan(`${binDir("real-7z", [], ["7z"])}:${SYS_PATH}`);
  expect(p7zip.envelope.errors.map((e) => [e.code, e.path])).toEqual([["E_ARCHIVE", rar.path]]);
  expect(p7zip.envelope.errors[0]!.msg).toContain("Unsupported Method");
  expect(readdirSync(income)).toEqual(["Synthetic - Rar Seven (2024).rar"]);
});

/** Build an encrypted archive with the real 7zz (password "secret"). */
function encrypted(name: string, type: "7z" | "zip"): { path: string; stem: string } {
  const stage = join(corpus.dir, "enc-stage");
  rmSync(stage, { recursive: true, force: true });
  mkdirSync(join(stage, "Album"), { recursive: true });
  writeFileSync(join(stage, "Album", "01 - Track.txt"), "secret payload\n".repeat(64));
  const path = join(income, name);
  const sevenZz = Bun.which("7zz");
  if (sevenZz === null) throw new Error("this test needs 7zz on PATH");
  const args = type === "7z" ? ["-t7z", "-mhe=on"] : ["-tzip"];
  const r = Bun.spawnSync([sevenZz, "a", "-bd", ...args, "-psecret", path, "Album"], { cwd: stage, stdout: "ignore" });
  if (r.exitCode !== 0) throw new Error(`7zz a failed: ${r.stderr.toString()}`);
  return { path, stem: path.replace(/\.[^.]+$/, "") };
}

for (const c of [
  { label: "7z archive, p7zip only", type: "7z" as const, real: ["7z"] },
  { label: "7z archive, 7zz preferred", type: "7z" as const, real: ["7zz", "7z"] },
  { label: "zip archive, unzip", type: "zip" as const, real: [] },
]) {
  test(`encrypted ${c.label}: fails with a password error, without prompting, nothing published`, () => {
    const arc = encrypted(`Synthetic - Locked (2022).${c.type}`, c.type);
    const path = c.real.length > 0 ? `${binDir(`enc-${c.real.join("-")}`, [], c.real)}:${SYS_PATH}` : SYS_PATH;
    const run = scanWithTty(path);
    expect(run.killed).toBe(false); // a password prompt would block until the 20 s kill
    const errors = run.envelope?.errors ?? [];
    expect(errors.map((e) => [e.code, e.path])).toEqual([["E_ARCHIVE", arc.path]]);
    if (c.type === "7z") expect(errors[0]!.msg).toMatch(/wrong password/i);
    expect(run.code).toBe(1);
    expect(readdirSync(income)).toEqual([`Synthetic - Locked (2022).${c.type}`]);
  }, 30_000);
}
