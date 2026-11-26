// MP3 provenance at execute (src/provenance.ts, mp3MergeTags): the TXXX
// INTAKE_* frames are merged into the file's own ID3v2 tag. The writer used to
// put a second ID3v2.3 tag, holding only those frames, in front of the
// original one: mutagen (beets) reads only the first tag and saw no title,
// artist or album. Its TXXX text was UTF-8 behind a Latin-1 encoding byte.
// Tags the writer cannot rebuild safely are refused with the file untouched.
//
// Synthetic mp3s made with ffmpeg in a temp dir. The mutagen checks run under
// INTAKE_PYTHON or the Python of the `beet` shebang, skipped when neither
// imports mutagen. Synthetic names only.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { audioHash } from "../src/audioHash.ts";
import { cmdResolve } from "../src/commands.ts";
import type { P2Deps } from "../src/commands-p2.ts";
import { cmdApprove, cmdExecute, cmdPropose } from "../src/commands-p3.ts";
import { writeProvenance, type ProvenanceTags } from "../src/provenance.ts";
import { readFirstLine, shebangPython, type Providers } from "../src/providers.ts";
import { loadGenreMap, saveGenreMap } from "../src/rules.ts";
import { readSidecar } from "../src/sidecar.ts";
import { makeTierRoots, setupCorpus, type Corpus } from "./helpers.ts";

type Kind = "v3" | "v4" | "none";

const META = { title: "Example Title", artist: "Example Artist", album: "Example Album" };
const TAGS: ProvenanceTags = { INTAKE_DATE: "2026-11-25", INTAKE_SOURCE: "web", INTAKE_BATCH: "b20261125-0001" };
const TAGS2: ProvenanceTags = { INTAKE_DATE: "2026-11-26", INTAKE_SOURCE: "soulseek", INTAKE_BATCH: "b20261126-0002" };

let dir: string;
let seq = 0;
const base = {} as Record<Kind, string>;

// ---------------------------------------------------------------- helpers

async function makeMp3(path: string, id3: 0 | 3 | 4, freq: number, meta = META): Promise<void> {
  mkdirSync(dirname(path), { recursive: true });
  const args = [
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", `sine=frequency=${freq}:duration=0.3:sample_rate=44100`,
  ];
  for (const [k, v] of Object.entries(meta)) args.push("-metadata", `${k}=${v}`);
  args.push("-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", String(id3), path);
  const proc = Bun.spawn(args, { stdout: "ignore", stderr: "pipe" });
  if ((await proc.exited) !== 0) throw new Error(`ffmpeg failed: ${await new Response(proc.stderr).text()}`);
}

/** A fresh copy of a base file, or of `bytes`, in the temp dir. */
function freshFile(src: Kind | Uint8Array): string {
  const p = join(dir, `case-${++seq}.mp3`);
  if (typeof src === "string") copyFileSync(base[src], p);
  else writeFileSync(p, src);
  return p;
}

