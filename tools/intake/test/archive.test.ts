// Archive edges that the rest of the suite does not reach: the E_ARCHIVE_TOOL
// surface (no unpack tool available). The PATH-stripped case runs through a
// real subprocess because Bun.which() reads the process environment at startup
// and ignores later mutation of process.env.PATH.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { unpackArchive } from "../src/archive.ts";
import { sha1Hex } from "../src/util.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const ZIP = "Carbon Based Lifeforms - Derelicts (2017).zip";

let corpus: Corpus;
let arcIncome: string; // income folder holding nothing but the archive
let zipPath: string;
let unpackedDir: string;

beforeAll(() => {
  corpus = setupCorpus();
  arcIncome = join(corpus.dir, "archive-only");
  mkdirSync(arcIncome, { recursive: true });
  zipPath = join(arcIncome, ZIP);
  unpackedDir = join(arcIncome, ZIP.replace(/\.zip$/, ".unpacked"));
  copyFileSync(join(corpus.income, "downloads", ZIP), zipPath);
  // Retarget the temp rules copy at that single income folder, so a scan does
  // archive work and nothing else.
  writeFileSync(
    join(corpus.rules, "income.yaml"),
    ["income:", "  - name: archive-only", `    path: ${arcIncome}`, "    source_type: web", ""].join("\n"),
  );
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

function scan(env: Record<string, string>): { code: number; envelope: Record<string, any> } {
  // process.execPath, not "bun": the stripped-PATH run cannot resolve names.
  const proc = Bun.spawnSync([process.execPath, "run", CLI, "scan", "--all", "--json"], { env });
  const out = proc.stdout.toString();
  if (!out.trim()) throw new Error(`no stdout; stderr: ${proc.stderr.toString()}`);
  return { code: proc.exitCode, envelope: JSON.parse(out) };
}

test("unsupported archive extension reports tool_missing without creating a target", async () => {
  const fake = join(corpus.dir, "not-a-release.tar.gz");
  writeFileSync(fake, new Uint8Array([0x1f, 0x8b, 0x08, 0x00]));
  const r = await unpackArchive(fake, false);
  expect(r.action).toBe("tool_missing");
  expect(r.error).toBe("no tool for .gz");
  expect(existsSync(join(corpus.dir, "not-a-release.tar.unpacked"))).toBe(false);
});

test("scan with no unpack tool on PATH: E_ARCHIVE_TOOL, exit 1, archive untouched", () => {
  rmSync(unpackedDir, { recursive: true, force: true }); // order-independent
  const before = sha1Hex(new Uint8Array(readFileSync(zipPath)));

  const { code, envelope } = scan({
    PATH: "/nonexistent",
    INTAKE_RULES_DIR: corpus.rules,
    HOME: process.env.HOME ?? "/tmp",
  });

  expect(envelope.ok).toBe(false);
  expect(envelope.errors.map((e: { code: string }) => e.code)).toEqual(["E_ARCHIVE_TOOL"]);
  expect(envelope.errors[0].path).toBe(zipPath);
  // Partial, not fatal: the income folder was still walked and reported.
  expect(code).toBe(1);
  expect(envelope.data[0].archives[0].action).toBe("tool_missing");
  // Nothing extracted, nothing mutated.
  expect(existsSync(unpackedDir)).toBe(false);
  expect(sha1Hex(new Uint8Array(readFileSync(zipPath)))).toBe(before);
});

test("control: the same scan with tools on PATH unpacks and exits 0", () => {
  rmSync(unpackedDir, { recursive: true, force: true });
  const { code, envelope } = scan({ ...process.env, INTAKE_RULES_DIR: corpus.rules } as Record<string, string>);
  expect(envelope.errors).toEqual([]);
  expect(code).toBe(0);
  expect(envelope.data[0].archives[0].action).toBe("unpacked");
  expect(existsSync(unpackedDir)).toBe(true);
});
