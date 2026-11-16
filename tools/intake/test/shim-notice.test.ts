// A failed beets shim leaves a trace: the issue is recorded on the sidecar's
// identification, and identify/propose give one human-mode notice per run.
// Notices never enter the --json envelope. Injected providers and the fake
// shim only; no beets, no network.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { cmdScan } from "../src/commands.ts";
import { cmdIdentify, shimNotice } from "../src/commands-p2.ts";
import { cmdPropose } from "../src/commands-p3.ts";
import type { Providers, ShimResult } from "../src/providers.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, useTempLibrary, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const FAKE_SHIM = join(import.meta.dir, "fakes", "fake-shim.ts");
const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, all: false,
  collection: null, by: null, allResolved: false,
};

let corpus: Corpus;
const dirOf = (...seg: string[]) => join(corpus.income, ...seg);
const doc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;
const POLLEN = () => dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
const MOVEMENTS = () => dirOf("slsk", "Solar Fields", "Solar Fields - Movements (2009)");
const REFLECTIVE = () => dirOf("slsk", "Solar Fields", "Solar Fields [2001] Reflective Frequencies");
const LEAVING = () => dirOf("slsk", "Solar Fields", "Solar Fields [2005] Leaving Home");
const OTT = () => dirOf("todo", "Ott - Blumenkraft (2003)");
const BLUETECH = () => dirOf("todo", "Bluetech [2011] Cosmic Dubwise");
const KOAN = () => dirOf("todo", "Koan-Condemned-(MKL033)-WEB-2016-KOAN");
const ASURA = () => dirOf("todo", "Asura [2003] Lost Eden (Ultimae Records; inre010)");
const SYNC24 = () => dirOf("downloads", "Sync24 [2024] Omnimotion Remixed");
const ARTIST = () => dirOf("todo", "Artist_Name-Album-(CAT123)-WEB-2011-ExampleGroup");

/** Providers whose shim answers per root dir; everything else offline. */
function withShim(answer: (dir: string) => ShimResult): { providers: Providers } {
  return { providers: { discogs: null, similar: null, shim: { identify: async (dir) => answer(dir) } } };
}
const FAILING = withShim(() => ({ error: "beets_unavailable" }));

