import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isSafeRelPath, walkDirs } from "../src/util.ts";
import { readSidecar, serializeSidecar } from "../src/sidecar.ts";
import { cmdScan } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdPropose } from "../src/commands-p3.ts";
import { setupCorpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, all: false,
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false, collection: null, by: null,
};

test("isSafeRelPath: accepts real release-relative paths, rejects escapes", () => {
  // Legitimate: plain names, spaces, and multi-disc subfolders.
  expect(isSafeRelPath("01 - Iliona.flac")).toBe(true);
  expect(isSafeRelPath("CD1/03 - Atmosphere.flac")).toBe(true);
  // Escapes and absolutes.
  expect(isSafeRelPath("../../../etc/passwd")).toBe(false);
  expect(isSafeRelPath("a/../../b")).toBe(false);
  expect(isSafeRelPath("/etc/passwd")).toBe(false);
  expect(isSafeRelPath("")).toBe(false);
  expect(isSafeRelPath("./x")).toBe(false);
  expect(isSafeRelPath("a\\b")).toBe(false);
});

test("readSidecar: rejects a sidecar whose file path escapes the release root", () => {
  const dir = mkdtempSync(join(tmpdir(), "intake-sec-"));
  const good = {
    schema: 1, id: "itk_00000000", files: [{ path: "01 - x.flac", audio_hash: "fsha1:00" }],
  };
  const evil = {
    schema: 1, id: "itk_11111111",
    files: [{ path: "../../../../../../tmp/pwned", audio_hash: "fsha1:00" }],
  };
  writeFileSync(join(dir, "good.json"), JSON.stringify(good));
  writeFileSync(join(dir, "evil.json"), JSON.stringify(evil));
  expect(readSidecar(join(dir, "good.json"))).not.toBeNull();
  expect(readSidecar(join(dir, "evil.json"))).toBeNull();
});

test("walkDirs: does not follow symlinks (traversal / cycle guard)", () => {
  const root = mkdtempSync(join(tmpdir(), "intake-sec-"));
  const real = join(root, "real");
  mkdirSync(real);
  writeFileSync(join(real, "track.flac"), new Uint8Array(4));
  // A symlinked subdir pointing back at the parent would cause infinite
  // recursion if followed; a symlinked file could point outside the tree.
  symlinkSync(root, join(root, "loop"));
  symlinkSync(join(real, "track.flac"), join(real, "link.flac"));

  const entries = walkDirs(root);
  // The symlinked "loop" dir must not appear as a walked directory.
  expect(entries.some((e) => e.name === "loop")).toBe(false);
  // The symlinked audio file must not be counted among real audio files.
  const realEntry = entries.find((e) => e.path === real)!;
  expect(realEntry.audioFiles).toEqual(["track.flac"]);
});

test("execute: refuses a target_path outside the configured tier roots", async () => {
  const corpus = setupCorpus();
  const library = join(corpus.dir, "library");
  const journalPath = join(corpus.dir, "journal", "intake-journal.ndjson");
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  delete process.env.INTAKE_BEETS_SHIM;
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${journalPath}`,
      "",
    ].join("\n"),
  );
  const pollen = join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  await cmdScan([], { ...OPTS, all: true });
  await cmdPropose([pollen], OPTS);
  await cmdApprove([pollen], OPTS);

  // Tamper: point the approved target outside every tier root (as a crafted or
  // corrupted sidecar could), then execute must refuse and place nothing.
  const scPath = join(pollen, ".intake.json");
  const doc = readSidecar(scPath)!;
  const escaped = join(corpus.dir, "escaped", "pwned");
  doc.proposal!.target_path = escaped;
  writeFileSync(scPath, serializeSidecar(doc));

  const result = await cmdExecute([pollen], OPTS);
  expect(result.errors.some((e) => e.code === "E_NO_TARGET")).toBe(true);
  expect(existsSync(escaped)).toBe(false);
  expect(readSidecar(scPath)!.status).toBe("approved"); // unchanged

  rmSync(corpus.dir, { recursive: true, force: true });
});
