// Library layout end to end (doc 02 "Library layout and credit rules
// (amendment 003)"): propose and the user override read the target
// collection dir in a temp library and choose the artist folder, [Releases]
// or [Compilations]; a VA root is proposed and executed into [Compilations].
// The tier roots point at the temp library; nothing outside the temp corpus
// is read or written. Synthetic names only.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { cmdAssign, type P2Deps } from "../src/commands-p2.ts";
import { cmdApprove, cmdExecute, cmdPropose } from "../src/commands-p3.ts";
import type { Providers } from "../src/providers.ts";
import { loadGenreMap, saveGenreMap } from "../src/rules.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, collection: null, by: null,
  allResolved: false, batch: null, approved: false, resume: false,
};
const OFFLINE: P2Deps = {
  providers: { discogs: null, similar: null, shim: { identify: async () => ({ candidates: [] }) } } as Providers,
};
const DTE = "[Downtempo & Electronica]";
const PSY = "[Psytrance]";
const AMB = "[Ambient]";

let corpus: Corpus;
let library: string;
const hq = (...seg: string[]) => join(library, "music.hq", ...seg);
const NAME_ROOT = () => join(corpus.income, "todo", "Artist_Name-Album-(CAT123)-WEB-2011-ExampleGroup");
const VA_ROOT = () => join(corpus.income, "todo", "VA_-_Example_Compilation_(Web_Version_2CD)");
const NEWCOMER_ROOT = () => join(corpus.dir, "extra", "Example Newcomer [2021] Second Light");
const doc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;

async function tone(path: string, n: number): Promise<void> {
  mkdirSync(dirname(path), { recursive: true });
  const proc = Bun.spawn([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", `sine=frequency=${3000 + 41 * n}:duration=0.2:sample_rate=44100`,
    "-metadata", "album_artist=Example Newcomer", "-metadata", "artist=Example Newcomer",
    "-metadata", "album=Second Light", "-metadata", `title=Song ${n}`, "-metadata", `track=${n}`,
    "-metadata", "date=2021",
    "-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3", path,
  ], { stdout: "ignore", stderr: "pipe" });
  if ((await proc.exited) !== 0) throw new Error(`ffmpeg failed: ${await new Response(proc.stderr).text()}`);
}

