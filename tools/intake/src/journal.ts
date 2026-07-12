// Intake journal (doc 03): append-only NDJSON, one record per line. The
// journal is the authority for "is it in the library"; sidecars are working
// copies. Location comes from structure.yaml `journal.path` (the real path on
// Amunet is pending confirmation; tests point it into a temp dir).

import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname } from "node:path";
import type { JournalRecord } from "./types.ts";

export function readJournal(path: string): JournalRecord[] {
  if (!existsSync(path)) return [];
  const out: JournalRecord[] = [];
  for (const line of readFileSync(path, "utf8").split("\n")) {
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

export function nextSeq(path: string): number {
  const records = readJournal(path);
  return records.length === 0 ? 1 : Math.max(...records.map((r) => r.seq)) + 1;
}

export function appendJournal(path: string, record: JournalRecord): void {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(record) + "\n");
}

export function findRecord(path: string, seq: number): JournalRecord | null {
  return readJournal(path).find((r) => r.seq === seq) ?? null;
}

export function findPlacedRecord(path: string, sidecarId: string): JournalRecord | null {
  const records = readJournal(path).filter((r) => r.sidecar_id === sidecarId && r.event === "placed");
  return records.at(-1) ?? null;
}
