// Doc 03 v1.2 additive surface (amendment 003): `intake income` (CR-004.7),
// `commands` in `version` data (CR-004.10), and `proposal.assigned_by` /
// `proposal.target_path` in the status summary (CR-004.11, CR-004.12).

import { afterAll, beforeAll, expect, test } from "bun:test";
import { cpSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cmdScan } from "../src/commands.ts";
import { cmdAssign } from "../src/commands-p2.ts";
import type { Providers } from "../src/providers.ts";
import { readSidecar } from "../src/sidecar.ts";
import { setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const OPTS = { json: true, dryRun: false, force: false, filters: {}, all: false, collection: null, by: null };
const OFFLINE: { providers: Providers } = { providers: { discogs: null, similar: null, shim: null } };
/** Doc 03 command surface, in its order. */
const SURFACE = [
  "scan", "resolve", "identify", "assign", "propose", "approve", "reject", "execute", "gc",
  "status", "collections", "income", "version", "bootstrap",
];

let corpus: Corpus;

function run(args: string[], rules = corpus.rules) {
  const proc = Bun.spawnSync([process.execPath, "run", CLI, ...args], {
    env: { ...process.env, INTAKE_RULES_DIR: rules },
  });
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
}
const json = (args: string[], rules = corpus.rules) => {
  const r = run([...args, "--json"], rules);
  return { code: r.code, env: JSON.parse(r.stdout) };
};

beforeAll(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  await cmdScan([], { ...OPTS, all: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

// ---- income ---------------------------------------------------------------------

test("income --json: every income.yaml folder in file order, path absolute, exists", () => {
  const before = treeHash(corpus.dir);
  const { code, env } = json(["income"]);
  expect(code).toBe(0);
  expect(env).toEqual({
    ok: true,
    data: [
      { name: "downloads", path: join(corpus.income, "downloads"), exists: true },
      { name: "slsk", path: join(corpus.income, "slsk"), exists: true },
      { name: "todo", path: join(corpus.income, "todo"), exists: true },
    ],
    errors: [],
  });
  expect(treeHash(corpus.dir)).toBe(before); // read-only
});

test("income: exists is false for a missing path or a file; malformed entries are not folders", () => {
  const rules = mkdtempSync(join(tmpdir(), "intake-income-"));
  try {
    cpSync(corpus.rules, rules, { recursive: true });
    const aFile = join(rules, "income.yaml");
    writeFileSync(
      join(rules, "income.yaml"),
      [
        "income:",
        "  - name: zeta",
        `    path: ${join(corpus.income, "todo")}`,
        "  - name: gone",
        "    path: ./no/such/dir",
        "  - name: notadir",
        `    path: ${aFile}`,
        "  - path: /nameless", // no name: not an income folder
        "  - name: alpha",
        "    path: ../",
        "",
      ].join("\n"),
    );
    const { code, env } = json(["income"], rules);
    expect(code).toBe(0);
    expect(env.data).toEqual([
      { name: "zeta", path: join(corpus.income, "todo"), exists: true },
      { name: "gone", path: join(rules, "no", "such", "dir"), exists: false },
      { name: "notadir", path: aFile, exists: false },
      { name: "alpha", path: join(rules, ".."), exists: true },
    ]);

    const human = run(["income"], rules);
    expect(human.code).toBe(0);
    expect(human.stdout).toContain(`gone  ${join(rules, "no", "such", "dir")}  (missing)`);
    expect(human.stdout).toContain(`zeta  ${join(corpus.income, "todo")}\n`);
  } finally {
    rmSync(rules, { recursive: true, force: true });
  }
});

test("income with no income folder configured: E_NO_RULES, as status", () => {
  const rules = mkdtempSync(join(tmpdir(), "intake-noincome-"));
  try {
    for (const dir of [rules, "/nonexistent/rules"]) {
      for (const cmd of ["income", "status"]) {
        const { code, env } = json([cmd], dir);
        expect({ cmd, code }).toEqual({ cmd, code: 2 });
        expect(env.data).toBeNull();
        expect(env.errors.map((e: { code: string }) => e.code)).toEqual(["E_NO_RULES"]);
      }
    }
  } finally {
    rmSync(rules, { recursive: true, force: true });
  }
});

// ---- version commands ------------------------------------------------------------

test("version --json lists every accepted command, and only those", () => {
  const { code, env } = json(["version"]);
  expect(code).toBe(0);
  expect(env.data.commands).toEqual(SURFACE);
  // Each listed name is dispatched (no command mutates without arguments);
  // anything else is an unknown command.
  for (const cmd of env.data.commands as string[]) {
    const r = json([cmd]);
    const unknown = (r.env.errors as { msg: string }[]).some((e) => e.msg.startsWith("unknown command"));
    expect({ cmd, unknown }).toEqual({ cmd, unknown: false });
  }
  for (const cmd of ["frobnicate", "toString", "constructor", "__proto__"]) {
    const r = json([cmd]);
    expect({ cmd, code: r.code, msg: r.env.errors[0]?.msg }).toEqual({ cmd, code: 2, msg: `unknown command: ${cmd}` });
  }
});

// ---- status summary: assigned_by, target_path --------------------------------------

test("status summary: proposal carries assigned_by and target_path; null without a proposal", async () => {
  const pollen = join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  const movements = join(corpus.income, "slsk", "Solar Fields", "Solar Fields - Movements (2009)");
  const oldskool = join(corpus.income, "todo", "Oldskool - Demo Tape (1998)"); // tier reject: no target
  expect((await cmdAssign([pollen], OPTS, OFFLINE)).errors).toEqual([]);
  expect((await cmdAssign([movements, oldskool], { ...OPTS, collection: "[Ambient]" }, OFFLINE)).errors).toEqual([]);
  const stored = (dir: string) => readSidecar(join(dir, ".intake.json"))!.proposal!.target_path;
  expect(stored(pollen)).toMatch(/^\/library\/music\.hq\//);
  expect(stored(oldskool)).toBeNull();

  const { code, env } = json(["status"]);
  expect(code).toBe(0);
  type Row = { root_path: string; proposal: Record<string, unknown> | null };
  const byRoot = new Map((env.data as Row[]).map((r) => [r.root_path, r]));
  expect(byRoot.get(pollen)!.proposal).toMatchObject({ assigned_by: "engine", target_path: stored(pollen) });
  expect(byRoot.get(movements)!.proposal).toMatchObject({
    target_collection: "[Ambient]", confidence: 1, assigned_by: "user", target_path: stored(movements),
  });
  expect(byRoot.get(oldskool)!.proposal).toMatchObject({ assigned_by: "user", target_path: null });
  const reflective = join(corpus.income, "slsk", "Solar Fields", "Solar Fields [2001] Reflective Frequencies");
  expect(byRoot.get(reflective)!.proposal).toBeNull();
  for (const r of env.data as Row[]) {
    if (r.proposal) expect("target_path" in r.proposal && "assigned_by" in r.proposal).toBe(true);
  }
});
