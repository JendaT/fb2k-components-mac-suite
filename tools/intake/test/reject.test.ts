// `intake reject` per doc 03 v1.1 "reject semantics": legal from new /
// resolved / proposed / approved, refused with E_BAD_STATUS from placing /
// placed / gc_done and from rejected itself (terminal). A state change only:
// the sidecar is the one file that changes — no tags, audio, journal, rules or
// library writes, nothing deleted — and no other command picks a rejected root
// back up. `resolve --force` is the specced re-entry.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve, cmdScan, cmdStatus } from "../src/commands.ts";
import { rootsFromRefs } from "../src/commands-p2.ts";
import { cmdApprove, cmdExecute, cmdGc, cmdPropose, cmdReject } from "../src/commands-p3.ts";
import { readSidecar, serializeSidecar } from "../src/sidecar.ts";
import type { Sidecar, Status } from "../src/types.ts";
import { setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, all: false,
  allResolved: false, batch: null, reason: null, approved: false, resume: false,
  age: null, relocateDj: false,
};

let corpus: Corpus;
let library: string;
let journalPath: string;

const dirOf = (...seg: string[]) => join(corpus.income, ...seg);
const REFLECTIVE = () => dirOf("slsk", "Solar Fields", "Solar Fields [2001] Reflective Frequencies");
const MOVEMENTS = () => dirOf("slsk", "Solar Fields", "Solar Fields - Movements (2009)");
const POLLEN = () => dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
const KOAN = () => dirOf("todo", "Koan-Condemned-(MKL033)-WEB-2016-KOAN");
const BLUETECH = () => dirOf("todo", "Bluetech [2011] Cosmic Dubwise");
const OTT = () => dirOf("todo", "Ott - Blumenkraft (2003)");

/** The one sidecar a ref names (path of a non-virtual root, or an id). */
function sidecarPathOf(ref: string): string {
  const roots = rootsFromRefs([ref], []);
  expect(roots.length).toBe(1);
  return roots[0]!.sidecarPath;
}
const raw = (ref: string) => readFileSync(sidecarPathOf(ref), "utf8");
const doc = (ref: string): Sidecar => readSidecar(sidecarPathOf(ref))!;

function forceStatus(ref: string, status: Status): void {
  const s = doc(ref);
  s.status = status;
  writeFileSync(sidecarPathOf(ref), serializeSidecar(s));
}

/** Everything reject must leave alone: audio/tags, rules, journal, library. */
function world(): Record<string, string | null> {
  return {
    income: treeHash(corpus.income), // excludes sidecars, covers every audio byte (tags included)
    rules: treeHash(corpus.rules),
    journal: existsSync(journalPath) ? readFileSync(journalPath, "utf8") : null,
    library: existsSync(library) ? treeHash(library) : null,
  };
}

/** Reject one ref and assert the sidecar is the only thing that changed. */
function rejectAndCheck(ref: string, rootDir: string, reason: string | null): void {
  const before = doc(ref);
  const rootBefore = treeHash(rootDir);
  const worldBefore = world();

  const result = cmdReject([ref], { ...OPTS, reason });
  expect(result.errors).toEqual([]);
  expect(result.exitCode).toBe(0);
  expect(result.data).toEqual([{ id: before.id, root_path: rootDir, status: "rejected" }]);

  const after = doc(ref);
  expect(after.status).toBe("rejected");
  expect(after.history.length).toBe(before.history.length + 1);
  const entry = after.history.at(-1)!;
  expect(entry.event).toBe("rejected");
  expect(entry.by).toMatch(/^intake@/);
  if (reason === null) expect("reason" in entry).toBe(false);
  else expect(entry.reason).toBe(reason);
  // Nothing else in the sidecar moved.
  expect({ ...after, status: before.status, history: after.history.slice(0, -1) }).toEqual(before);

  expect(treeHash(rootDir)).toBe(rootBefore);
  expect(world()).toEqual(worldBefore);
}

beforeAll(async () => {
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
      "gc:",
      `  dj_zone: ${join(corpus.dir, "dj")}`,
      "  dj_collections: []",
      "",
    ].join("\n"),
  );
  await cmdScan([], { ...OPTS, all: true });
});

afterAll(() => {
  delete process.env.INTAKE_BEETS_SHIM;
  rmSync(corpus.dir, { recursive: true, force: true });
});

// ---- legal sources -----------------------------------------------------------

test("reject from new (by id, with reason)", async () => {
  const rows = (await cmdStatus([], { ...OPTS, filters: { status: "new" } })).data!;
  expect(rows.length).toBe(1); // the iso stub, a virtual root in the dump dir
  rejectAndCheck(rows[0]!.id, rows[0]!.root_path, "iso, not worth unpacking");
});

