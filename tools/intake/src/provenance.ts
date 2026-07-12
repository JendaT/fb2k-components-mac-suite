// Provenance tags at execute (doc 03): INTAKE_DATE, INTAKE_SOURCE,
// INTAKE_BATCH written to the COPIES only, via TXXX (mp3) / VorbisComment
// (flac). Writers must not change audio_hash: metaflac edits only metadata
// blocks (STREAMINFO MD5 untouched); for mp3 a fresh ID3v2.3 block is
// prepended, which mp3sha1 strips. Other formats are skipped with an issue.

import { readFileSync, writeFileSync } from "node:fs";
import { ext } from "./util.ts";

export interface ProvenanceTags {
  INTAKE_DATE: string;
  INTAKE_SOURCE: string;
  INTAKE_BATCH: string;
}

export interface TagWriteResult {
  written: boolean;
  issue: string | null;
}

async function metaflacSetTags(path: string, tags: ProvenanceTags): Promise<TagWriteResult> {
  if (Bun.which("metaflac") === null) return { written: false, issue: "metaflac_missing" };
  const args = ["metaflac"];
  for (const [k, v] of Object.entries(tags)) args.push(`--remove-tag=${k}`, `--set-tag=${k}=${v}`);
  args.push(path);
  const proc = Bun.spawn(args, { stdout: "ignore", stderr: "pipe" });
  if ((await proc.exited) !== 0) {
    const err = (await new Response(proc.stderr).text()).trim().slice(0, 120);
    return { written: false, issue: `metaflac_failed: ${err}` };
  }
  return { written: true, issue: null };
}

function syncSafe(n: number): number[] {
  return [(n >> 21) & 0x7f, (n >> 14) & 0x7f, (n >> 7) & 0x7f, n & 0x7f];
}

/** Build one ID3v2.3 TXXX frame (latin1 description + value). */
function txxxFrame(description: string, value: string): Uint8Array {
  const enc = new TextEncoder();
  const body = new Uint8Array([0, ...enc.encode(description), 0, ...enc.encode(value)]);
  const header = new Uint8Array(10);
  header.set(enc.encode("TXXX"));
  header[4] = (body.length >> 24) & 0xff;
  header[5] = (body.length >> 16) & 0xff;
  header[6] = (body.length >> 8) & 0xff;
  header[7] = body.length & 0xff;
  // header[8..9] = frame flags 0
  return new Uint8Array([...header, ...body]);
}

/** Prepend a fresh ID3v2.3 block with the TXXX provenance frames. */
function mp3PrependTags(path: string, tags: ProvenanceTags): TagWriteResult {
  const frames = Object.entries(tags).flatMap(([k, v]) => [...txxxFrame(k, v)]);
  const header = new Uint8Array([0x49, 0x44, 0x33, 3, 0, 0, ...syncSafe(frames.length)]);
  const original = readFileSync(path);
  writeFileSync(path, new Uint8Array([...header, ...frames, ...original]));
  return { written: true, issue: null };
}

/** Write provenance tags to one copied file. Never throws. */
export async function writeProvenance(path: string, tags: ProvenanceTags): Promise<TagWriteResult> {
  try {
    switch (ext(path)) {
      case "flac":
        return await metaflacSetTags(path, tags);
      case "mp3":
        return mp3PrependTags(path, tags);
      default:
        return { written: false, issue: `provenance_tags_skipped:${ext(path)}` };
    }
  } catch (e) {
    return { written: false, issue: `provenance_write_failed: ${String(e).slice(0, 120)}` };
  }
}
