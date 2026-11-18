// `propose --all-resolved` skips every resolved root that needs review (doc 01
// "Thresholds": only clean roots are auto-eligible). Human mode says how many
// it skipped, counting roots flagged before the run (never picked up) and
// roots flagged by the run's own identify/assign (`skipped` rows). The --json
// envelope is unchanged apart from the additive `structure_slot` on propose
// and assign rows. Injected providers and the fake shim only.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { cmdScan, cmdStatus } from "../src/commands.ts";
import { cmdAssign } from "../src/commands-p2.ts";
import { cmdPropose, type ProposeRow } from "../src/commands-p3.ts";
import type { Providers } from "../src/providers.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, useTempLibrary, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const FAKE_SHIM = join(import.meta.dir, "fakes", "fake-shim.ts");
const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, all: false,
  collection: null, by: null, allResolved: false,
};
const PCP = "[Psychill & Chillout & Psydub]";

let corpus: Corpus;
let library: string;
const dirOf = (...seg: string[]) => join(corpus.income, ...seg);
const doc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;
const POLLEN = () => dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
const MOVEMENTS = () => dirOf("slsk", "Solar Fields", "Solar Fields - Movements (2009)");
const HILYARD = () => dirOf("todo", "Hilyard [2019] Division Cycle");

/** The beets shim confirms Pollen only; every other root stays unconfirmed (needs_review). */
const POLLEN_ONLY: { providers: Providers } = {
  providers: {
    discogs: null,
    similar: null,
    shim: {
      identify: async (dir) => ({
        candidates: dir === POLLEN()
          ? [{
            source: "mb", release_id: "mb-pollen", artist: "Aes Dana", album: "Pollen", year: "2012",
            label: "Ultimae Records", catno: "inre042", distance: 0.05, track_mapping: null,
          }]
          : [],
      }),
    },
  },
};
const OFFLINE: { providers: Providers } = { providers: { discogs: null, similar: null, shim: null } };

/** Resolved roots already flagged for review, read through `status` (independent of propose). */
const flaggedResolved = () =>
  cmdStatus([], { ...OPTS, filters: { status: "resolved", needs_review: "true" } }).data!.length;

const skipLine = (n: number) => `skipped ${n} resolved root(s) that need review; propose them by id`;

beforeAll(async () => {
  corpus = setupCorpus();
  library = useTempLibrary(corpus); // propose refuses a tier root that does not exist
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  await cmdScan([], { ...OPTS, all: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

function run(args: string[]): { code: number; stdout: string; stderr: string } {
  const env: Record<string, string | undefined> = {
    ...process.env,
    INTAKE_RULES_DIR: corpus.rules,
    INTAKE_BEETS_SHIM: `bun ${FAKE_SHIM}`,
    FAKE_SHIM_MODE: "far", // candidates too distant: identify leaves every root unconfirmed
  };
  delete env.DISCOGS_TOKEN;
  delete env.LASTFM_API_KEY;
  const proc = Bun.spawnSync([process.execPath, "run", CLI, ...args], { env });
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
}

test("CLI: human mode prints one skipped line counting both kinds; --json unchanged", () => {
  const before = flaggedResolved(); // resolver-flagged, never picked up
  expect(before).toBeGreaterThan(0);

  const json = run(["propose", "--all-resolved", "--dry-run", "--json"]);
  expect(json.code).toBe(0);
  const env = JSON.parse(json.stdout);
  expect(Object.keys(env)).toEqual(["ok", "data", "errors"]);
  expect(env.ok).toBe(true);
  expect(env.errors).toEqual([]);
  // Flagged by the run's own identify: the existing skipped rows, as they were.
  const rows = env.data as Record<string, unknown>[];
  expect(rows.length).toBeGreaterThan(0);
  for (const r of rows) expect(Object.keys(r)).toEqual(["id", "root_path", "skipped"]);
  expect(rows.every((r) => r.skipped === "needs_review")).toBe(true);
  expect(json.stderr).not.toContain("notice");

  const human = run(["propose", "--all-resolved", "--dry-run"]);
  expect(human.code).toBe(0);
  const notices = human.stderr.split("\n").filter((l) => l.startsWith("notice: "));
  expect(notices).toEqual([`notice: ${skipLine(before + rows.length)}`]);
  expect(flaggedResolved()).toBe(before); // dry runs wrote nothing
});

test("propose rows carry structure_slot; the skipped notice counts both kinds", async () => {
  const before = flaggedResolved();
  const r = await cmdPropose([], { ...OPTS, allResolved: true }, POLLEN_ONLY);
  expect(r.errors).toEqual([]);
  const rows = r.data as ProposeRow[];
  const proposed = rows.filter((row) => row.status === "proposed");
  const skipped = rows.filter((row) => row.skipped === "needs_review");
  expect(proposed.length + skipped.length).toBe(rows.length);
  expect(skipped.length).toBeGreaterThan(0);
  expect(proposed).toEqual([{
    id: doc(POLLEN()).id,
    root_path: POLLEN(),
    status: "proposed",
    target_path: `${library}/music.hq/${PCP}/[Releases]/Aes Dana [2012] Pollen (Ultimae Records; inre042)`,
    structure_slot: "releases",
    confidence: doc(POLLEN()).proposal!.confidence,
  }]);
  expect(doc(POLLEN()).proposal!.structure_slot).toBe("releases");
  for (const row of skipped) expect(Object.keys(row)).toEqual(["id", "root_path", "skipped"]);
  expect(r.notices).toEqual([skipLine(before + skipped.length)]);
});

test("nothing auto-eligible: empty data, and the notice still says what was skipped", async () => {
  // Every resolved root is flagged now (the run above raised it on the rest).
  const flagged = flaggedResolved();
  expect(flagged).toBeGreaterThan(0);
  const r = await cmdPropose([], { ...OPTS, allResolved: true }, OFFLINE);
  expect(r).toEqual({ data: [], errors: [], exitCode: 0, notices: [skipLine(flagged)] });
});

test("explicit propose of a needs_review root: proposed, no skipped notice", async () => {
  expect(doc(HILYARD()).cluster.needs_review).toBe(true);
  const r = await cmdPropose([HILYARD()], OPTS, OFFLINE);
  expect(r.errors).toEqual([]);
  expect((r.data as ProposeRow[])[0]).toMatchObject({ status: "proposed", structure_slot: expect.any(String) });
  expect(r.notices).toBeUndefined();
});

test("assign rows carry structure_slot (engine and user)", async () => {
  const engine = await cmdAssign([MOVEMENTS()], { ...OPTS, force: true }, OFFLINE);
  expect(engine.errors).toEqual([]);
  const slot = doc(MOVEMENTS()).proposal!.structure_slot;
  expect(engine.data![0]).toMatchObject({ assigned_by: "engine", structure_slot: slot });

  const user = await cmdAssign([MOVEMENTS()], { ...OPTS, collection: "[Ambient]" }, OFFLINE);
  expect(user.errors).toEqual([]);
  expect(user.data![0]).toMatchObject({ assigned_by: "user", structure_slot: doc(MOVEMENTS()).proposal!.structure_slot });
});
