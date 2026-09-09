// audio_hash algorithm tests (doc 03 normative): correct container parsing
// and the key invariant — tag edits do not change the hash for
// flac/mp3/wav/aiff.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { audioHash, audioHashBuffer } from "../src/audioHash.ts";
import { sha1Hex } from "../src/util.ts";
import { FIXTURES } from "./helpers.ts";

const INCOME = join(FIXTURES, "income");
const FLAC = join(INCOME, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)", "01 - Iliona.flac");
const MP3 = join(INCOME, "todo", "Koan-Condemned-(MKL033)-WEB-2016-KOAN", "01 - Condemned.mp3");
const WAV = join(INCOME, "slsk", "loose", "hol_baumann_endless_park.wav");
const AIFF = join(INCOME, "slsk", "loose", "miktek_awakenings.aiff");
const OGG = join(INCOME, "slsk", "loose", "cell_calling_earth.ogg");

let tmp: string;

beforeAll(() => {
  tmp = mkdtempSync(join(tmpdir(), "intake-hash-"));
});

afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

async function retagged(src: string, out: string): Promise<string> {
  const proc = Bun.spawn(
    ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-c", "copy",
     "-metadata", "title=Completely Different Title", "-metadata", "comment=retag test", out],
    { stdout: "ignore", stderr: "pipe" },
  );
  expect(await proc.exited).toBe(0);
  return out;
}

test("flacmd5 matches metaflac --show-md5sum", async () => {
  const { hash, issues } = await audioHash(FLAC);
  expect(issues).toEqual([]);
  const proc = Bun.spawn(["metaflac", "--show-md5sum", FLAC], { stdout: "pipe" });
  const md5 = (await new Response(proc.stdout).text()).trim();
  expect(hash).toBe(`flacmd5:${md5}`);
});

for (const [name, src, ext] of [
  ["flac", FLAC, "flac"],
  ["wav", WAV, "wav"],
  ["aiff", AIFF, "aiff"],
] as const) {
  test(`${name}: tag edit does not change audio_hash`, async () => {
    const before = await audioHash(src);
    const out = await retagged(src, join(tmp, `retag.${ext}`));
    const after = await audioHash(out);
    expect(readFileSync(out)).not.toEqual(readFileSync(src)); // tags did change bytes
    expect(after.hash).toBe(before.hash);
  });
}

test("mp3: ID3v2 rewrite does not change audio_hash", async () => {
  // ffmpeg -c copy remuxes (rewrites the Xing/Info frame), so simulate what a
  // real tag editor does: replace only the ID3v2 block, keep audio bytes.
  const orig = new Uint8Array(readFileSync(MP3));
  expect(String.fromCharCode(...orig.subarray(0, 3))).toBe("ID3");
  const before = audioHashBuffer("x.mp3", orig);

  const oldSize =
    ((orig[6]! & 0x7f) << 21) | ((orig[7]! & 0x7f) << 14) | ((orig[8]! & 0x7f) << 7) | (orig[9]! & 0x7f);
  const audio = orig.subarray(10 + oldSize);
  const newTagBody = new Uint8Array(300).fill(0x20); // bigger, different content
  const header = new Uint8Array([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, (300 >> 7) & 0x7f, 300 & 0x7f]);
  const retag = new Uint8Array([...header, ...newTagBody, ...audio]);

  const after = audioHashBuffer("x.mp3", retag);
  expect(after.hash).toBe(before.hash);
});

test("mp3: appended ID3v1 and APEv2 tails are excluded", async () => {
  const orig = readFileSync(MP3);
  const { hash } = audioHashBuffer("x.mp3", new Uint8Array(orig));

  // ID3v1: 128-byte "TAG" block at the end.
  const id3v1 = new Uint8Array(128);
  id3v1.set([0x54, 0x41, 0x47]); // "TAG"
  const withV1 = new Uint8Array([...orig, ...id3v1]);
  expect(audioHashBuffer("x.mp3", withV1).hash).toBe(hash);

  // APEv2: footer-only empty tag (32 bytes, size=32, no header flag).
  const ape = new Uint8Array(32);
  ape.set(new TextEncoder().encode("APETAGEX"));
  new DataView(ape.buffer).setUint32(8, 2000, true); // version
  new DataView(ape.buffer).setUint32(12, 32, true); // size incl footer
  const withApe = new Uint8Array([...orig, ...ape]);
  expect(audioHashBuffer("x.mp3", withApe).hash).toBe(hash);
});

test("flac with unset STREAMINFO MD5 falls back to fsha1 + issue", () => {
  const buf = new Uint8Array(readFileSync(FLAC));
  buf.fill(0, 8 + 18, 8 + 34); // zero the MD5 inside STREAMINFO
  const { hash, issues } = audioHashBuffer("x.flac", buf);
  expect(issues).toEqual(["flac_md5_unset"]);
  expect(hash).toBe("fsha1:" + sha1Hex(buf));
});

test("wav: hash is over the data chunk only", async () => {
  const { hash } = await audioHash(WAV);
  expect(hash).toStartWith("pcmsha1:");
  const b = readFileSync(WAV);
  // Locate the data chunk by scanning RIFF chunks the same way a third party would.
  let off = 12;
  let found = "";
  while (off + 8 <= b.length) {
    const id = b.toString("latin1", off, off + 4);
    const size = b.readUInt32LE(off + 4);
    if (id === "data") {
      found = sha1Hex(new Uint8Array(b.subarray(off + 8, off + 8 + size)));
      break;
    }
    off += 8 + size + (size & 1);
  }
  expect(hash).toBe(`pcmsha1:${found}`);
});

test("dsf: hash is over the data chunk payload (synthetic)", () => {
  const payload = new TextEncoder().encode("dsd-bitstream-payload");
  const fmt = new Uint8Array(52); // fmt chunk: id+size+content
  fmt.set(new TextEncoder().encode("fmt "));
  new DataView(fmt.buffer).setUint32(4, 52, true);
  const data = new Uint8Array(12 + payload.length);
  data.set(new TextEncoder().encode("data"));
  new DataView(data.buffer).setUint32(4, 12 + payload.length, true);
  data.set(payload, 12);
  const head = new Uint8Array(28);
  head.set(new TextEncoder().encode("DSD "));
  new DataView(head.buffer).setUint32(4, 28, true);
  const file = new Uint8Array([...head, ...fmt, ...data]);
  const { hash, issues } = audioHashBuffer("x.dsf", file);
  expect(issues).toEqual([]);
  expect(hash).toBe("pcmsha1:" + sha1Hex(payload));
});

test("ogg and unknown containers use whole-file fsha1", async () => {
  const { hash } = await audioHash(OGG);
  expect(hash).toBe("fsha1:" + sha1Hex(new Uint8Array(readFileSync(OGG))));
});

test("distinct fixture files produce distinct hashes", async () => {
  const dir = join(INCOME, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  const hashes = await Promise.all(
    ["01 - Iliona.flac", "02 - Signs.flac", "03 - Adonai.flac"].map(async (f) => (await audioHash(join(dir, f))).hash),
  );
  expect(new Set(hashes).size).toBe(3);
});
