// Archive tool choice and non-interactive runs. The CLI runs as a subprocess
// with a controlled PATH (Bun.which reads PATH at process start):
// - fake 7zz / 7z shell scripts on a temp PATH show which tool is chosen and
//   with which arguments, and that a non-zero exit publishes nothing;
// - the real tools show why 7zz is preferred (a RAR 7 archive p7zip rejects)
//   and that an encrypted archive fails instead of prompting. The prompt only
//   blocks when there is a terminal, so those runs go through `script`, which
//   gives the CLI a pseudo-terminal.
// The real-tool tests need 7zz, 7z (p7zip) and unzip on PATH and fail, not
// skip, without them.

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupCorpus, type Corpus } from "./helpers.ts";
import { buildRar5Stored } from "./rarbuild.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const SYS_PATH = "/usr/bin:/bin"; // has unzip, sh, mkdir; no 7-Zip

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
  for (const t of ["7z", "7zz"]) {
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
 * Album/fake.txt into its `-o` dir, exits $FAKE_EXIT (default 0).
 */
const FAKE = `#!/bin/sh
{ printf '%s ' "\${0##*/}"; for a in "$@"; do printf '[%s]' "$a"; done; echo; } >> "$FAKE_LOG"
out=
for a in "$@"; do case "$a" in -o*) out="\${a#-o}";; esac; done
mkdir -p "$out/Album" && printf x > "$out/Album/fake.txt"
exit "\${FAKE_EXIT:-0}"
`;

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

test("7zz is preferred over 7z for .rar and .7z, run with -y, -bd and an empty -p", () => {
  const dir = binDir("both", ["7zz", "7z"]);
  const rar = placeArchive("Synthetic - Tools Rar (2021).rar");
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
  const rar = placeArchive("Synthetic - Tools Rar (2021).rar");
  const { code, envelope } = scan(`${dir}:${SYS_PATH}`);
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(fakeCalls()).toEqual([`7z [x][-y][-bd][-p][-o${rar.stem}.unpacked.partial][${rar.path}]`]);
  expect(existsSync(join(`${rar.stem}.unpacked`, "Album", "fake.txt"))).toBe(true);
});

test("with neither 7zz nor 7z on PATH: tool_missing, E_ARCHIVE_TOOL, nothing created", () => {
  const rar = placeArchive("Synthetic - Tools Rar (2021).rar");
  const { code, envelope } = scan(SYS_PATH);
  expect(envelope.errors.map((e) => [e.code, e.path])).toEqual([["E_ARCHIVE_TOOL", rar.path]]);
  expect(code).toBe(1);
  expect(envelope.data[0].archives[0].action).toBe("tool_missing");
  expect(readdirSync(income)).toEqual(["Synthetic - Tools Rar (2021).rar"]);
});

test("a tool that writes files and exits 2: failed, E_ARCHIVE, nothing published", () => {
  const dir = binDir("fails", ["7zz"]);
  const rar = placeArchive("Synthetic - Tools Rar (2021).rar");
  const { code, envelope } = scan(`${dir}:${SYS_PATH}`, { FAKE_EXIT: "2" });
  expect(fakeCalls()).toHaveLength(1); // it ran, and wrote Album/fake.txt
  expect(envelope.errors.map((e) => [e.code, e.path])).toEqual([["E_ARCHIVE", rar.path]]);
  expect(code).toBe(1);
  expect(envelope.data[0].archives[0].action).toBe("failed");
  expect(readdirSync(income)).toEqual(["Synthetic - Tools Rar (2021).rar"]);
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
