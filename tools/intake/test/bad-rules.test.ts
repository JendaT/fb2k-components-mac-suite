// A malformed rules file is E_BAD_RULES (exit 2, `path` = the file, the
// message naming the file and, where known, the key), for the command that
// loaded it. It used to surface as E_INTERNAL with `path: null` from the
// CLI's top-level catch. Covered: a YAML syntax error in income.yaml,
// structure.yaml and each map, and the existing archive_code_pages check
// (also in test/archive-codepage.test.ts). E_NO_RULES is unchanged.
//
// The envelope is checked through the real CLI subprocess; the map loaders
// are also checked in process. Each case gets its own copy of the fixture
// rules dir. Execute reads the genre map before placing anything: a malformed
// map used to fail the root after its commit point (placed, but left
// `placing` with a bookkeeping E_VERIFY).

import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { cpSync, existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdPropose } from "../src/commands-p3.ts";
import { loadIncomeConfig, RulesError } from "../src/config.ts";
import { loadGenreMap, loadLabelMap, loadStyleMap } from "../src/rules.ts";
import { readSidecar } from "../src/sidecar.ts";
import { makeTierRoots, setupCorpus, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");

interface Envelope {
  ok: boolean;
  data: unknown;
  errors: { code: string; msg: string; path: string | null }[];
}

let corpus: Corpus;
let rules: string;

beforeAll(() => {
  corpus = setupCorpus();
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

afterEach(() => {
  if (rules) rmSync(rules, { recursive: true, force: true });
});

/** A copy of the fixture rules dir with `file` replaced by `text`. */
function rulesWith(file: string, text: string): string {
  rules = mkdtempSync(join(tmpdir(), "intake-badrules-"));
  cpSync(corpus.rules, rules, { recursive: true });
  writeFileSync(join(rules, file), text);
  return rules;
}

function cli(args: string[], json = true): { code: number | null; stdout: string; stderr: string } {
  const proc = Bun.spawnSync([process.execPath, "run", CLI, ...args, ...(json ? ["--json"] : [])], {
    env: { ...process.env, INTAKE_RULES_DIR: rules }, timeout: 30_000,
  });
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
}

function expectBadRules(args: string[], file: string, msg: string): void {
  const { code, stdout } = cli(args);
  expect(code).toBe(2);
  expect(stdout.trim().split("\n").length).toBe(1);
  expect(JSON.parse(stdout) as Envelope).toEqual({
    ok: false, data: null, errors: [{ code: "E_BAD_RULES", msg, path: join(rules, file) }],
  });
}

test("archive_code_pages: [cp999] in income.yaml: E_BAD_RULES, exit 2, path = income.yaml, the key named", () => {
  const file = join(rulesWith("income.yaml", "archive_code_pages: [cp999]\nincome: []\n"), "income.yaml");
  expectBadRules(
    ["income"], "income.yaml",
    `${file}: archive_code_pages: unknown code page "cp999" (allowed: cp437, cp852, cp1252, cp1250)`,
  );
  expect(() => loadIncomeConfig(rules)).toThrow(RulesError);
});

test("a YAML syntax error in structure.yaml: E_BAD_RULES naming that file", () => {
  const file = join(rulesWith("structure.yaml", "tiers:\n  music.hq: { root: /library/music.hq\n"), "structure.yaml");
  expectBadRules(["gc", "--all"], "structure.yaml", `${file}: YAML Parse error: Unexpected token`);
});

test("a YAML syntax error in income.yaml: E_BAD_RULES, also in human mode (stderr only)", () => {
  const file = join(rulesWith("income.yaml", "income: [unclosed\n"), "income.yaml");
  expectBadRules(["status"], "income.yaml", `${file}: YAML Parse error: Unexpected token`);
  const human = cli(["status"], false);
  expect(human.code).toBe(2);
  expect(human.stdout).toBe("");
  expect(human.stderr).toBe(`error E_BAD_RULES: ${file}: YAML Parse error: Unexpected token (${file})\n`);
});

test("a YAML syntax error in genre-map.yaml: E_BAD_RULES naming that file", () => {
  const file = join(rulesWith("genre-map.yaml", "artists: [\n"), "genre-map.yaml");
  expectBadRules(["collections"], "genre-map.yaml", `${file}: YAML Parse error: Unexpected token`);
});

test("the map loaders throw a RulesError naming the file, for every map", () => {
  for (const [file, load] of [
    ["genre-map.yaml", loadGenreMap],
    ["label-map.yaml", loadLabelMap],
    ["styles.yaml", loadStyleMap],
  ] as const) {
    rulesWith(file, "a: {\n");
    let thrown: unknown = null;
    try {
      load(rules);
    } catch (e) {
      thrown = e;
    }
    expect(thrown).toBeInstanceOf(RulesError);
    expect((thrown as RulesError).file).toBe(join(rules, file));
    expect((thrown as RulesError).message.startsWith(`${join(rules, file)}: `)).toBe(true);
    rmSync(rules, { recursive: true, force: true });
  }
});

test("execute with a malformed genre-map.yaml places nothing: the map is read before the first root", async () => {
  const own = setupCorpus();
  const opts = {
    json: true, dryRun: false, force: false, filters: {},
    allResolved: false, batch: null, approved: false, resume: false,
  };
  process.env.INTAKE_BEETS_SHIM = `bun ${join(import.meta.dir, "fakes", "fake-shim.ts")}`;
  try {
    const library = join(own.dir, "library");
    const journal = join(own.dir, "journal", "intake-journal.ndjson");
    writeFileSync(join(own.rules, "structure.yaml"), [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${journal}`,
      "",
    ].join("\n"));
    makeTierRoots(own.rules);
    const root = join(own.income, "todo", "Asura [2003] Lost Eden (Ultimae Records; inre010)");
    expect((await cmdResolve([root], opts)).errors).toEqual([]);
    expect((await cmdPropose([root], opts)).errors).toEqual([]);
    expect(cmdApprove([root], opts).errors).toEqual([]);
    const target = readSidecar(join(root, ".intake.json"))!.proposal!.target_path!;
    writeFileSync(join(own.rules, "genre-map.yaml"), "artists: [\n");

    await expect(cmdExecute([root], opts)).rejects.toThrow(RulesError);
    expect(existsSync(target)).toBe(false);
    expect(existsSync(journal)).toBe(false);
    expect(readSidecar(join(root, ".intake.json"))!.status).toBe("approved");
  } finally {
    delete process.env.INTAKE_BEETS_SHIM;
    process.env.INTAKE_RULES_DIR = corpus.rules;
    rmSync(own.dir, { recursive: true, force: true });
  }
});
