// Intake journal (doc 03): append-only NDJSON, one record per line. The
// journal is the authority for "is it in the library"; sidecars are working
// copies. Location comes from structure.yaml `journal.path` (the real path on
// Amunet is pending confirmation; tests point it into a temp dir).

import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, statSync } from "node:fs";
import { dirname } from "node:path";
import type { JournalRecord } from "./types.ts";

/**
 * Parsed-journal cache, keyed by path and validated against (size, mtimeMs).
 * A batch `execute --approved` or `gc` calls nextSeq/findRecord once per root,
 * which re-read and re-parsed the whole journal every time; the journal only
 * grows, so that was quadratic in placements. An external append invalidates
 * the entry via size/mtime, so a stale read is not possible within a process.
 */
interface CacheEntry {
  records: JournalRecord[];
  size: number;
  mtimeMs: number;
}
const cache = new Map<string, CacheEntry>();

function parseJournal(text: string): JournalRecord[] {
  const out: JournalRecord[] = [];
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const doc = JSON.parse(trimmed);
      if (typeof doc === "object" && doc !== null && typeof doc.seq === "number") out.push(doc as JournalRecord);
    } catch {
      // tolerate a torn final line (crash mid-append); it is rewritten by seq
    }
  }
  return out;
}

/** Cached records — callers must treat the array as read-only. */
function records(path: string): JournalRecord[] {
  if (!existsSync(path)) {
    cache.delete(path);
    return [];
  }
  const st = statSync(path);
  const hit = cache.get(path);
  if (hit && hit.size === st.size && hit.mtimeMs === st.mtimeMs) return hit.records;
  const parsed = parseJournal(readFileSync(path, "utf8"));
  cache.set(path, { records: parsed, size: st.size, mtimeMs: st.mtimeMs });
  return parsed;
}

export function readJournal(path: string): JournalRecord[] {
  return records(path).slice(); // copy: callers may sort/mutate
}

export function nextSeq(path: string): number {
  let max = 0;
  for (const r of records(path)) if (r.seq > max) max = r.seq;
  return max + 1;
}

/**
 * True if the file is empty or its last byte is a newline. A crash mid-append
 * can leave a torn final line with no terminator; appending straight onto it
 * would glue the next record to the garbage and lose it (readers skip the
 * unparseable line). Reads one byte, not the file.
 */
function endsWithNewline(path: string): boolean {
  const size = statSync(path).size;
  if (size === 0) return true;
  const fd = openSync(path, "r");
  try {
    const buf = new Uint8Array(1);
    readSync(fd, buf, 0, 1, size - 1);
    return buf[0] === 0x0a;
  } finally {
    closeSync(fd);
  }
}

export function appendJournal(path: string, record: JournalRecord): void {
  mkdirSync(dirname(path), { recursive: true });
  const before = cache.get(path);
  const prefix = existsSync(path) && !endsWithNewline(path) ? "\n" : "";
  appendFileSync(path, prefix + JSON.stringify(record) + "\n");
  // Extend the cache in place rather than dropping it, so the next read after
  // an append stays O(1) instead of re-parsing the whole file.
  if (before) {
    try {
      const st = statSync(path);
      cache.set(path, { records: [...before.records, record], size: st.size, mtimeMs: st.mtimeMs });
    } catch {
      cache.delete(path);
    }
  }
}

export function findRecord(path: string, seq: number): JournalRecord | null {
  return records(path).find((r) => r.seq === seq) ?? null;
}

export function findPlacedRecord(path: string, sidecarId: string): JournalRecord | null {
  let found: JournalRecord | null = null;
  for (const r of records(path)) if (r.sidecar_id === sidecarId && r.event === "placed") found = r;
  return found;
}