beforeAll(async () => {
  corpus = setupCorpus();
  library = join(corpus.dir, "library");
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${join(corpus.dir, "journal", "intake-journal.ndjson")}`,
      "",
    ].join("\n"),
  );
  // A second synthetic artist, known to the genre map but new to the library.
  for (const n of [1, 2, 3]) await tone(join(NEWCOMER_ROOT(), `0${n} Example Newcomer - Song ${n}.mp3`), n);
  const genre = loadGenreMap(corpus.rules);
  genre.artists["Example Newcomer"] = { [DTE]: 2 };
  saveGenreMap(corpus.rules, genre);
  for (const dir of [join(corpus.income, "todo"), NEWCOMER_ROOT()]) {
    expect((await cmdResolve([dir], OPTS)).errors).toEqual([]);
  }
  for (const dir of [NAME_ROOT(), VA_ROOT(), NEWCOMER_ROOT()]) expect(doc(dir).status).toBe("resolved");
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("propose: the artist's release in [releases] makes an artist folder and is reported, not moved", async () => {
  const old = hq(DTE, "[releases]", "Artist Name [2009] Older Album");
  mkdirSync(old, { recursive: true });
  const result = await cmdPropose([NAME_ROOT()], { ...OPTS, dryRun: true }, OFFLINE);
  expect(result.errors).toEqual([]);
  expect(result.data).toEqual([{
    id: doc(NAME_ROOT()).id,
    root_path: NAME_ROOT(),
    status: "proposed",
    target_path: hq(DTE, "Artist Name", "Artist Name [2011] Album"),
    confidence: 0.95,
    restructure_candidates: [`${DTE}/[releases]/Artist Name [2009] Older Album`],
  }]);
  expect(existsSync(old)).toBe(true);
  expect(readdirSync(hq(DTE))).toEqual(["[releases]"]);
  expect(doc(NAME_ROOT()).proposal).toBeNull(); // dry run
});

test("propose: an existing artist dir is the target, with its on-disk spelling", async () => {
  mkdirSync(hq(DTE, "ARTIST NAME", "Artist Name [2008] Oldest Album"), { recursive: true });
  const result = await cmdPropose([NAME_ROOT()], OPTS, OFFLINE);
  expect(result.errors).toEqual([]);
  const target = hq(DTE, "ARTIST NAME", "Artist Name [2011] Album");
  expect(result.data).toEqual([{
    id: doc(NAME_ROOT()).id, root_path: NAME_ROOT(), status: "proposed", target_path: target, confidence: 0.95,
  }]);
  const proposal = doc(NAME_ROOT()).proposal!;
  expect(proposal).toMatchObject({ target_collection: DTE, target_path: target, structure_slot: "artist" });
  expect("restructure_candidates" in proposal).toBe(false);
});

test("propose: an artist new to the collection goes to its existing [releases] dir", async () => {
  const result = await cmdPropose([NEWCOMER_ROOT()], OPTS, OFFLINE);
  expect(result.errors).toEqual([]);
  const target = hq(DTE, "[releases]", "Example Newcomer [2021] Second Light");
  expect(result.data).toMatchObject([{ status: "proposed", target_path: target }]);
  expect(doc(NEWCOMER_ROOT()).proposal).toMatchObject({ target_path: target, structure_slot: "releases" });
});

test("assign --collection: the user override reads the chosen collection the same way", async () => {
  // In [Ambient] the artist only sits in a curated selection, which does not
  // count, next to another artist's loose release.
  mkdirSync(hq(AMB, "[Best Of]", "Artist Name [2005] Curated Pick"), { recursive: true });
  mkdirSync(hq(AMB, "Another Example - Loose Album (2010)"), { recursive: true });
  const result = await cmdAssign([NAME_ROOT()], { ...OPTS, dryRun: true, collection: AMB, by: "user" }, OFFLINE);
  expect(result.errors).toEqual([]);
  expect(result.data).toMatchObject([{
    target_collection: AMB, assigned_by: "user", target_path: hq(AMB, "[Releases]", "Artist Name [2011] Album"),
  }]);
});

test("a VA root: override, propose under [Compilations], approve, execute into [Compilations]", async () => {
  const folder = "Various Artists Example Compilation - An Example Site compilation (2CD Web Edition)";
  const target = hq(PSY, "[Compilations]", folder);
  const assigned = await cmdAssign([VA_ROOT()], { ...OPTS, collection: PSY, by: "user" }, OFFLINE);
  expect(assigned.errors).toEqual([]);
  expect(doc(VA_ROOT()).proposal).toMatchObject({ structure_slot: "compilations", target_path: target });

  // Formerly refused with "compilations slot pending".
  const proposed = await cmdPropose([VA_ROOT()], OPTS, OFFLINE);
  expect(proposed.errors).toEqual([]);
  expect(proposed.data).toMatchObject([{ status: "proposed", target_path: target }]);

  expect(cmdApprove([VA_ROOT()], OPTS).errors).toEqual([]);
  const executed = await cmdExecute([VA_ROOT()], OPTS);
  expect(executed.errors).toEqual([]);
  const placed = doc(VA_ROOT());
  expect(placed.status).toBe("placed");
  expect(placed.placed!.target_path).toBe(target);
  expect(readdirSync(hq(PSY))).toEqual(["[Compilations]"]);
  for (const f of placed.files) expect(existsSync(join(target, f.path))).toBe(true);
  expect(readdirSync(join(target, "cd1")).filter((n) => n.endsWith(".mp3")).length).toBeGreaterThan(0);
});
