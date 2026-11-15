// CR-003 (doc 03 v1.2, "audio_hash"): a FLAC whose STREAMINFO MD5 is unset is
// keyed by the MD5 of its decoded audio, the value a correct STREAMINFO holds,
// so the provenance tag write at execute leaves the key alone. Without a
// usable `flac` decoder the file falls back to `fsha1:` (whole file), the root
// gets needs_review, and execute writes no tags to that file.
//
// Synthetic audio only: sine PCM encoded with `flac` into temp dirs. The
// decoder-missing runs go through a CLI subprocess with a PATH that holds
// `metaflac` but not `flac`, because Bun.which() reads PATH at process start
// and ignores later changes to process.env.PATH (see test/archive.test.ts).

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { audioHash } from "../src/audioHash.ts";
import { cmdResolve } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdGc, cmdPropose } from "../src/commands-p3.ts";
import { readJournal } from "../src/journal.ts";
import { loadGenreMap, saveGenreMap } from "../src/rules.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { sha1Hex } from "../src/util.ts";
import { setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};
const DTE = "[Downtempo & Electronica]";
const ARTIST = "Example Artist"; // placeholder name

let corpus: Corpus;
let library: string;
let journalPath: string;
let work: string; // raw PCM and unit-test files, outside the income tree
let noFlacBin: string; // PATH dir with metaflac only

const sc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;

function run(args: string[]): string {
  const proc = Bun.spawnSync(args, { stdout: "pipe", stderr: "pipe" });
  if (proc.exitCode !== 0) throw new Error(`${args[0]} failed: ${proc.stderr.toString()}`);
  return proc.stdout.toString();
}

/** Interleaved signed little-endian stereo PCM: a sine plus a little noise. */
function pcm(bps: 16 | 24, freq: number, seconds = 0.5, rate = 44100): Uint8Array {
  const bytes = bps / 8;
  const n = Math.round(rate * seconds);
  const out = new Uint8Array(n * 2 * bytes);
  const amp = ((1 << (bps - 1)) - 1) * 0.5;
  let o = 0;
  for (let i = 0; i < n; i++) {
    for (let c = 0; c < 2; c++) {
      const v = Math.round(Math.sin((2 * Math.PI * (freq + c * 110) * i) / rate) * amp) + ((i * 7919 + c) % 13) - 6;
      for (let k = 0; k < bytes; k++) out[o++] = (v >> (8 * k)) & 0xff;
    }
  }
  return out;
}

/** Encode synthetic PCM to `path` with flac (+ Vorbis tags); returns the STREAMINFO MD5. */
function encodeFlac(path: string, opts: { bps: 16 | 24; freq: number; tags?: Record<string, string> }): string {
  const raw = join(work, `pcm-${opts.bps}-${opts.freq}.raw`);
  writeFileSync(raw, pcm(opts.bps, opts.freq));
  mkdirSync(join(path, ".."), { recursive: true });
  run([
    "flac", "-s", "-f", "--force-raw-format", "--endian=little", "--sign=signed",
    "--channels=2", `--bps=${opts.bps}`, "--sample-rate=44100", "-o", path, raw,
  ]);
  const tags = Object.entries(opts.tags ?? {});
  if (tags.length) run(["metaflac", ...tags.map(([k, v]) => `--set-tag=${k}=${v}`), path]);
  return run(["metaflac", "--show-md5sum", path]).trim();
}

/** Zero the STREAMINFO MD5: a valid, decodable FLAC with an unset signature. */
function zeroMd5(path: string): void {
  const b = new Uint8Array(readFileSync(path));
  expect(String.fromCharCode(...b.subarray(0, 4))).toBe("fLaC");
  expect(b[4]! & 0x7f).toBe(0); // STREAMINFO is the first block: MD5 at [26, 42)
  b.fill(0, 26, 42);
  writeFileSync(path, b);
}

