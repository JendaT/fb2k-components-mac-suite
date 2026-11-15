// Resolver: Various Artists releases whose album-artist tags are per track
// stay one root (doc 01 "Various Artists releases"); same-titled albums by
// different artists, and an artist album with guests, keep their old outcome.
// The two-disc case is in the golden corpus; these flat dirs are generated
// here. Placeholder names only.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { cmdAssign, type P2Deps } from "../src/commands-p2.ts";
import { cmdPropose } from "../src/commands-p3.ts";
import type { Providers } from "../src/providers.ts";
import { loadGenreMap, type OverrideEvent } from "../src/rules.ts";
import { readSidecar } from "../src/sidecar.ts";
import { isVariousArtists } from "../src/util.ts";
import { collectSidecars, setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = { json: true, dryRun: false, force: false, filters: {} };
const ALBUM = "Example Compilation";

let corpus: Corpus;
let base: string;
let freq = 2000;

async function tone(path: string, tags: Record<string, string | number>): Promise<void> {
  mkdirSync(dirname(path), { recursive: true });
  const args = [
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", `sine=frequency=${(freq += 37)}:duration=0.2:sample_rate=44100`,
  ];
  for (const [k, v] of Object.entries(tags)) args.push("-metadata", `${k}=${v}`);
  args.push("-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3", path);
  const proc = Bun.spawn(args, { stdout: "ignore", stderr: "pipe" });
  if ((await proc.exited) !== 0) throw new Error(`ffmpeg failed: ${await new Response(proc.stderr).text()}`);
}

/** One mp3 per [albumartist, track]; artist = album artist, one album tag. */
async function release(dir: string, tracks: [string, number][], album = ALBUM): Promise<void> {
  for (const [i, [artist, track]] of tracks.entries()) {
    await tone(join(base, dir, `${String(i + 1).padStart(2, "0")} ${artist} - Song ${i + 1}.mp3`), {
      album_artist: artist, artist, album, title: `Song ${i + 1}`, track, date: "2012",
    });
  }
}

type Doc = {
  virtual: boolean;
  singles?: true;
  discs: unknown;
  files: { path: string }[];
  cluster: { albumartist: string | null; signals: { seq: number } };
};

function sidecarsOf(dir: string): Doc[] {
  return collectSidecars(join(base, dir)).map(([, doc]) => doc as unknown as Doc);
}

beforeAll(async () => {
  corpus = setupCorpus();
  base = join(corpus.dir, "va");
  // Flat VA compilation: every track by a different artist, tracks 1..5.
  await release("Example Flat Compilation", [
    ["Artist One", 1], ["Artist Two", 2], ["Artist Three", 3], ["Artist Four", 4], ["Artist Five", 5],
  ]);
  // Flat VA compilation with the disc in the track number, no disc dirs.
  await release("Example Numbered Compilation", [
    ["Artist One", 101], ["Artist Two", 102], ["Artist Three", 201], ["Artist Four", 202], ["Artist Five", 203],
  ]);
  // Two artists' albums with the same title in one dir: positions collide.
  await release("Same Title Two Artists", [
    ["Artist Alpha", 1], ["Artist Alpha", 2], ["Artist Alpha", 3],
    ["Artist Beta", 1], ["Artist Beta", 2], ["Artist Beta", 3],
  ]);
  // Three artists, same title: only the position check keeps them apart.
  await release("Same Title Three Artists", [
    ["Artist Alpha", 1], ["Artist Alpha", 2], ["Artist Beta", 1], ["Artist Beta", 2], ["Artist Gamma", 1], ["Artist Gamma", 2],
  ]);
  // Artist album with per-track album artists for its guest tracks: the lead
  // credit holds most files, so it stays the lead artist's album.
  await release("Lead Artist - Example Album", [
    ["Lead Artist", 1], ["Lead Artist", 2], ["Lead Artist", 3], ["Lead Artist feat. Guest One", 4],
    ["Guest Two", 5], ["Guest Three", 6],
  ], "Example Album");
  const result = await cmdResolve([base], OPTS);
  expect(result.errors).toEqual([]);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("flat VA compilation (tracks 1..n) is one root credited to Various Artists", () => {
  const docs = sidecarsOf("Example Flat Compilation");
  expect(docs.length).toBe(1);
  const doc = docs[0]!;
  expect(doc.virtual).toBe(false);
  expect(doc.singles).toBeUndefined();
  expect(doc.discs).toBeNull();
  expect(doc.files.length).toBe(5);
  expect(doc.cluster.albumartist).toBe("Various Artists");
  expect(doc.cluster.signals.seq).toBe(1);
});

test("flat VA compilation numbered 101.., 201.. is one root with complete track sequence", () => {
  const docs = sidecarsOf("Example Numbered Compilation");
  expect(docs.length).toBe(1);
  expect(docs[0]!.virtual).toBe(false);
  expect(docs[0]!.discs).toBeNull();
  expect(docs[0]!.cluster.albumartist).toBe("Various Artists");
  expect(docs[0]!.cluster.signals.seq).toBe(1);
});

test("two artists' same-titled albums in one dir still split per artist", () => {
  const docs = sidecarsOf("Same Title Two Artists");
  expect(docs.length).toBe(2);
  for (const d of docs) {
    expect(d.virtual).toBe(true);
    expect(d.files.length).toBe(3);
  }
  expect(docs.map((d) => d.cluster.albumartist).sort()).toEqual(["Artist Alpha", "Artist Beta"]);
});

test("three artists' same-titled albums with colliding track numbers still split", () => {
  const docs = sidecarsOf("Same Title Three Artists");
  expect(docs.length).toBe(3);
  for (const d of docs) expect(d.virtual).toBe(true);
  expect(docs.map((d) => d.cluster.albumartist).sort()).toEqual(["Artist Alpha", "Artist Beta", "Artist Gamma"]);
});

test("artist album with guest album artists stays the lead artist's album", () => {
  const docs = sidecarsOf("Lead Artist - Example Album");
  expect(docs.length).toBe(1);
  expect(docs[0]!.virtual).toBe(false);
  expect(docs[0]!.cluster.albumartist).toBe("Lead Artist");
});

test("a VA root lands in the compilations slot; propose proposes its [Compilations] target", async () => {
  const dir = join(base, "Example Flat Compilation");
  const assigned = await cmdAssign([dir], { ...OPTS, collection: "[Ambient]", by: "user" });
  expect(assigned.errors).toEqual([]);
  // Amendment 003: compilations get a real target_path under [Compilations]
  // (the fixture tier root does not exist, so the canonical slot name).
  const target = `/library/music.hq/[Ambient]/[Compilations]/Various Artists ${ALBUM}`;
  expect(readSidecar(join(dir, ".intake.json"))!.proposal).toMatchObject({
    structure_slot: "compilations", target_path: target,
  });
  const offline: P2Deps = {
    providers: { discogs: null, similar: null, shim: { identify: async () => ({ candidates: [] }) } } as Providers,
  };
  const proposed = await cmdPropose([dir], { ...OPTS, allResolved: false }, offline);
  expect(proposed.errors).toEqual([]);
  // Propose identifies the root and rebuilds the target at propose time, so
  // the release folder gains the identified year.
  expect(proposed.data).toMatchObject([{
    status: "proposed", target_path: `/library/music.hq/[Ambient]/[Compilations]/Various Artists [2012] ${ALBUM}`,
  }]);
});

test("a user override on a VA root is logged but adds no feedback for the VA credit", async () => {
  const dir = join(base, "Example Numbered Compilation");
  const assigned = await cmdAssign([dir], { ...OPTS, collection: "[Psytrance]", by: "user" });
  expect(assigned.errors).toEqual([]);
  const sc = readSidecar(join(dir, ".intake.json"))!;
  expect(sc.proposal).toMatchObject({
    target_collection: "[Psytrance]", assigned_by: "user", structure_slot: "compilations",
    target_path: `/library/music.hq/[Psytrance]/[Compilations]/Various Artists ${ALBUM}`,
  });

  const events = Bun.YAML.parse(readFileSync(join(corpus.rules, "overrides.log.yaml"), "utf8")) as OverrideEvent[];
  expect(events.filter((e) => e.sidecar_id === sc.id)).toMatchObject([
    { artist: "Various Artists", collection: "[Psytrance]", by: "user" },
  ]);

  const genre = loadGenreMap(corpus.rules);
  expect(Object.keys(genre.feedback).filter((k) => isVariousArtists(k))).toEqual([]);
});
