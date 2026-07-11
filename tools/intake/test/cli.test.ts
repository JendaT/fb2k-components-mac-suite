// CLI surface tests through the real entrypoint: JSON envelope, exit codes,
// status summary shape per doc 03.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { setupCorpus, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");

let corpus: Corpus;

function run(args: string[]): { code: number; stdout: string; stderr: string } {
  const proc = Bun.spawnSync(["bun", "run", CLI, ...args], {
    env: { ...process.env, INTAKE_RULES_DIR: corpus.rules },
  });
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
}

beforeAll(() => {
  corpus = setupCorpus();
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("version --json returns {cli, schema, engine} in an envelope", () => {
  const r = run(["version", "--json"]);
  expect(r.code).toBe(0);
  const env = JSON.parse(r.stdout);
  expect(env).toEqual({ ok: true, data: { cli: "0.1.0", schema: 1, engine: "0.1.0" }, errors: [] });
});

test("unknown command exits 2 with E_BAD_ARGS envelope", () => {
  const r = run(["frobnicate", "--json"]);
  expect(r.code).toBe(2);
  const env = JSON.parse(r.stdout);
  expect(env.ok).toBe(false);
  expect(env.errors[0].code).toBe("E_BAD_ARGS");
});

test("resolve on a missing path exits 2 with E_NOT_FOUND", () => {
  const r = run(["resolve", "/nonexistent/nowhere", "--json"]);
  expect(r.code).toBe(2);
  expect(JSON.parse(r.stdout).errors[0].code).toBe("E_NOT_FOUND");
});

test("scan of unknown income exits 2; missing rules dir raises E_NO_RULES", () => {
  expect(JSON.parse(run(["scan", "nope", "--json"]).stdout).errors[0].code).toBe("E_NOT_FOUND");
  const proc = Bun.spawnSync(["bun", "run", CLI, "status", "--json"], {
    env: { ...process.env, INTAKE_RULES_DIR: "/nonexistent/rules" },
  });
  expect(proc.exitCode).toBe(2);
  expect(JSON.parse(proc.stdout.toString()).errors[0].code).toBe("E_NO_RULES");
});

test("scan + status --json round trip with doc 03 summary shape", () => {
  const scan = run(["scan", "--all", "--json"]);
  expect(scan.code).toBe(0);
  const scanEnv = JSON.parse(scan.stdout);
  expect(scanEnv.ok).toBe(true);

  const status = run(["status", "--json"]);
  expect(status.code).toBe(0);
  const env = JSON.parse(status.stdout);
  expect(env.ok).toBe(true);
  expect(Array.isArray(env.data)).toBe(true);
  expect(env.data.length).toBe(19);
  for (const s of env.data) {
    expect(Object.keys(s).sort()).toEqual(["cluster", "id", "needs_review", "placed", "proposal", "root_path", "status"]);
    expect(s.id).toMatch(/^itk_[0-9a-f]{8}$/);
    expect(s.proposal).toBeNull(); // P1: no propose stage yet
    expect(s.placed).toBeNull();
  }

  const filtered = JSON.parse(run(["status", "--json", "--filter", "status=new"]).stdout);
  expect(filtered.data.length).toBe(1); // the iso stub
  const tierFiltered = JSON.parse(run(["status", "--json", "--filter", "tier=reject", "--filter", "virtual=false"]).stdout);
  expect(tierFiltered.data.length).toBe(1); // Oldskool 128kbps
});