/** Flip bytes in the middle of the audio frames (frame CRCs then fail). */
function corruptFrames(path: string): void {
  const b = new Uint8Array(readFileSync(path));
  let off = 4;
  for (;;) {
    const last = b[off]! & 0x80;
    off += 4 + ((b[off + 1]! << 16) | (b[off + 2]! << 8) | b[off + 3]!);
    if (last) break;
  }
  const mid = off + ((b.length - off) >> 1);
  for (let i = mid; i < mid + 64; i++) b[i]! ^= 0xa5;
  writeFileSync(path, b);
}

function intakeTags(path: string): string[] {
  return run(["metaflac", "--export-tags-to=-", path]).split("\n").filter((l) => l.startsWith("INTAKE_"));
}

function trackTags(album: string, year: string, n: number, title: string): Record<string, string> {
  return { ARTIST, ALBUMARTIST: ARTIST, ALBUM: album, TITLE: title, TRACKNUMBER: String(n), DATE: year };
}

/** Run the CLI with flac absent from PATH (metaflac still present). */
function cliWithoutFlac(args: string[]): { code: number; envelope: Record<string, any> } {
  const proc = Bun.spawnSync([process.execPath, "run", CLI, ...args, "--json"], {
    env: { PATH: noFlacBin, INTAKE_RULES_DIR: corpus.rules },
    stdout: "pipe",
    stderr: "pipe",
  });
  const out = proc.stdout.toString();
  if (!out.trim()) throw new Error(`no stdout; stderr: ${proc.stderr.toString()}`);
  return { code: proc.exitCode, envelope: JSON.parse(out) };
}

beforeAll(() => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  process.env.INTAKE_BEETS_SHIM = `bun ${join(import.meta.dir, "fakes", "fake-shim.ts")}`;
  delete process.env.FAKE_SHIM_MODE;

  library = join(corpus.dir, "library");
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
  // The placeholder artist needs a prior so assign proposes a target.
  const genre = loadGenreMap(corpus.rules);
  genre.artists[ARTIST] = { [DTE]: 5 };
  saveGenreMap(corpus.rules, genre);

  work = mkdtempSync(join(tmpdir(), "intake-cr003-"));
  noFlacBin = join(work, "bin");
  mkdirSync(noFlacBin);
  const metaflac = Bun.which("metaflac");
  if (!metaflac || !Bun.which("flac")) throw new Error("flac and metaflac must be installed for this test");
  symlinkSync(metaflac, join(noFlacBin, "metaflac"));
});

afterAll(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  rmSync(corpus.dir, { recursive: true, force: true });
  rmSync(work, { recursive: true, force: true });
});

// ---- audio_hash ---------------------------------------------------------------

for (const bps of [16, 24] as const) {
  test(`${bps}-bit: decoded-audio key equals the STREAMINFO MD5 it stands in for`, async () => {
    const f = join(work, `unit-${bps}.flac`);
    const md5 = encodeFlac(f, { bps, freq: 440 + bps });
    expect(md5).toBe(new Bun.CryptoHasher("md5").update(pcm(bps, 440 + bps)).digest("hex")); // flac's own MD5
    expect(await audioHash(f)).toEqual({ hash: `flacmd5:${md5}`, issues: [] });

    zeroMd5(f);
    expect(run(["metaflac", "--show-md5sum", f]).trim()).toBe("0".repeat(32));
    expect(await audioHash(f)).toEqual({ hash: `flacmd5:${md5}`, issues: ["flac_md5_unset"] });
  });
}

test("unset MD5: a tag write leaves the key unchanged", async () => {
  const f = join(work, "unit-tags.flac");
  encodeFlac(f, { bps: 16, freq: 523 });
  zeroMd5(f);
  const before = await audioHash(f);
  const bytesBefore = readFileSync(f);
  run(["metaflac", "--set-tag=INTAKE_DATE=2026-01-01", "--set-tag=COMMENT=retag test", f]);
  expect(readFileSync(f)).not.toEqual(bytesBefore); // the tag write did change bytes
  expect(await audioHash(f)).toEqual(before);
  expect(before.hash).toStartWith("flacmd5:");
});