const bytes = (p: string) => new Uint8Array(readFileSync(p));
const latin1 = (b: Uint8Array, off: number, len: number) => Buffer.from(b.subarray(off, off + len)).toString("latin1");
const syncsafe = (b: Uint8Array, o: number) => (b[o]! << 21) | (b[o + 1]! << 14) | (b[o + 2]! << 7) | b[o + 3]!;
const u32 = (b: Uint8Array, o: number) => ((b[o]! << 24) | (b[o + 1]! << 16) | (b[o + 2]! << 8) | b[o + 3]!) >>> 0;
const syncsafeBytes = (n: number) => [(n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f];

interface RawFrame { id: string; off: number; body: Uint8Array }
interface RawTag {
  version: number;
  flags: number;
  size: number; // header size: frames + padding
  framesEnd: number; // first padding byte (or the frames area end)
  end: number; // first byte after the tag, footer included
  frames: RawFrame[];
}

/** The ID3v2 tag at offset 0, read without the code under test. */
function rawTag(b: Uint8Array): RawTag {
  expect(latin1(b, 0, 3)).toBe("ID3");
  const version = b[3]!;
  const flags = b[5]!;
  const size = syncsafe(b, 6);
  const frames: RawFrame[] = [];
  let off = 10;
  while (off + 10 <= 10 + size && b[off] !== 0) {
    const n = version === 4 ? syncsafe(b, off + 4) : u32(b, off + 4);
    frames.push({ id: latin1(b, off, 4), off, body: b.subarray(off + 10, off + 10 + n) });
    off += 10 + n;
  }
  return { version, flags, size, framesEnd: off, end: 10 + size + (flags & 0x10 ? 10 : 0), frames };
}

/** No second ID3v2 tag right after the first one. */
function expectOneTag(b: Uint8Array): RawTag {
  const tag = rawTag(b);
  expect(latin1(b, tag.end, 3)).not.toBe("ID3");
  return tag;
}

const txxx = (tag: RawTag) => tag.frames.filter((f) => f.id === "TXXX");

function ffprobeTags(path: string): Record<string, string> {
  const r = Bun.spawnSync(["ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "json", path], {
    stdout: "pipe", stderr: "pipe",
  });
  if (r.exitCode !== 0) throw new Error(`ffprobe failed: ${r.stderr.toString()}`);
  return JSON.parse(r.stdout.toString()).format?.tags ?? {};
}

function findMutagenPython(): string | null {
  const beet = Bun.which("beet");
  for (const py of [process.env.INTAKE_PYTHON, beet ? shebangPython(readFirstLine(beet)) : null]) {
    if (!py) continue;
    try {
      if (Bun.spawnSync([py, "-I", "-c", "import mutagen"], { stdout: "ignore", stderr: "ignore" }).exitCode === 0) return py;
    } catch {
      // not runnable: try the next one
    }
  }
  return null;
}

const PYTHON = findMutagenPython();
const withMutagen = test.skipIf(PYTHON === null);

const MUTAGEN_SCRIPT = [
  "import json, sys",
  "from mutagen.id3 import ID3",
  "t = ID3(sys.argv[1])",
  "print(json.dumps({'version': list(t.version),",
  "  'frames': {k: [str(x) for x in getattr(f, 'text', [])] for k, f in t.items()}}))",
].join("\n");

/** What mutagen reads: the first ID3v2 tag only, as beets does. */
function mutagen(path: string): { version: number[]; frames: Record<string, string[]> } {
  const r = Bun.spawnSync([PYTHON!, "-I", "-c", MUTAGEN_SCRIPT, path], { stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`mutagen failed: ${r.stderr.toString()}`);
  return JSON.parse(r.stdout.toString());
}

function expectMutagenIntake(path: string, version: number, tags: ProvenanceTags): void {
  const m = mutagen(path);
  expect(m.version).toEqual([2, version, 0]);
  expect(m.frames.TIT2).toEqual([META.title]);
  expect(m.frames.TPE1).toEqual([META.artist]);
  expect(m.frames.TALB).toEqual([META.album]);
  // One value each: a duplicate frame in the tag would show as a second one.
  for (const [k, v] of Object.entries(tags)) expect(m.frames[`TXXX:${k}`]).toEqual([v]);
}

async function write(path: string, tags: ProvenanceTags = TAGS): Promise<void> {
  expect(await writeProvenance(path, tags, (await audioHash(path)).hash)).toEqual({ written: true, issue: null });
}

// ---------------------------------------------------------------- setup

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), "intake-id3-"));
  base.v3 = join(dir, "base-v3.mp3");
  base.v4 = join(dir, "base-v4.mp3");
  base.none = join(dir, "base-none.mp3");
  await makeMp3(base.v3, 3, 440);
  await makeMp3(base.v4, 4, 550);
  await makeMp3(base.none, 0, 660);
  expect(rawTag(bytes(base.v3)).version).toBe(3);
  expect(rawTag(bytes(base.v4)).version).toBe(4);
  expect(latin1(bytes(base.none), 0, 3)).not.toBe("ID3");
});

afterAll(() => {
  rmSync(dir, { recursive: true, force: true });
});

// ---------------------------------------------------------------- merge