test("reject from resolved (by path, no reason)", () => {
  expect(doc(REFLECTIVE()).status).toBe("resolved");
  rejectAndCheck(REFLECTIVE(), REFLECTIVE(), null);
});

test("reject from proposed", async () => {
  expect((await cmdPropose([POLLEN()], OPTS)).errors).toEqual([]);
  expect(doc(POLLEN()).status).toBe("proposed");
  rejectAndCheck(POLLEN(), POLLEN(), "duplicate of a better rip");
});

test("reject from approved", async () => {
  expect((await cmdPropose([KOAN()], OPTS)).errors).toEqual([]);
  expect(cmdApprove([KOAN()], OPTS).errors).toEqual([]);
  expect(doc(KOAN()).status).toBe("approved");
  rejectAndCheck(KOAN(), KOAN(), "wrong edition");
});

// ---- refused sources ---------------------------------------------------------

for (const status of ["placing", "placed", "gc_done"] as const) {
  test(`reject from ${status} is refused with E_BAD_STATUS and writes nothing`, () => {
    forceStatus(MOVEMENTS(), status);
    const before = raw(MOVEMENTS());
    const result = cmdReject([MOVEMENTS()], { ...OPTS, reason: "too late" });
    expect(result.exitCode).toBe(2);
    expect(result.data).toBeNull();
    expect(result.errors).toEqual([
      { code: "E_BAD_STATUS", msg: `cannot reject from status ${status}`, path: MOVEMENTS() },
    ]);
    expect(raw(MOVEMENTS())).toBe(before);
  });
}

test("reject from rejected is refused: terminal", () => {
  expect(doc(REFLECTIVE()).status).toBe("rejected");
  const before = raw(REFLECTIVE());
  const result = cmdReject([REFLECTIVE()], { ...OPTS, reason: "again" });
  expect(result.exitCode).toBe(2);
  expect(result.errors.map((e) => e.code)).toEqual(["E_BAD_STATUS"]);
  expect(raw(REFLECTIVE())).toBe(before);
});

// ---- batch / dry-run / partial -----------------------------------------------

test("--batch: ids and paths, comments skipped, a root named twice rejected once", () => {
  const mix = dirOf("slsk", "random_mix");
  const virtuals = rootsFromRefs([mix], []);
  expect(virtuals.length).toBeGreaterThan(1);
  const target = virtuals[0]!;
  const siblings = virtuals.slice(1).map((v) => [v.sidecarPath, readFileSync(v.sidecarPath, "utf8")] as const);
  const bluetechId = doc(BLUETECH()).id;

  const batchFile = join(corpus.dir, "reject-batch.txt");
  writeFileSync(batchFile, `# rejects\n\n${target.sidecar.id}\n${BLUETECH()}\n${bluetechId}\n`);
  const worldBefore = world();
  const result = cmdReject([], { ...OPTS, batch: batchFile, reason: "batch" });
  expect(result.errors).toEqual([]);
  expect(result.data).toEqual([
    { id: target.sidecar.id, root_path: mix, status: "rejected" },
    { id: bluetechId, root_path: BLUETECH(), status: "rejected" },
  ]);
  expect(doc(target.sidecar.id).status).toBe("rejected");
  expect(doc(BLUETECH()).history.filter((h) => h.event === "rejected")).toHaveLength(1);
  // A virtual root shares its dir: only its own sidecar file changed.
  for (const [path, text] of siblings) expect(readFileSync(path, "utf8")).toBe(text);
  expect(world()).toEqual(worldBefore);

  const missing = cmdReject([], { ...OPTS, batch: join(corpus.dir, "nope.txt") });
  expect(missing.exitCode).toBe(2);
  expect(missing.errors[0]?.code).toBe("E_NOT_FOUND");
  const empty = cmdReject([], OPTS);
  expect(empty.exitCode).toBe(2);
  expect(empty.errors[0]?.code).toBe("E_BAD_ARGS");
});

test("--dry-run reports the flip and writes nothing", () => {
  const before = raw(OTT());
  const result = cmdReject([OTT()], { ...OPTS, dryRun: true, reason: "maybe" });
  expect(result.exitCode).toBe(0);
  expect(result.data).toEqual([{ id: doc(OTT()).id, root_path: OTT(), status: "rejected", dry_run: true }]);
  expect(raw(OTT())).toBe(before);
  expect(doc(OTT()).status).toBe("resolved");
});

