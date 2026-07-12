// P3 lifecycle end-to-end (offline): propose -> approve -> execute -> gc,
// with journal, provenance tags, crash resume, and every guard rail.
// Tier roots, journal, and dj zone all live inside the temp corpus dir; the
// real library is never touched.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { audioHash } from "../src/audioHash.ts";
import { cmdScan, cmdStatus } from "../src/commands.ts";
import { cmdApprove, cmdExecute, cmdGc, cmdPropose } from "../src/commands-p3.ts";
import { readJournal } from "../src/journal.ts";
import { loadGenreMap } from "../src/rules.ts";
import { readSidecar, serializeSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};
const PCP = "[Psychill & Chillout & Psydub]";
const DTE = "[Downtempo & Electronica]";

let corpus: Corpus;
let library: string;
let journalPath: string;
let djZone: string;
let pristineIncome: string;

const dirOf = (...seg: string[]) => join(corpus.income, ...seg);
const sc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;

beforeAll(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  process.env.INTAKE_BEETS_SHIM = `bun ${join(import.meta.dir, "fakes", "fake-shim.ts")}`;
  delete process.env.FAKE_SHIM_MODE;

  library = join(corpus.dir, "library");
  journalPath = join(corpus.dir, "journal", "intake-journal.ndjson");
  djZone = join(corpus.dir, "dj");
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${journalPath}`,
      "gc:",
      `  dj_zone: ${djZone}`,
      `  dj_collections: ["${DTE}"]`,
      "",
    ].join("\n"),
  );
  await cmdScan([], { ...OPTS, all: true });
  pristineIncome = treeHash(corpus.income);
});

afterAll(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("propose --all-resolved: offline identify flags review, so nothing auto-proposes", async () => {
  const result = await cmdPropose([], { ...OPTS, allResolved: true });
  expect(result.errors).toEqual([]);
  const rows = result.data as { skipped?: string; status?: string }[];
  expect(rows.length).toBeGreaterThanOrEqual(8);
  expect(rows.every((r) => r.skipped === "needs_review")).toBe(true);
  expect((await cmdStatus([], { ...OPTS, filters: { status: "proposed" } })).data).toEqual([]);
});

test("explicit propose runs identify+assign and flips to proposed", async () => {
  const pollen = dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  const result = await cmdPropose([pollen], OPTS);
  expect(result.errors).toEqual([]);

  const doc = sc(pollen);
  expect(doc.status).toBe("proposed");
  expect(doc.identification?.status).toBe("unconfirmed");
  expect(doc.proposal?.target_path).toBe(
    `${library}/music.hq/${PCP}/Aes Dana/Aes Dana [2012] Pollen (Ultimae Records; inre042)`,
  );
  expect(doc.history.at(-1)?.event).toBe("proposed");
});

test("lifecycle guards: approve needs proposed, execute needs approved", async () => {
  const reflective = dirOf("slsk", "Solar Fields", "Solar Fields [2001] Reflective Frequencies");
  const approve = cmdApprove([reflective], OPTS);
  expect(approve.errors[0]?.code).toBe("E_BAD_STATUS");

  const pollen = dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  const exec = await cmdExecute([pollen], OPTS); // proposed, not yet approved
  expect(exec.errors[0]?.code).toBe("E_BAD_STATUS");
});

test("approve single + --batch file of ids", async () => {
  const pollen = dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  expect(cmdApprove([pollen], OPTS).errors).toEqual([]);
  expect(sc(pollen).status).toBe("approved");

  const reflective = dirOf("slsk", "Solar Fields", "Solar Fields [2001] Reflective Frequencies");
  const movements = dirOf("slsk", "Solar Fields", "Solar Fields - Movements (2009)");
  await cmdPropose([reflective, movements], OPTS);
  const batchFile = join(corpus.dir, "approve-batch.txt");
  writeFileSync(batchFile, `# batch\n${sc(reflective).id}\n${sc(movements).id}\n`);
  const result = cmdApprove([], { ...OPTS, batch: batchFile });
  expect(result.errors).toEqual([]);
  expect(sc(reflective).status).toBe("approved");
  expect(sc(movements).status).toBe("approved");
});