describe.each([["v3", 3], ["v4", 4]] as const)("%s tag", (kind, version) => {
  test("one tag at the head keeps the original frames and gains the INTAKE frames; version, audio, hash kept", async () => {
    const p = freshFile(kind);
    const before = bytes(p);
    const beforeTag = rawTag(before);
    const hash = (await audioHash(p)).hash;
    await write(p);

    const after = bytes(p);
    const tag = expectOneTag(after);
    expect(after[3]).toBe(version);
    expect(tag.flags).toBe(beforeTag.flags);
    // Every original frame verbatim, in order, then the three TXXX frames.
    const kept = beforeTag.frames.map((f) => latin1(before, f.off, 10 + f.body.length));
    expect(tag.frames.slice(0, kept.length).map((f) => latin1(after, f.off, 10 + f.body.length))).toEqual(kept);
    expect(tag.frames.map((f) => f.id)).toEqual([...beforeTag.frames.map((f) => f.id), "TXXX", "TXXX", "TXXX"]);
    expect(tag.frames.map((f) => f.id)).toEqual(expect.arrayContaining(["TIT2", "TPE1", "TALB"]));
    // Audio bytes after the tag byte-identical; the key is unchanged.
    expect(Buffer.from(after.subarray(tag.end)).equals(Buffer.from(before.subarray(beforeTag.end)))).toBe(true);
    expect((await audioHash(p)).hash).toBe(hash);

    const probe = ffprobeTags(p);
    expect(probe).toMatchObject({ ...META, ...TAGS });
  });

  test("a second write replaces the INTAKE frames: no duplicates, new values", async () => {
    const p = freshFile(kind);
    const hash = (await audioHash(p)).hash;
    await write(p, TAGS);
    const first = rawTag(bytes(p)).frames.map((f) => f.id);
    await write(p, TAGS2);

    const tag = expectOneTag(bytes(p));
    expect(tag.frames.map((f) => f.id)).toEqual(first);
    expect(txxx(tag)).toHaveLength(3);
    expect(ffprobeTags(p)).toMatchObject({ ...META, ...TAGS2 });
    expect((await audioHash(p)).hash).toBe(hash);
  });

  test.each([
    ["web-ü", 0], // Latin-1 range: encoding 0, real Latin-1 bytes
    ["web-ř", version === 3 ? 1 : 3], // beyond Latin-1: UTF-16 with BOM (v2.3), UTF-8 (v2.4)
  ])("non-ASCII INTAKE_SOURCE %p reads back exactly (encoding %p)", async (source, encoding) => {
    const p = freshFile(kind);
    await write(p, { ...TAGS, INTAKE_SOURCE: source });
    const tag = expectOneTag(bytes(p));
    for (const f of txxx(tag)) {
      const isSource = latin1(f.body, 0, 40).replace(/\0/g, "").includes("INTAKE_SOURCE");
      expect(f.body[0]).toBe(isSource ? encoding : 0);
    }
    expect(ffprobeTags(p).INTAKE_SOURCE).toBe(source);
  });

  withMutagen("mutagen reads TIT2, TPE1, TALB and the INTAKE frames from the one tag", async () => {
    const p = freshFile(kind);
    await write(p);
    expectMutagenIntake(p, version, TAGS);
  });

  withMutagen("mutagen after a second write: only the new INTAKE values", async () => {
    const p = freshFile(kind);
    await write(p, TAGS);
    await write(p, TAGS2);
    expectMutagenIntake(p, version, TAGS2);
  });

  withMutagen("mutagen reads non-ASCII INTAKE_SOURCE values exactly", async () => {
    for (const source of ["web-ü", "web-ř"]) {
      const p = freshFile(kind);
      await write(p, { ...TAGS, INTAKE_SOURCE: source });
      expectMutagenIntake(p, version, { ...TAGS, INTAKE_SOURCE: source });
    }
  });
});

test("no ID3v2 tag: a new ID3v2.3 tag with the three frames, the original bytes unchanged after it", async () => {
  const p = freshFile("none");
  const before = bytes(p);
  const hash = (await audioHash(p)).hash;
  await write(p);

  const after = bytes(p);
  const tag = expectOneTag(after);
  expect(tag.version).toBe(3);
  expect(tag.flags).toBe(0);
  expect(tag.frames.map((f) => f.id)).toEqual(["TXXX", "TXXX", "TXXX"]);
  expect(Buffer.from(after.subarray(tag.end)).equals(Buffer.from(before))).toBe(true);
  expect((await audioHash(p)).hash).toBe(hash);
  expect(ffprobeTags(p)).toMatchObject(TAGS);
});