test("mixed refs: exit 1 partial with the rejected subset (CLI envelope)", () => {
  const ottId = doc(OTT()).id;
  forceStatus(MOVEMENTS(), "placed");
  const proc = Bun.spawnSync(
    [process.execPath, "run", CLI, "reject", ottId, MOVEMENTS(), "--reason", "two-word reason", "--json"],
    { env: { ...process.env, INTAKE_RULES_DIR: corpus.rules } },
  );
  expect(proc.exitCode).toBe(1);
  const env = JSON.parse(proc.stdout.toString());
  expect(env.ok).toBe(false);
  expect(env.data).toEqual([{ id: ottId, root_path: OTT(), status: "rejected" }]);
  expect(env.errors.map((e: { code: string; path: string }) => [e.code, e.path])).toEqual([["E_BAD_STATUS", MOVEMENTS()]]);
  expect(doc(OTT()).history.at(-1)).toMatchObject({ event: "rejected", reason: "two-word reason" });
  expect(doc(MOVEMENTS()).status).toBe("placed");
});

// ---- inventory and terminality ------------------------------------------------

test("status keeps rejected roots in the default inventory", async () => {
  const all = (await cmdStatus([], OPTS)).data!;
  expect(all.length).toBe(22); // nothing dropped from the full fixture inventory
  const rejected = all.filter((r) => r.status === "rejected").map((r) => r.root_path);
  expect(rejected).toEqual(expect.arrayContaining([REFLECTIVE(), POLLEN(), KOAN(), BLUETECH(), OTT()]));
  const filtered = (await cmdStatus([], { ...OPTS, filters: { status: "rejected" } })).data!;
  expect(filtered.length).toBe(rejected.length);
  expect(filtered.length).toBe(7); // iso stub, Reflective, Pollen, Koan, mix cluster, Bluetech, Ott
});

test("no other command picks a rejected root back up", async () => {
  // Koan was approved (it carries a target path), Reflective was resolved.
  const watched = [KOAN(), REFLECTIVE(), POLLEN()];
  const before = new Map(watched.map((r) => [r, raw(r)]));
  const ids = new Set(watched.map((r) => doc(r).id));
  const touches = (rows: unknown) => ((rows ?? []) as { id: string }[]).some((r) => ids.has(r.id));

  const propose = await cmdPropose([REFLECTIVE()], OPTS);
  expect(propose.errors.map((e) => e.code)).toEqual(["E_BAD_STATUS"]);
  expect(touches((await cmdPropose([], { ...OPTS, allResolved: true })).data)).toBe(false);

  expect(cmdApprove([KOAN()], OPTS).errors.map((e) => e.code)).toEqual(["E_BAD_STATUS"]);

  const exec = await cmdExecute([KOAN()], OPTS);
  expect(exec.errors.map((e) => e.code)).toEqual(["E_BAD_STATUS"]);
  expect(touches((await cmdExecute([], { ...OPTS, approved: true })).data)).toBe(false);
  expect(touches((await cmdExecute([], { ...OPTS, resume: true })).data)).toBe(false);
  expect(existsSync(doc(KOAN()).proposal!.target_path!)).toBe(false);

  // gc touches only placed roots: a rejected root is not eligible, named or not.
  expect(touches((await cmdGc([], OPTS)).data)).toBe(false);
  const gcNamed = await cmdGc([KOAN()], OPTS);
  expect(gcNamed.data).toEqual([]);
  expect(existsSync(join(KOAN(), doc(KOAN()).files[0]!.path))).toBe(true);

  // Re-scan / re-resolve without --force keep the existing sidecar.
  const scan = await cmdScan([], { ...OPTS, all: true });
  expect(scan.data!.flatMap((b) => b.kept)).toEqual(expect.arrayContaining([KOAN(), REFLECTIVE(), POLLEN()]));
  expect(touches(scan.data!.flatMap((b) => b.written))).toBe(false);
  const resolve = await cmdResolve([REFLECTIVE()], OPTS);
  expect(resolve.data!.kept).toEqual([REFLECTIVE()]);
  expect(resolve.data!.written).toEqual([]);

  for (const r of watched) expect(raw(r)).toBe(before.get(r)!);
});

test("resolve --force is the re-entry: rebuilds the sidecar, history kept", async () => {
  const id = doc(REFLECTIVE()).id;
  const result = await cmdResolve([REFLECTIVE()], { ...OPTS, force: true });
  expect(result.errors).toEqual([]);
  const after = doc(REFLECTIVE());
  expect(after.id).toBe(id);
  expect(after.status).toBe("resolved");
  expect(after.history.map((h) => h.event)).toEqual(["resolved", "rejected", "re-resolved"]);
});
