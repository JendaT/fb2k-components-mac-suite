// Regression: `gc --relocate-dj` must preserve a release's internal layout.
// Flattening to basename() collided whenever discs number tracks independently
// (CD1/01.flac + CD2/01.flac), and renameSync overwrites in silence — so the
// local copy of one disc was destroyed while the journal recorded a clean
// relocation. The library copy was never at risk; the dj zone was.
//
// Its own corpus, because it needs dj_collections to mirror the collection the
// multi-disc fixture assigns to.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { audioHash } from "../src/audioHash.ts";
import { cmdResolve } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdGc, cmdPropose } from "../src/commands-p3.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};
const PCP = "[Psychill & Chillout & Psydub]";

let corpus: Corpus;
let djZone: string;
let release: string; // the two-disc release with per-disc track numbering

const sc = (): Sidecar => readSidecar(join(release, ".intake.json"))!;

beforeAll(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  process.env.INTAKE_BEETS_SHIM = `bun ${join(import.meta.dir, "fakes", "fake-shim.ts")}`;

  const library = join(corpus.dir, "library");
  djZone = join(corpus.dir, "dj");
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${join(corpus.dir, "journal", "intake-journal.ndjson")}`,
      "gc:",
      `  dj_zone: ${djZone}`,
      `  dj_collections: ["${PCP}"]`,
      "",
    ].join("\n"),
  );

  // Two discs whose files share basenames: copied from the multi-disc fixture
  // (distinct audio, disc tags 1 and 2 intact) but renamed to bare numbers, as
  // rips that number per disc do.
  const src = join(corpus.income, "todo", "Asura [2003] Lost Eden (Ultimae Records; inre010)");
  release = join(corpus.income, "todo", "Asura [2004] Twin Discs (Ultimae Records; inre011)");
  for (const disc of [1, 2]) {
    const from = join(src, `CD${disc}`);
    const to = join(release, `CD${disc}`);
    mkdirSync(to, { recursive: true });
    readdirSync(from)
      .filter((n) => n.endsWith(".flac"))
      .sort()
      .forEach((n, i) => copyFileSync(join(from, n), join(to, `${String(i + 1).padStart(2, "0")}.flac`)));
  }

  expect((await cmdResolve([release], OPTS)).errors).toEqual([]);
  expect((await cmdPropose([release], OPTS)).errors).toEqual([]);
  expect(cmdApprove([release], OPTS).errors).toEqual([]);
  expect((await cmdExecute([release], OPTS)).errors).toEqual([]);
});

afterAll(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("the fixture really does have colliding basenames across discs", () => {
  const paths = sc().files.map((f) => f.path);
  expect(paths).toEqual(["CD1/01.flac", "CD1/02.flac", "CD1/03.flac", "CD2/01.flac", "CD2/02.flac", "CD2/03.flac"]);
  expect(new Set(paths.map((p) => p.split("/")[1]!)).size).toBe(3); // 6 files, 3 distinct names
});

test("gc --relocate-dj preserves the disc layout instead of flattening it", async () => {
  const before = sc();
  const result = await cmdGc([release], { ...OPTS, relocateDj: true });
  expect(result.errors).toEqual([]);
  const row = (result.data as { action: string; dj_dest: string }[])[0]!;
  expect(row.action).toBe("relocate_dj");
  expect(row.dj_dest.startsWith(djZone)).toBe(true);

  // All six files arrive, under their own disc dirs.
  expect(readdirSync(row.dj_dest).sort()).toEqual(["CD1", "CD2"]);
  for (const disc of ["CD1", "CD2"]) {
    expect(readdirSync(join(row.dj_dest, disc)).sort()).toEqual(["01.flac", "02.flac", "03.flac"]);
  }

  // Content check: under the flattening bug CD2 won the race and CD1/01.flac
  // held CD2's audio, so per-file hashes are what actually proves the fix.
  for (const f of before.files) {
    expect((await audioHash(join(row.dj_dest, f.path))).hash).toBe(f.audio_hash);
  }

  // Originals left the income tree; the sidecar is a gc_done tombstone.
  expect(existsSync(join(release, "CD1", "01.flac"))).toBe(false);
  expect(sc().status).toBe("gc_done");
});