test.each(["web-ü", "web-ř"])("no ID3v2 tag: non-ASCII INTAKE_SOURCE %p reads back exactly", async (source) => {
  // One tag either way, so only the text encoding is under test here.
  const p = freshFile("none");
  await write(p, { ...TAGS, INTAKE_SOURCE: source });
  expect(ffprobeTags(p).INTAKE_SOURCE).toBe(source);
  if (PYTHON) expect(mutagen(p).frames["TXXX:INTAKE_SOURCE"]).toEqual([source]);
});

test("padding:a tag whose padding holds the new frames keeps its size", async () => {
  // The v2.3 base with 1024 bytes of padding added to its tag.
  const b = bytes(base.v3);
  const tag = rawTag(b);
  const size = tag.framesEnd - 10 + 1024;
  const padded = new Uint8Array([
    ...b.subarray(0, 6), ...syncsafeBytes(size), ...b.subarray(10, tag.framesEnd), ...new Uint8Array(1024), ...b.subarray(tag.end),
  ]);
  const p = freshFile(padded);
  const hash = (await audioHash(p)).hash;
  await write(p);

  const after = bytes(p);
  const merged = expectOneTag(after);
  expect(merged.size).toBe(size);
  expect(after.length).toBe(padded.length);
  expect(merged.frames.map((f) => f.id)).toEqual([...tag.frames.map((f) => f.id), "TXXX", "TXXX", "TXXX"]);
  expect((await audioHash(p)).hash).toBe(hash);
});

describe("v2.4 tag with a footer", () => {
  /** The v2.4 base rebuilt with flag 0x10, no padding and a "3DI" footer. */
  function withFooter(): Uint8Array {
    const b = bytes(base.v4);
    const tag = rawTag(b);
    const size = tag.framesEnd - 10;
    const head = [4, b[4]!, 0x10, ...syncsafeBytes(size)];
    return new Uint8Array([
      0x49, 0x44, 0x33, ...head, ...b.subarray(10, tag.framesEnd), 0x33, 0x44, 0x49, ...head, ...b.subarray(tag.end),
    ]);
  }

  test("footer rebuilt and valid, no padding, one tag, audio and hash kept", async () => {
    const before = withFooter();
    const p = freshFile(before);
    const beforeTag = rawTag(before);
    const hash = (await audioHash(p)).hash;
    await write(p);

    const after = bytes(p);
    const tag = expectOneTag(after);
    expect([tag.version, tag.flags]).toEqual([4, 0x10]);
    expect(tag.framesEnd).toBe(10 + tag.size); // no padding
    const footer = after.subarray(10 + tag.size, 20 + tag.size);
    expect(latin1(footer, 0, 3)).toBe("3DI");
    expect(Array.from(footer.subarray(3))).toEqual(Array.from(after.subarray(3, 10)));
    expect(tag.frames.map((f) => f.id)).toEqual([...beforeTag.frames.map((f) => f.id), "TXXX", "TXXX", "TXXX"]);
    expect(Buffer.from(after.subarray(tag.end)).equals(Buffer.from(before.subarray(beforeTag.end)))).toBe(true);
    expect((await audioHash(p)).hash).toBe(hash);
    expect(ffprobeTags(p)).toMatchObject({ ...META, ...TAGS });
  });

  withMutagen("mutagen reads the rebuilt tag", async () => {
    const p = freshFile(withFooter());
    await write(p);
    expectMutagenIntake(p, 4, TAGS);
  });
});

// ---------------------------------------------------------------- refusals

/** A copy of a base file's bytes with `edit` applied. */
function edited(kind: Kind, edit: (b: Uint8Array, tag: RawTag) => Uint8Array | void): Uint8Array {
  const b = bytes(base[kind]);
  return edit(b, rawTag(b)) ?? b;
}