test("unset MD5 with corrupt frames: fsha1 fallback + flac_decode_failed", async () => {
  const f = join(work, "unit-corrupt.flac");
  encodeFlac(f, { bps: 16, freq: 587 });
  zeroMd5(f);
  corruptFrames(f);
  expect(await audioHash(f)).toEqual({
    hash: "fsha1:" + sha1Hex(new Uint8Array(readFileSync(f))),
    issues: ["flac_md5_unset", "flac_decode_failed"],
  });
});

test("decode failure in a release: the root needs review", async () => {
  const dir = join(corpus.income, "todo", `${ARTIST} [2021] Corrupt Frames`);
  encodeFlac(join(dir, "01 - First.flac"), { bps: 16, freq: 659, tags: trackTags("Corrupt Frames", "2021", 1, "First") });
  encodeFlac(join(dir, "02 - Second.flac"), { bps: 16, freq: 698, tags: trackTags("Corrupt Frames", "2021", 2, "Second") });
  zeroMd5(join(dir, "02 - Second.flac"));
  corruptFrames(join(dir, "02 - Second.flac"));
  const pristine = treeHash(dir);

  expect((await cmdResolve([dir], OPTS)).errors).toEqual([]);
  const doc = sc(dir);
  expect(doc.files[0]!.audio_hash).toStartWith("flacmd5:");
  expect(doc.files[1]!.audio_hash).toBe("fsha1:" + sha1Hex(new Uint8Array(readFileSync(join(dir, "02 - Second.flac")))));
  expect(doc.quality.issues).toContain("flac_md5_unset");
  expect(doc.quality.issues).toContain("flac_decode_failed");
  expect(doc.cluster.needs_review).toBe(true);
  expect(treeHash(dir)).toBe(pristine); // resolve never mutates inputs
});

// ---- CR-003 regression gate -----------------------------------------------------

test("unset-MD5 FLAC with metaflac on PATH: placed, verified, tagged, gc re-verifies", async () => {
  // Committed fixture: 01 and 02 have an unset MD5, 03 is normal.
  const dir = join(corpus.income, "todo", "Bluetech [2011] Cosmic Dubwise");
  expect((await cmdResolve([dir], OPTS)).errors).toEqual([]);
  expect((await cmdPropose([dir], OPTS)).errors).toEqual([]);
  expect(cmdApprove([dir], OPTS).errors).toEqual([]);

  const result = await cmdExecute([dir], OPTS);
  // Before CR-003: E_VERIFY "hash mismatch" (the tag write changed the
  // whole-file key), and the root fell back to approved.
  expect(result.errors).toEqual([]);
  const doc = sc(dir);
  expect(doc.status).toBe("placed");
  expect(doc.placed!.verified).toBe(true);

  // Keyed by the decoded audio, marked as computed.
  expect(doc.files.map((f) => f.audio_hash.split(":")[0])).toEqual(["flacmd5", "flacmd5", "flacmd5"]);
  expect(doc.quality.issues).toContain("flac_md5_unset");
  expect(readJournal(journalPath).find((r) => r.sidecar_id === doc.id)!.audio_hashes).toEqual(
    doc.files.map((f) => f.audio_hash),
  );

  // Every copy carries the provenance tags; none was skipped.
  const target = doc.placed!.target_path;
  for (const f of doc.files) {
    const tags = intakeTags(join(target, f.path));
    expect(tags.some((t) => t.startsWith("INTAKE_DATE="))).toBe(true);
    expect(tags).toContain("INTAKE_SOURCE=manual");
    expect(tags.some((t) => t.startsWith("INTAKE_BATCH=b"))).toBe(true);
    expect((await audioHash(join(target, f.path))).hash).toBe(f.audio_hash);
  }
  expect((result.data as { issues: string[] }[])[0]!.issues).toEqual([]);

  const gc = await cmdGc([dir], OPTS);
  expect(gc.errors).toEqual([]);
  expect(sc(dir).status).toBe("gc_done");
});

