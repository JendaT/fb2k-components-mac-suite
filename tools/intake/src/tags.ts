import { parseFile } from "music-metadata";
import { basename } from "node:path";
import type { TagSnapshot } from "./types.ts";
import { LOSSLESS_EXTS, ext } from "./util.ts";

export interface AudioSnapshot {
  codec: string; // normalized short codec name
  lossless: boolean;
  sample_rate: number | null;
  bit_depth: number | null;
  bitrate: number | null; // kbps, lossy only
  duration: number | null;
  tags: TagSnapshot;
}

function normCodec(fileExt: string, codec: string | undefined): { codec: string; lossless: boolean } {
  const c = (codec ?? "").toLowerCase();
  if (c.includes("alac")) return { codec: "alac", lossless: true };
  if (c.includes("aac")) return { codec: "aac", lossless: false };
  if (fileExt === "aif") return { codec: "aiff", lossless: true };
  return { codec: fileExt, lossless: LOSSLESS_EXTS.has(fileExt) };
}

/** Filename fallback: `NN - Title`, `NN. Title`, `NN_Title`, `Artist - Title`. */
export function parseFilename(name: string): { tracknumber: number | null; artist: string | null; title: string | null } {
  const stem = name.replace(/\.[^.]+$/, "");
  let m = stem.match(/^(\d{1,3})\s*(?:[-._])\s*(.+)$/);
  if (m) {
    const rest = m[2]!;
    const at = rest.match(/^(.+?)\s+-\s+(.+)$/);
    return {
      tracknumber: parseInt(m[1]!, 10),
      artist: at ? at[1]! : null,
      title: at ? at[2]! : rest,
    };
  }
  m = stem.match(/^(.+?)\s+-\s+(.+)$/);
  if (m) return { tracknumber: null, artist: m[1]!, title: m[2]! };
  return { tracknumber: null, artist: null, title: stem };
}

/** Read tag + format snapshot for one audio file. Never throws; degraded snapshot on parse failure. */
export async function readSnapshot(path: string): Promise<AudioSnapshot> {
  const fileExt = ext(basename(path));
  const empty: TagSnapshot = {
    albumartist: null, artist: null, album: null, title: null,
    tracknumber: null, disc: null, date: null,
  };
  try {
    const mm = await parseFile(path, { duration: true, skipCovers: true });
    const { codec, lossless } = normCodec(fileExt, mm.format.codec);
    const c = mm.common;
    const date = c.date ?? (c.year != null ? String(c.year) : null);
    return {
      codec,
      lossless,
      sample_rate: mm.format.sampleRate ?? null,
      bit_depth: mm.format.bitsPerSample ?? null,
      bitrate: !lossless && mm.format.bitrate ? Math.round(mm.format.bitrate / 1000) : null,
      duration: mm.format.duration != null ? Math.round(mm.format.duration * 10) / 10 : null,
      tags: {
        albumartist: c.albumartist ?? null,
        artist: c.artist ?? null,
        album: c.album ?? null,
        title: c.title ?? null,
        tracknumber: c.track?.no ?? null,
        disc: c.disk?.no ?? null,
        date: date ?? null,
      },
    };
  } catch {
    return {
      codec: fileExt,
      lossless: LOSSLESS_EXTS.has(fileExt),
      sample_rate: null,
      bit_depth: null,
      bitrate: null,
      duration: null,
      tags: empty,
    };
  }
}
