// `propose --dry-run` used to be a no-op preview: it delegated identify and
// assign, which write nothing under --dry-run, then re-read the sidecar from
// disk — so it saw the unchanged file and reported "no assignment evidence".
// It now drives both stages on the RootRef it holds, so the preview is real
// while the disk stays untouched.
//
// Also covers provider injection: these run with no DISCOGS_TOKEN or
// LASTFM_API_KEY and an explicitly injected shim, i.e. nothing below the
// command layer reads the environment.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { cmdPropose } from "../src/commands-p3.ts";
import type { P2Deps } from "../src/commands-p2.ts";
import type { Providers } from "../src/providers.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};

// Offline everything: no network providers, and a shim that finds nothing —
// identification falls back to tags/parse, which is enough to assign.
const OFFLINE: P2Deps = {
  providers: {
    discogs: null,
    similar: null,
    shim: { identify: async () => ({ candidates: [] }) },
  } as Providers,
};

let corpus: Corpus;
let release: string;
let sidecarPath: string;

const onDisk = (): Sidecar => readSidecar(sidecarPath)!;

beforeAll(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  delete process.env.INTAKE_BEETS_SHIM;

  release = join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  sidecarPath = join(release, ".intake.json");
  expect((await cmdResolve([release], OPTS)).errors).toEqual([]);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("propose --dry-run previews the target and writes nothing", async () => {
  const before = readFileSync(sidecarPath, "utf8");
  const incomeBefore = treeHash(corpus.income);

  const result = await cmdPropose([release], { ...OPTS, dryRun: true }, OFFLINE);
  expect(result.errors).toEqual([]);
  const row = (result.data as { status: string; target_path: string; confidence: number }[])[0]!;
  expect(row.status).toBe("proposed");
  expect(row.target_path).toContain("Aes Dana");
  expect(row.confidence).toBeGreaterThan(0);

  // The preview left no trace: sidecar byte-identical, no audio touched.
  expect(readFileSync(sidecarPath, "utf8")).toBe(before);
  expect(onDisk().status).toBe("resolved");
  expect(onDisk().proposal).toBeNull();
  expect(onDisk().identification).toBeNull();
  expect(treeHash(corpus.income)).toBe(incomeBefore);
});

test("the real run lands on the target the preview showed", async () => {
  const preview = (
    (await cmdPropose([release], { ...OPTS, dryRun: true }, OFFLINE)).data as { target_path: string }[]
  )[0]!;

  const result = await cmdPropose([release], OPTS, OFFLINE);
  expect(result.errors).toEqual([]);
  expect((result.data as { target_path: string }[])[0]!.target_path).toBe(preview.target_path);

  const doc = onDisk();
  expect(doc.status).toBe("proposed");
  expect(doc.proposal?.target_path).toBe(preview.target_path);
  expect(doc.identification).not.toBeNull();
  expect(doc.history.map((h) => h.event)).toContain("identified");
});