test("flac absent: fsha1 fallback, needs_review, no tags on that copy, still placed", async () => {
  // 01 has its MD5 set (keyed from STREAMINFO, tagged as usual); 02 has it
  // unset and cannot be decoded without flac.
  const dir = join(corpus.income, "todo", `${ARTIST} [2020] Decoder Missing`);
  const md5One = encodeFlac(join(dir, "01 - One.flac"), { bps: 16, freq: 740, tags: trackTags("Decoder Missing", "2020", 1, "One") });
  encodeFlac(join(dir, "02 - Two.flac"), { bps: 16, freq: 784, tags: trackTags("Decoder Missing", "2020", 2, "Two") });
  zeroMd5(join(dir, "02 - Two.flac"));
  const twoBytes = new Uint8Array(readFileSync(join(dir, "02 - Two.flac")));
  const pristine = treeHash(dir);

  const resolved = cliWithoutFlac(["resolve", dir]);
  expect(resolved.envelope.errors).toEqual([]);
  expect(resolved.code).toBe(0);
  expect(treeHash(dir)).toBe(pristine);
  let doc = sc(dir);
  expect(doc.files.map((f) => f.audio_hash)).toEqual([`flacmd5:${md5One}`, "fsha1:" + sha1Hex(twoBytes)]);
  expect(doc.quality.issues).toContain("flac_md5_unset");
  expect(doc.quality.issues).toContain("flac_decoder_missing");
  expect(doc.cluster.needs_review).toBe(true);

  expect((await cmdPropose([dir], OPTS)).errors).toEqual([]);
  expect(cmdApprove([dir], OPTS).errors).toEqual([]);

  // Execute with flac still absent and metaflac present.
  const executed = cliWithoutFlac(["execute", dir]);
  expect(executed.envelope.errors).toEqual([]);
  expect(executed.code).toBe(0);
  expect(executed.envelope.data[0].issues).toEqual(["provenance_tags_skipped:flac_fsha1"]);
  doc = sc(dir);
  expect(doc.status).toBe("placed");
  expect(doc.placed!.verified).toBe(true);
  const target = doc.placed!.target_path;
  expect(intakeTags(join(target, "02 - Two.flac"))).toEqual([]);
  expect(new Uint8Array(readFileSync(join(target, "02 - Two.flac")))).toEqual(twoBytes);
  expect(intakeTags(join(target, "01 - One.flac"))).toContain("INTAKE_SOURCE=manual");

  // gc in this process, where flac IS on PATH: the fsha1 key is still checked
  // as a whole-file SHA1, not re-keyed to the decoded audio.
  const gc = await cmdGc([dir], OPTS);
  expect(gc.errors).toEqual([]);
  expect(sc(dir).status).toBe("gc_done");
});

test("flac absent at execute for a decoded-audio key: verify refuses and says why", async () => {
  const dir = join(corpus.income, "todo", `${ARTIST} [2022] Verify Needs Flac`);
  encodeFlac(join(dir, "01 - Alpha.flac"), { bps: 16, freq: 831, tags: trackTags("Verify Needs Flac", "2022", 1, "Alpha") });
  encodeFlac(join(dir, "02 - Beta.flac"), { bps: 16, freq: 880, tags: trackTags("Verify Needs Flac", "2022", 2, "Beta") });
  zeroMd5(join(dir, "01 - Alpha.flac"));
  expect((await cmdResolve([dir], OPTS)).errors).toEqual([]); // flac on PATH here
  expect(sc(dir).files[0]!.audio_hash).toStartWith("flacmd5:");
  expect((await cmdPropose([dir], OPTS)).errors).toEqual([]);
  expect(cmdApprove([dir], OPTS).errors).toEqual([]);

  const executed = cliWithoutFlac(["execute", dir]);
  expect(executed.code).not.toBe(0);
  expect(executed.envelope.errors).toEqual([
    { code: "E_VERIFY", msg: "verify failed: flac decoder missing: 01 - Alpha.flac", path: dir },
  ]);
  const doc = sc(dir);
  expect(doc.status).toBe("approved");
  expect(existsSync(doc.proposal!.target_path!)).toBe(false);
});
