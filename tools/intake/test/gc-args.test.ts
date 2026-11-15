// Doc 03 v1.2 `gc` semantics (CR-004.14): gc takes roots or --all. With
// neither it returns E_BAD_ARGS and touches nothing; an empty ref list never
// means every root. `--all` collects every placed root in every income folder.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdScan } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdGc, cmdPropose } from "../src/commands-p3.ts";
import type { Providers } from "../src/providers.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { collectSidecars, setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, all: false,
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};
const OFFLINE: { providers: Providers } = { providers: { discogs: null, similar: null, shim: null } };

let corpus: Corpus;
let journalPath: string;

const POLLEN = () => join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
const MOVEMENTS = () => join(corpus.income, "slsk", "Solar Fields", "Solar Fields - Movements (2009)");
const doc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;

/** Every byte gc could touch: income files, sidecars, journal. */
function world(): string {
  return JSON.stringify({
    income: treeHash(corpus.income),
    sidecars: collectSidecars(corpus.income),
    journal: existsSync(journalPath) ? readFileSync(journalPath, "utf8") : null,
  });
}

function run(args: string[]): { code: number; env: { ok: boolean; data: unknown; errors: { code: string; path: string | null }[] } } {
  const proc = Bun.spawnSync([process.execPath, "run", CLI, ...args, "--json"], {
    env: { ...process.env, INTAKE_RULES_DIR: corpus.rules },
  });
  return { code: proc.exitCode, env: JSON.parse(proc.stdout.toString()) };
}

beforeAll(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  const library = join(corpus.dir, "library");
  journalPath = join(corpus.dir, "journal", "intake-journal.ndjson");
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${journalPath}`,
      "",
    ].join("\n"),
  );
  await cmdScan([], { ...OPTS, all: true });
  // Two placed roots in two different income folders.
  for (const dir of [POLLEN(), MOVEMENTS()]) {
    expect((await cmdPropose([dir], OPTS, OFFLINE)).errors).toEqual([]);
    expect(cmdApprove([dir], OPTS).errors).toEqual([]);
    expect((await cmdExecute([dir], OPTS)).errors).toEqual([]);
    expect(doc(dir).status).toBe("placed");
  }
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("gc with neither roots nor --all: E_BAD_ARGS, exit 2, nothing touched", async () => {
  const before = world();
  for (const dryRun of [false, true]) {
    const result = await cmdGc([], { ...OPTS, dryRun });
    expect(result.exitCode).toBe(2);
    expect(result.data).toBeNull();
    expect(result.errors.map((e) => e.code)).toEqual(["E_BAD_ARGS"]);
    expect(result.errors[0]!.msg).toContain("--all");
  }
  const cli = run(["gc"]);
  expect(cli.code).toBe(2);
  expect(cli.env.ok).toBe(false);
  expect(cli.env.data).toBeNull();
  expect(cli.env.errors.map((e) => e.code)).toEqual(["E_BAD_ARGS"]);
  expect(world()).toBe(before);
});

test("named roots are the whole work set, with or without --all", async () => {
  const result = await cmdGc([POLLEN()], { ...OPTS, all: true, dryRun: true });
  expect(result.errors).toEqual([]);
  expect(result.data!.map((r) => r.root_path)).toEqual([POLLEN()]);
});

test("gc --all collects every placed root in every income folder", async () => {
  const dry = run(["gc", "--all", "--dry-run"]);
  expect(dry.code).toBe(0);
  expect((dry.env.data as { root_path: string }[]).map((r) => r.root_path).sort()).toEqual([MOVEMENTS(), POLLEN()].sort());

  const result = await cmdGc([], { ...OPTS, all: true });
  expect(result.errors).toEqual([]);
  expect(result.exitCode).toBe(0);
  expect(result.data!.map((r) => r.root_path).sort()).toEqual([MOVEMENTS(), POLLEN()].sort());
  for (const dir of [POLLEN(), MOVEMENTS()]) {
    expect(doc(dir).status).toBe("gc_done");
    expect(existsSync(join(dir, doc(dir).files[0]!.path))).toBe(false);
  }
});
