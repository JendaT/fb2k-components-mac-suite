// Envelope invariants the component parses against (doc 03 § JSON conventions,
// as CR-EXT-001 CR-1 proposes tightening them). Driven through the real CLI,
// because this is about what lands on stdout, not what a function returns:
//
//   - every --json invocation emits exactly one JSON object, never a bare array
//   - ok is true iff the exit code is 0
//   - exit 2 carries data: null; exit 1 carries the successful subset
//   - reserved host-synthesized codes are never emitted by the CLI
//
// If doc 03 is amended differently, this file is the thing to change.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { setupCorpus, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const SRC = join(import.meta.dir, "..", "src");

let corpus: Corpus;

interface Envelope {
  ok: boolean;
  data: unknown;
  errors: { code: string; msg: string; path: string | null }[];
}

function run(args: string[]): { code: number; envelope: Envelope; stdout: string } {
  const proc = Bun.spawnSync([process.execPath, "run", CLI, ...args, "--json"], {
    env: { ...process.env, INTAKE_RULES_DIR: corpus.rules },
  });
  const stdout = proc.stdout.toString();
  return { code: proc.exitCode, envelope: JSON.parse(stdout) as Envelope, stdout };
}

beforeAll(() => {
  corpus = setupCorpus();
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

// Commands covering exit 0 (payload), exit 2 via fail(), and exit 2 via
// "nothing matched" — the two exit-2 routes that used to disagree.
const CASES: { args: string[]; exit: number }[] = [
  { args: ["version"], exit: 0 },
  { args: ["status"], exit: 0 },
  { args: ["collections"], exit: 0 },
  { args: ["scan", "--all"], exit: 0 },
  { args: ["frobnicate"], exit: 2 },
  { args: ["scan", "nope"], exit: 2 },
  { args: ["resolve", "/nonexistent/nowhere"], exit: 2 },
  { args: ["identify", "itk_deadbeef"], exit: 2 },
  { args: ["assign", "itk_deadbeef"], exit: 2 },
  { args: ["propose", "itk_deadbeef"], exit: 2 },
  { args: ["approve", "itk_deadbeef"], exit: 2 },
  { args: ["reject", "itk_deadbeef"], exit: 2 },
];

test("every --json invocation emits exactly one envelope object", () => {
  for (const c of CASES) {
    const { stdout, envelope } = run(c.args);
    expect(stdout.trimEnd().split("\n").length).toBe(1); // one line, one document
    expect(stdout.trimStart().startsWith("{")).toBe(true); // never a bare array
    expect(Object.keys(envelope).sort()).toEqual(["data", "errors", "ok"]);
    expect(Array.isArray(envelope.errors)).toBe(true);
  }
});

test("ok is true iff exit 0; exit 2 carries a null payload", () => {
  for (const c of CASES) {
    const { code, envelope } = run(c.args);
    expect({ args: c.args.join(" "), code }).toEqual({ args: c.args.join(" "), code: c.exit });
    expect(envelope.ok).toBe(code === 0);
    expect(envelope.errors.length === 0).toBe(code === 0);
    if (code === 2) expect(envelope.data).toBeNull();
    else expect(envelope.data).not.toBeNull();
  }
});

test("exit 1 is partial: the successful subset plus the errors", () => {
  // One unreadable sidecar among many: status still returns the rows it could
  // read, and says what it could not.
  const victim = join(
    corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)", ".intake.json",
  );
  run(["scan", "--all"]); // populate sidecars
  Bun.write(victim, "{ this is not json");

  const { code, envelope } = run(["status"]);
  expect(code).toBe(1);
  expect(envelope.ok).toBe(false);
  expect(envelope.errors.map((e) => e.code)).toEqual(["E_PARSE"]);
  expect(Array.isArray(envelope.data)).toBe(true);
  expect((envelope.data as unknown[]).length).toBeGreaterThan(0); // the subset that parsed
});

test("host-synthesized codes are reserved: the CLI never emits them", () => {
  const reserved = ["E_NO_CLI", "E_CLI_TIMEOUT"];
  const sources = readdirSync(SRC).filter((n) => n.endsWith(".ts"));
  expect(sources.length).toBeGreaterThan(10);
  for (const name of sources) {
    const text = readFileSync(join(SRC, name), "utf8");
    for (const code of reserved) {
      expect({ file: name, emits: text.includes(`"${code}"`) }).toEqual({ file: name, emits: false });
    }
  }
});
