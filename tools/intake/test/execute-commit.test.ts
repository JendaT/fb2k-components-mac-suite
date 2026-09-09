// The rename in execute step 4 is the commit point. Anything that fails after
// it (journal append, genre-map write, sidecar flip) must leave the release in
// the library and the sidecar in `placing`, so `--resume` can finish the
// bookkeeping. Reverting to `approved` would strand it: the files are there, so
// every retry dies on E_TARGET_EXISTS.
//
// The failure is induced by pointing journal.path at a directory that cannot be
// created (its parent is a regular file), which throws inside appendJournal.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdPropose } from "../src/commands-p3.ts";
import { readJournal } from "../src/journal.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};

let corpus: Corpus;
let library: string;
let release: string;
let goodJournal: string;

const sc = (): Sidecar => readSidecar(join(release, ".intake.json"))!;

function writeStructure(journalPath: string): void {
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
}

beforeAll(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  process.env.INTAKE_BEETS_SHIM = `bun ${join(import.meta.dir, "fakes", "fake-shim.ts")}`;

  library = join(corpus.dir, "library");
  goodJournal = join(corpus.dir, "journal", "intake-journal.ndjson");

  // A regular file where the journal's parent directory should be: mkdirSync
  // inside appendJournal throws ENOTDIR, i.e. after the release is placed.
  const blocker = join(corpus.dir, "blocker");
  writeFileSync(blocker, "not a directory\n");
  writeStructure(join(blocker, "nested", "intake-journal.ndjson"));

  release = join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  expect((await cmdResolve([release], OPTS)).errors).toEqual([]);
  expect((await cmdPropose([release], OPTS)).errors).toEqual([]);
  expect(cmdApprove([release], OPTS).errors).toEqual([]);
});

afterAll(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("a failure after the commit point keeps the release and stays resumable", async () => {
  const target = sc().proposal!.target_path!;
  const result = await cmdExecute([release], OPTS);

  expect(result.errors.length).toBe(1);
  expect(result.errors[0]!.code).toBe("E_VERIFY");
  expect(result.errors[0]!.msg).toContain("--resume");

  // The library copy survived, complete.
  expect(existsSync(target)).toBe(true);
  expect(readdirSync(target).filter((n) => n.endsWith(".flac")).length).toBe(4);
  // No temp dir left behind under the same parent.
  expect(readdirSync(join(target, "..")).some((n) => n.startsWith(".intake-tmp-"))).toBe(false);

  // Not reverted to approved — that is what would strand it on E_TARGET_EXISTS.
  expect(sc().status).toBe("placing");
  expect(sc().placed).toBeUndefined();
});

test("--resume completes the bookkeeping once the journal is reachable again", async () => {
  writeStructure(goodJournal);
  const result = await cmdExecute([release], { ...OPTS, resume: true });
  expect(result.errors).toEqual([]);
  expect((result.data as { resumed: string }[])[0]!.resumed).toBe("completed");

  const doc = sc();
  expect(doc.status).toBe("placed");
  expect(doc.placed?.verified).toBe(true);
  const records = readJournal(goodJournal).filter((r) => r.sidecar_id === doc.id && r.event === "placed");
  expect(records.length).toBe(1);
  expect(records[0]!.target_path).toBe(doc.placed!.target_path);
  expect(doc.placed!.journal_seq).toBe(records[0]!.seq);
});