beforeAll(async () => {
  corpus = setupCorpus();
  useTempLibrary(corpus); // propose refuses a tier root that does not exist
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  await cmdScan([], { ...OPTS, all: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("identify: a failed shim is recorded on each identification, one notice for the run", async () => {
  const r = await cmdIdentify([POLLEN(), MOVEMENTS()], OPTS, FAILING);
  expect(r.errors).toEqual([]);
  for (const dir of [POLLEN(), MOVEMENTS()]) {
    const ident = doc(dir).identification!;
    expect(ident.issues).toEqual(["beets_unavailable"]);
    // Additive: every existing field is still there.
    expect(ident).toMatchObject({ status: "unconfirmed", source: null, release_id: null, candidates: null });
    expect(Object.keys(ident)).toEqual(expect.arrayContaining([
      "status", "source", "release_id", "artist", "album", "year", "label", "catno",
      "styles", "genres", "distance", "grammar", "candidates", "identified_at",
    ]));
  }
  expect(r.notices).toEqual(["beets shim failed for 2 root(s): beets_unavailable; see INTAKE_BEETS_SHIM"]);
});

test("identify: no issues key and no notice when nothing failed", async () => {
  const r = await cmdIdentify([REFLECTIVE()], OPTS, withShim(() => ({ candidates: [] })));
  expect(r.errors).toEqual([]);
  expect(doc(REFLECTIVE()).identification!.status).toBe("unconfirmed");
  expect("issues" in doc(REFLECTIVE()).identification!).toBe(false);
  expect(r.notices).toBeUndefined();
});

test("identify: notice counts the failed roots only, shows the first error's first line", async () => {
  const crash = "beets_error: HTTPSConnectionPool(host='musicbrainz.org')\nTraceback (most recent call last):";
  const r = await cmdIdentify(
    [LEAVING(), OTT(), BLUETECH()],
    OPTS,
    withShim((dir) => (dir === LEAVING() ? { candidates: [] } : dir === OTT() ? { error: crash } : { error: "shim_exit_1" })),
  );
  expect(r.errors).toEqual([]);
  expect("issues" in doc(LEAVING()).identification!).toBe(false);
  expect(doc(OTT()).identification!.issues).toEqual([crash]);
  expect(doc(BLUETECH()).identification!.issues).toEqual(["shim_exit_1"]);
  // A beets error is not fixed by another shim command: no INTAKE_BEETS_SHIM hint.
  expect(r.notices).toEqual([
    "beets shim failed for 2 root(s): beets_error: HTTPSConnectionPool(host='musicbrainz.org')",
  ]);
});

// ---- the INTAKE_BEETS_SHIM hint ----------------------------------------------

const HINT = "; see INTAKE_BEETS_SHIM";

test("notice: no INTAKE_BEETS_SHIM hint when the shim ran and failed on the release or in beets", () => {
  for (const error of [
    "no_audio_files",
    "beets_error: x",
    "file_not_found: cd1/01 - Intro.mp3",
    "file_outside_release_dir: ../01 - Intro.mp3",
  ]) {
    expect(shimNotice([error])).toBe(`beets shim failed for 1 root(s): ${error}`);
  }
  // The hint follows the error shown, the first.
  expect(shimNotice(["beets_error: x", "beets_unavailable"])).toBe("beets shim failed for 2 root(s): beets_error: x");
});

test("notice: the INTAKE_BEETS_SHIM hint stays for launch, interpreter and invocation failures", () => {
  for (const error of [
    "shim_unavailable",
    "beets_unavailable",
    "shim_exit_1",
    "shim_exit_127",
    "shim_bad_output",
    "usage: beets_identify.py <release_dir> <file>... --json",
  ]) {
    expect(shimNotice([error])).toBe(`beets shim failed for 1 root(s): ${error}${HINT}`);
  }
  expect(shimNotice(["beets_unavailable", "beets_error: x"])).toBe(`beets shim failed for 2 root(s): beets_unavailable${HINT}`);
});

test("identify: a Discogs outage is recorded too, but is not a shim notice", async () => {
  const r = await cmdIdentify([KOAN()], OPTS, {
    providers: {
      discogs: { searchRelease: async () => null, artistAliases: async () => null },
      similar: null,
      shim: { identify: async () => ({ candidates: [] }) },
    },
  });
  expect(r.errors).toEqual([]);
  expect(doc(KOAN()).identification!.issues).toEqual(["discogs_unreachable"]);
  expect(r.notices).toBeUndefined();
});

test("propose: the identify it runs records the shim failure, one notice for the run", async () => {
  const r = await cmdPropose([ASURA(), SYNC24()], OPTS, FAILING);
  expect(r.errors).toEqual([]);
  for (const dir of [ASURA(), SYNC24()]) expect(doc(dir).identification!.issues).toEqual(["beets_unavailable"]);
  expect(r.notices).toEqual(["beets shim failed for 2 root(s): beets_unavailable; see INTAKE_BEETS_SHIM"]);
  // Already identified: propose does not run the shim again, so no notice.
  const again = await cmdPropose([MOVEMENTS()], OPTS, FAILING);
  expect(again.notices).toBeUndefined();
});

// ---- through the real entrypoint ---------------------------------------------

function run(args: string[]): { code: number; stdout: string; stderr: string } {
  const env: Record<string, string | undefined> = {
    ...process.env,
    INTAKE_RULES_DIR: corpus.rules,
    INTAKE_BEETS_SHIM: `bun ${FAKE_SHIM}`, // default mode: {"error":"beets_unavailable"}, exit 3
  };
  delete env.FAKE_SHIM_MODE;
  delete env.DISCOGS_TOKEN;
  delete env.LASTFM_API_KEY;
  const proc = Bun.spawnSync([process.execPath, "run", CLI, ...args], { env });
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
}

const noticeLines = (stderr: string) => stderr.split("\n").filter((l) => l.startsWith("notice: "));

test("CLI identify: --json envelope has no notices; human mode prints exactly one notice line", () => {
  const json = run(["identify", ARTIST(), "--dry-run", "--json"]);
  expect(json.code).toBe(0);
  const env = JSON.parse(json.stdout);
  expect(Object.keys(env)).toEqual(["ok", "data", "errors"]);
  expect(env.data[0].issues).toEqual(["beets_unavailable"]); // the row's issues, as before
  expect(json.stderr).not.toContain("notice");

  const human = run(["identify", ARTIST()]);
  expect(human.code).toBe(0);
  expect(noticeLines(human.stderr)).toEqual([
    "notice: beets shim failed for 1 root(s): beets_unavailable; see INTAKE_BEETS_SHIM",
  ]);
  expect(human.stdout).not.toContain("notice");
  expect(doc(ARTIST()).identification!.issues).toEqual(["beets_unavailable"]);
});