test("execute: copy, tag, verify, atomic place, journal, genre-map count", async () => {
  const pollen = dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  const before = loadGenreMap(corpus.rules).artists["Aes Dana"]![PCP]!;

  const result = await cmdExecute([pollen], OPTS);
  expect(result.errors).toEqual([]);

  const doc = sc(pollen);
  const target = doc.placed!.target_path;
  expect(doc.status).toBe("placed");
  expect(doc.placed!.verified).toBe(true);
  expect(doc.placed!.journal_seq).toBe(1);

  // Copies: 4 audio + cover artifact, hashes identical to sidecar (tag writes
  // did not touch audio), provenance tags present via metaflac.
  const placedFiles = readdirSync(target).sort();
  expect(placedFiles).toEqual([
    "01 - Iliona.flac", "02 - Signs.flac", "03 - Adonai.flac", "04 - Borderline.flac", "cover.jpg",
  ]);
  for (const f of doc.files) {
    expect((await audioHash(join(target, f.path))).hash).toBe(f.audio_hash);
  }
  const tagProc = Bun.spawnSync(["metaflac", "--export-tags-to=-", join(target, "01 - Iliona.flac")]);
  const tags = tagProc.stdout.toString();
  expect(tags).toContain("INTAKE_DATE=");
  expect(tags).toContain("INTAKE_SOURCE=web");
  expect(tags).toContain("INTAKE_BATCH=b");

  // No temp dir left behind; journal has the placed record; counts bumped.
  expect(readdirSync(join(target, "..")).filter((n) => n.startsWith(".intake-tmp"))).toEqual([]);
  const journal = readJournal(journalPath);
  expect(journal.length).toBe(1);
  expect(journal[0]).toMatchObject({
    seq: 1, event: "placed", sidecar_id: doc.id, target_path: target, cli_version: "0.1.0",
  });
  expect(journal[0]!.audio_hashes).toEqual(doc.files.map((f) => f.audio_hash));
  expect(loadGenreMap(corpus.rules).artists["Aes Dana"]![PCP]).toBe(before + 1);

  // Income originals untouched by execute (gc is the only deleter).
  expect(treeHash(corpus.income)).toBe(pristineIncome);
});

test("execute mp3 root: prepended ID3 provenance keeps mp3sha1 stable", async () => {
  const koan = dirOf("todo", "Koan-Condemned-(MKL033)-WEB-2016-KOAN");
  await cmdPropose([koan], OPTS);
  cmdApprove([koan], OPTS);
  const result = await cmdExecute([koan], OPTS);
  expect(result.errors).toEqual([]);

  const doc = sc(koan);
  const target = doc.placed!.target_path;
  for (const f of doc.files) {
    expect((await audioHash(join(target, f.path))).hash).toBe(f.audio_hash);
    // The copy grew by the prepended ID3v2 block (bytes differ, hash equal).
    const placed = readFileSync(join(target, f.path));
    expect(placed.length).toBeGreaterThan(readFileSync(join(koan, f.path)).length);
    expect(placed.subarray(0, 3).toString("latin1")).toBe("ID3");
  }
});

test("execute quality shadows: lossy duplicates stay local", async () => {
  const ott = dirOf("todo", "Ott - Blumenkraft (2003)");
  await cmdPropose([ott], OPTS);
  cmdApprove([ott], OPTS);
  const result = await cmdExecute([ott], OPTS);
  expect(result.errors).toEqual([]);
  const row = (result.data as { skipped_shadows: number }[])[0]!;
  expect(row.skipped_shadows).toBe(3);
  const target = sc(ott).placed!.target_path;
  expect(readdirSync(target).filter((n) => n.endsWith(".mp3"))).toEqual([]);
  expect(readdirSync(target).filter((n) => n.endsWith(".flac")).length).toBe(3);
});

test("execute virtual root places only the cluster's files", async () => {
  const mix = dirOf("slsk", "random_mix");
  const emantra = readdirSync(mix)
    .filter((n) => /^\.intake\..*\.json$/.test(n))
    .map((n) => readSidecar(join(mix, n))!)
    .find((s) => s.cluster.albumartist === "E-Mantra")!;
  await cmdPropose([emantra.id], OPTS);
  cmdApprove([emantra.id], OPTS);
  const result = await cmdExecute([emantra.id], OPTS);
  expect(result.errors).toEqual([]);

  const target = `${library}/music.hq/[Psytrance]/E-Mantra/E-Mantra [2010] Arcana`;
  expect(readdirSync(target).sort()).toEqual(["emantra_1_arcana.flac", "emantra_2_nocturne.flac"]);
  // Dump-dir neighbours untouched.
  expect(existsSync(join(mix, "koan_1_argonautica.mp3"))).toBe(true);
  expect(existsSync(join(mix, "emantra_1_arcana.flac"))).toBe(true);
});

test("execute refuses an existing target and stays approved", async () => {
  const sync24 = dirOf("downloads", "Sync24 [2024] Omnimotion Remixed");
  await cmdPropose([sync24], OPTS);
  cmdApprove([sync24], OPTS);
  const target = `${library}/music.uhq/${DTE}/Sync24/Sync24 [2024] Omnimotion Remixed`;
  mkdirSync(target, { recursive: true });
  const blocked = await cmdExecute([sync24], OPTS);
  expect(blocked.errors[0]?.code).toBe("E_TARGET_EXISTS");
  expect(sc(sync24).status).toBe("approved");

  rmSync(target, { recursive: true });
  const ok = await cmdExecute([sync24], OPTS);
  expect(ok.errors).toEqual([]);
  expect(sc(sync24).placed!.target_path).toBe(target); // uhq tier routing
});