test.each<[string, () => Uint8Array]>([
  ["the unsynchronisation flag", () => edited("v3", (b) => void (b[5]! |= 0x80))],
  ["an extended header", () => edited("v3", (b) => void (b[5]! |= 0x40))],
  ["ID3v2.2", () => edited("v3", (b) => void (b[3] = 2))],
  ["unknown header flags", () => edited("v4", (b) => void (b[5]! |= 0x01))],
  ["two stacked tags", () => edited("v3", (b, tag) => new Uint8Array([...b.subarray(0, tag.end), ...b]))],
  ["a frame size past the tag end", () => edited("v3", (b, tag) => b.set([0, 0, 0x7f, 0xff], tag.frames[0]!.off + 4))],
  ["a v2.4 frame size that is not syncsafe", () => edited("v4", (b, tag) => void (b[tag.frames[0]!.off + 7]! |= 0x80))],
  ["a bad frame ID", () => edited("v3", (b, tag) => void (b[tag.frames[1]!.off] = 0x61))],
  ["a non-zero byte in the padding", () => edited("v3", (b, tag) => {
    expect(tag.framesEnd).toBeLessThan(10 + tag.size);
    b[10 + tag.size - 1] = 1;
  })],
  ["a tag that runs past the end of the file", () => edited("v3", (b) => b.subarray(0, 40))],
])("refused, file untouched: %s", async (_name, build) => {
  const input = build();
  const p = freshFile(input);
  const r = await writeProvenance(p, TAGS, "mp3sha1:unused");
  expect(r.written).toBe(false);
  expect(r.issue).toStartWith("provenance_write_failed: ");
  expect(Buffer.from(bytes(p)).equals(Buffer.from(input))).toBe(true);
});

// ---------------------------------------------------------------- execute

describe("execute", () => {
  const OPTS = {
    json: true, dryRun: false, force: false, filters: {}, collection: null, by: null,
    allResolved: false, batch: null, approved: false, resume: false,
  };
  const OFFLINE: P2Deps = {
    providers: { discogs: null, similar: null, shim: { identify: async () => ({ candidates: [] }) } } as Providers,
  };
  const ARTIST = "Example Tagger";
  let corpus: Corpus;
  let root: string;

  beforeAll(async () => {
    corpus = setupCorpus();
    const library = join(corpus.dir, "library");
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
    makeTierRoots(corpus.rules);
    // An income folder whose source_type is beyond Latin-1.
    const income = join(corpus.rules, "income.yaml");
    writeFileSync(income, readFileSync(income, "utf8") + "  - name: extra\n    path: ../income/extra\n    source_type: web-ř\n");
    root = join(corpus.income, "extra", `${ARTIST} [2020] Merged Tags`);
    const meta = (n: number) => ({ ...META, artist: ARTIST, album_artist: ARTIST, album: "Merged Tags", title: `Song ${n}`, track: String(n), date: "2020" });
    await makeMp3(join(root, `01 ${ARTIST} - Song 1.mp3`), 3, 700, meta(1));
    await makeMp3(join(root, `02 ${ARTIST} - Song 2.mp3`), 4, 750, meta(2));
    const genre = loadGenreMap(corpus.rules);
    genre.artists[ARTIST] = { "[Downtempo & Electronica]": 2 };
    saveGenreMap(corpus.rules, genre);
  });

  afterAll(() => {
    rmSync(corpus.dir, { recursive: true, force: true });
  });

  test("a synthetic mp3 root is placed: one tag per file with the original title and the INTAKE frames", async () => {
    expect((await cmdResolve([root], OPTS)).errors).toEqual([]);
    expect((await cmdPropose([root], OPTS, OFFLINE)).errors).toEqual([]);
    expect(cmdApprove([root], OPTS).errors).toEqual([]);
    const executed = await cmdExecute([root], OPTS);
    expect(executed.errors).toEqual([]);

    const doc = readSidecar(join(root, ".intake.json"))!;
    expect(doc.status).toBe("placed");
    expect(doc.source.source_type).toBe("web-ř");
    const target = doc.placed!.target_path;
    expect(readdirSync(target).filter((n) => n.endsWith(".mp3"))).toHaveLength(2);
    for (const [i, f] of doc.files.entries()) {
      const placed = join(target, f.path);
      const tag = expectOneTag(bytes(placed));
      expect(tag.version).toBe(bytes(join(root, f.path))[3]!);
      expect(tag.frames.map((x) => x.id)).toEqual(expect.arrayContaining(["TIT2", "TPE1", "TALB"]));
      expect(txxx(tag)).toHaveLength(3);
      expect((await audioHash(placed)).hash).toBe(f.audio_hash);
      const probe = ffprobeTags(placed);
      expect(probe.title).toBe(`Song ${i + 1}`);
      expect(probe.INTAKE_SOURCE).toBe("web-ř");
      expect(probe.INTAKE_DATE).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(probe.INTAKE_BATCH).toBeTruthy();
      if (PYTHON) expect(mutagen(placed).frames["TIT2"]).toEqual([`Song ${i + 1}`]);
    }
  });
});
