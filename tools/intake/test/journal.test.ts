// Journal reads are cached per path and validated against (size, mtimeMs),
// so a batch execute/gc does not re-parse the whole file per root. These cover
// the invalidation paths — including writes this process did not make.

import { expect, test } from "bun:test";
import { appendFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendJournal, findPlacedRecord, findRecord, nextSeq, readJournal } from "../src/journal.ts";
import type { JournalRecord } from "../src/types.ts";

function rec(seq: number, extra: Partial<JournalRecord> = {}): JournalRecord {
  return {
    seq, ts: "2026-07-25T12:00:00+02:00", event: "placed", sidecar_id: `itk_${seq}`,
    audio_hashes: [`fsha1:${seq}`], target_path: `/library/x/${seq}`, cli_version: "0.1.0",
    ...extra,
  };
}

/** What a process with a cold cache would parse out of the file. */
function onDiskSeqs(path: string): number[] {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((l) => l.trim())
    .flatMap((l) => {
      try {
        return [(JSON.parse(l) as { seq: number }).seq];
      } catch {
        return [];
      }
    });
}

function tmpJournal(): string {
  return join(mkdtempSync(join(tmpdir(), "intake-journal-")), "intake-journal.ndjson");
}

test("missing journal reads empty and starts at seq 1", () => {
  const path = tmpJournal();
  expect(readJournal(path)).toEqual([]);
  expect(nextSeq(path)).toBe(1);
});

test("appends are visible immediately, including through the cache", () => {
  const path = tmpJournal();
  appendJournal(path, rec(1));
  expect(nextSeq(path)).toBe(2);
  appendJournal(path, rec(2, { event: "gc_done" }));
  expect(readJournal(path).map((r) => r.seq)).toEqual([1, 2]);
  expect(nextSeq(path)).toBe(3);
  expect(findRecord(path, 2)?.event).toBe("gc_done");
  expect(findRecord(path, 99)).toBeNull();
});

test("a write from outside this process invalidates the cache", () => {
  const path = tmpJournal();
  appendJournal(path, rec(1));
  expect(nextSeq(path)).toBe(2); // populates the cache

  // Another intake process (or a hand edit) appends.
  appendFileSync(path, JSON.stringify(rec(7)) + "\n");
  expect(nextSeq(path)).toBe(8);
  expect(readJournal(path).map((r) => r.seq)).toEqual([1, 7]);

  // ...and a full rewrite of different length, e.g. a restored backup.
  writeFileSync(path, JSON.stringify(rec(3)) + "\n");
  expect(readJournal(path).map((r) => r.seq)).toEqual([3]);

  // ...and removal.
  rmSync(path);
  expect(readJournal(path)).toEqual([]);
  expect(nextSeq(path)).toBe(1);
});

test("findPlacedRecord returns the latest placed record for an id", () => {
  const path = tmpJournal();
  appendJournal(path, rec(1, { sidecar_id: "itk_a" }));
  appendJournal(path, rec(2, { sidecar_id: "itk_b" }));
  appendJournal(path, rec(3, { sidecar_id: "itk_a", target_path: "/library/x/replaced" }));
  appendJournal(path, rec(4, { sidecar_id: "itk_a", event: "gc_done" }));
  expect(findPlacedRecord(path, "itk_a")?.target_path).toBe("/library/x/replaced");
  expect(findPlacedRecord(path, "itk_c")).toBeNull();
});

test("a torn final line is tolerated, and the next append is not glued to it", () => {
  const path = tmpJournal();
  appendJournal(path, rec(1));
  appendFileSync(path, '{"seq":2,"event":"pla'); // crash mid-append, no newline
  expect(readJournal(path).map((r) => r.seq)).toEqual([1]);
  expect(nextSeq(path)).toBe(2); // the torn record never counted

  appendJournal(path, rec(2));
  expect(readJournal(path).map((r) => r.seq)).toEqual([1, 2]);
  // What the cache reports must be what a cold reader would parse: without the
  // newline repair, record 2 lands on the torn line and is silently lost.
  expect(onDiskSeqs(path)).toEqual([1, 2]);
});

test("callers cannot mutate the cached records", () => {
  const path = tmpJournal();
  appendJournal(path, rec(1));
  readJournal(path).push(rec(50));
  expect(readJournal(path).map((r) => r.seq)).toEqual([1]);
  expect(nextSeq(path)).toBe(2);
});