test("execute --resume: completed placing finalizes, interrupted reverts", async () => {
  // Interrupted: approved root manually flipped to placing, no target.
  const asura = dirOf("todo", "Asura [2003] Lost Eden (Ultimae Records; inre010)");
  await cmdPropose([asura], OPTS);
  cmdApprove([asura], OPTS);
  let doc = sc(asura);
  doc.status = "placing";
  writeFileSync(join(asura, ".intake.json"), serializeSidecar(doc));
  const revert = await cmdExecute([], { ...OPTS, resume: true });
  expect((revert.data as { resumed: string }[])[0]!.resumed).toBe("reverted_to_approved");
  expect(sc(asura).status).toBe("approved");

  // Completed: placed root flipped back to placing; resume re-verifies + finalizes.
  await cmdExecute([asura], OPTS);
  doc = sc(asura);
  expect(doc.status).toBe("placed");
  const seq = doc.placed!.journal_seq;
  expect(existsSync(join(doc.placed!.target_path, "CD1", "01 - Lost Eden.flac"))).toBe(true); // disc layout preserved
  doc.status = "placing";
  writeFileSync(join(asura, ".intake.json"), serializeSidecar(doc));
  const complete = await cmdExecute([], { ...OPTS, resume: true });
  expect((complete.data as { resumed: string }[])[0]!.resumed).toBe("completed");
  const after = sc(asura);
  expect(after.status).toBe("placed");
  expect(after.placed!.journal_seq).toBe(seq); // no duplicate journal record
  expect(readJournal(journalPath).filter((r) => r.sidecar_id === after.id && r.event === "placed").length).toBe(1);
});

test("gc: journal re-verify then delete originals, tombstone sidecar", async () => {
  const pollen = dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
  const before = sc(pollen);
  const result = await cmdGc([pollen], OPTS);
  expect(result.errors).toEqual([]);

  expect(readdirSync(pollen)).toEqual([".intake.json"]); // audio + cover gone, tombstone stays
  const doc = sc(pollen);
  expect(doc.status).toBe("gc_done");
  expect(readJournal(journalPath).at(-1)).toMatchObject({
    event: "gc_done", sidecar_id: before.id, target_path: before.placed!.target_path,
  });
  // Placed copies untouched.
  expect(readdirSync(before.placed!.target_path).length).toBe(5);
});

test("gc --age skips young placements; tampered target refuses deletion", async () => {
  const koan = dirOf("todo", "Koan-Condemned-(MKL033)-WEB-2016-KOAN");
  const aged = await cmdGc([koan], { ...OPTS, age: 30 });
  expect((aged.data as { skipped: string }[])[0]!.skipped).toBe("too_young");
  expect(sc(koan).status).toBe("placed");

  const ott = dirOf("todo", "Ott - Blumenkraft (2003)");
  const target = sc(ott).placed!.target_path;
  const victim = join(target, "01 - Jack's Cheese and Bread Snack.flac");
  const original = readFileSync(victim);
  writeFileSync(victim, new Uint8Array([1, 2, 3, 4]));
  const tampered = await cmdGc([ott], OPTS);
  expect(tampered.errors[0]?.code).toBe("E_VERIFY");
  expect(sc(ott).status).toBe("placed");
  expect(existsSync(join(ott, "01 - Jack's Cheese and Bread Snack.flac"))).toBe(true); // nothing deleted
  writeFileSync(victim, original);
});

test("gc --relocate-dj moves originals into the dj zone for mirrored collections", async () => {
  const sync24 = dirOf("downloads", "Sync24 [2024] Omnimotion Remixed");
  const result = await cmdGc([sync24], { ...OPTS, relocateDj: true });
  expect(result.errors).toEqual([]);
  const row = (result.data as { action: string; dj_dest: string }[])[0]!;
  expect(row.action).toBe("relocate_dj");
  expect(readdirSync(row.dj_dest).length).toBe(3); // the three flacs moved
  expect(sc(sync24).status).toBe("gc_done");
  expect(readJournal(journalPath).at(-1)?.event).toBe("gc_relocated");
});

test("status --json surfaces placed and the full lifecycle mix", async () => {
  const rows = (await cmdStatus([], OPTS)).data as {
    status: string;
    placed: { verified: boolean; target_path: string } | null;
  }[];
  const byStatus = new Map<string, number>();
  for (const r of rows) byStatus.set(r.status, (byStatus.get(r.status) ?? 0) + 1);
  expect(byStatus.get("gc_done")).toBe(2); // Pollen + Sync24
  expect(byStatus.get("placed")).toBeGreaterThanOrEqual(4);
  for (const r of rows.filter((x) => x.status === "placed")) {
    expect(r.placed?.verified).toBe(true);
    expect(r.placed?.target_path.startsWith(library)).toBe(true);
  }
});

test("execute without journal config fails with E_NO_JOURNAL", async () => {
  const bare = join(corpus.dir, "bare-rules");
  mkdirSync(bare, { recursive: true });
  writeFileSync(join(bare, "structure.yaml"), "resolver: {}\n");
  const prev = process.env.INTAKE_RULES_DIR;
  process.env.INTAKE_RULES_DIR = bare;
  try {
    const result = await cmdExecute(["whatever"], OPTS);
    expect(result.errors[0]?.code).toBe("E_NO_JOURNAL");
    expect(result.exitCode).toBe(2);
  } finally {
    process.env.INTAKE_RULES_DIR = prev;
  }
});
