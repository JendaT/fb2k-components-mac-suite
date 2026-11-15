// Doc 03 v1.2 "Legal source statuses (normative)" for identify, assign,
// resolve --force, scan --force and gc. A root in a status that is not legal
// for the command gets E_BAD_STATUS in errors[] and its sidecar is not
// touched; the other roots proceed (exit 1 if some succeeded, 2 if none did).
// The all-roots form of gc selects `placed` roots and skips the rest silently.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve, cmdScan } from "../src/commands.ts";
import { cmdAssign, cmdIdentify, rootsFromRefs } from "../src/commands-p2.ts";
import { cmdApprove, cmdExecute, cmdGc, cmdPropose } from "../src/commands-p3.ts";
import type { Providers } from "../src/providers.ts";
import { readSidecar, serializeSidecar } from "../src/sidecar.ts";
import type { Sidecar, Status } from "../src/types.ts";
import { isSidecarName } from "../src/util.ts";
import { setupCorpus, treeHash, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, all: false,
  collection: null, by: null, allResolved: false, batch: null, reason: null,
  approved: false, resume: false, age: null, relocateDj: false,
};
/** The all-roots form of gc (`--all`; a no-arg call before CR-004.14). */
const ALL = { ...OPTS, all: true };
const OFFLINE: { providers: Providers } = { providers: { discogs: null, similar: null, shim: null } };
const REFUSED = ["rejected", "placing", "placed", "gc_done"] as const;
const NO_REBUILD = ["placing", "placed", "gc_done"] as const;

let corpus: Corpus;
let library: string;

const dirOf = (...seg: string[]) => join(corpus.income, ...seg);
const SOLAR = () => dirOf("slsk", "Solar Fields");
const MOVEMENTS = () => join(SOLAR(), "Solar Fields - Movements (2009)");
const REFLECTIVE = () => join(SOLAR(), "Solar Fields [2001] Reflective Frequencies");
const LEAVING = () => join(SOLAR(), "Solar Fields [2005] Leaving Home");
const POLLEN = () => dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
const MIX = () => dirOf("slsk", "random_mix");

const file = (dir: string) => join(dir, ".intake.json");
const raw = (dir: string) => readFileSync(file(dir), "utf8");
const doc = (dir: string): Sidecar => readSidecar(file(dir))!;

function setStatus(path: string, status: Status): void {
  const s = readSidecar(path)!;
  s.status = status;
  writeFileSync(path, serializeSidecar(s));
}

beforeAll(async () => {
  corpus = setupCorpus();
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  library = join(corpus.dir, "library");
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    [
      "tiers:",
      `  music.uhq: { root: ${library}/music.uhq, gate: hires, growth: active }`,
      `  music.hq: { root: ${library}/music.hq, gate: lossless-first, growth: primary }`,
      "journal:",
      `  path: ${join(corpus.dir, "journal", "intake-journal.ndjson")}`,
      "",
    ].join("\n"),
  );
  await cmdScan([], ALL);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

// ---- identify / assign ------------------------------------------------------------

for (const status of REFUSED) {
  test(`identify and assign from ${status}: E_BAD_STATUS, nothing written`, async () => {
    setStatus(file(MOVEMENTS()), status);
    const before = raw(MOVEMENTS());
    const rulesBefore = treeHash(corpus.rules);
    const refused = (verb: string) => [
      { code: "E_BAD_STATUS", msg: `cannot ${verb} from status ${status}`, path: MOVEMENTS() },
    ];

    for (const force of [false, true]) {
      const ident = await cmdIdentify([MOVEMENTS()], { ...OPTS, force }, OFFLINE);
      expect(ident.exitCode).toBe(2);
      expect(ident.data).toBeNull();
      expect(ident.errors).toEqual(refused("identify"));
    }
    for (const opts of [OPTS, { ...OPTS, force: true }, { ...OPTS, collection: "[Ambient]" }, { ...OPTS, by: "user" }]) {
      const asg = await cmdAssign([MOVEMENTS()], opts, OFFLINE);
      expect(asg.exitCode).toBe(2);
      expect(asg.data).toBeNull();
      expect(asg.errors).toEqual(refused("assign"));
    }
    expect(raw(MOVEMENTS())).toBe(before);
    expect(treeHash(corpus.rules)).toBe(rulesBefore); // no override log, no feedback
    setStatus(file(MOVEMENTS()), "resolved");
  });
}

test("identify and assign with a refused root among legal ones: exit 1, the rest proceed", async () => {
  setStatus(file(MOVEMENTS()), "placed");
  const ident = await cmdIdentify([MOVEMENTS(), REFLECTIVE()], OPTS, OFFLINE);
  expect(ident.exitCode).toBe(1);
  expect(ident.data!.map((r) => r.root_path)).toEqual([REFLECTIVE()]);
  expect(ident.errors.map((e) => [e.code, e.path])).toEqual([["E_BAD_STATUS", MOVEMENTS()]]);
  expect(doc(REFLECTIVE()).identification).not.toBeNull();

  const asg = await cmdAssign([REFLECTIVE(), MOVEMENTS()], OPTS, OFFLINE);
  expect(asg.exitCode).toBe(1);
  expect(asg.data!.map((r) => r.root_path)).toEqual([REFLECTIVE()]);
  expect(asg.errors.map((e) => [e.code, e.path])).toEqual([["E_BAD_STATUS", MOVEMENTS()]]);
  expect(doc(MOVEMENTS()).identification).toBeNull();
  expect(doc(MOVEMENTS()).proposal).toBeNull();
  setStatus(file(MOVEMENTS()), "resolved");
});

test("identify and assign stay legal from new, resolved, proposed, approved", async () => {
  for (const status of ["new", "resolved", "proposed", "approved"] as const) {
    setStatus(file(LEAVING()), status);
    const ident = await cmdIdentify([LEAVING()], { ...OPTS, force: true }, OFFLINE);
    expect({ status, errors: ident.errors, exit: ident.exitCode }).toEqual({ status, errors: [], exit: 0 });
    const asg = await cmdAssign([LEAVING()], { ...OPTS, collection: "[Ambient]" }, OFFLINE);
    expect({ status, errors: asg.errors, exit: asg.exitCode }).toEqual({ status, errors: [], exit: 0 });
    expect(doc(LEAVING()).status).toBe(status); // neither command moves the status
  }
});

// ---- resolve --force / scan --force -------------------------------------------------

for (const status of NO_REBUILD) {
  test(`resolve --force from ${status}: E_BAD_STATUS, the sidecar is kept untouched`, async () => {
    setStatus(file(MOVEMENTS()), status);
    const before = raw(MOVEMENTS());
    for (const dryRun of [false, true]) {
      const result = await cmdResolve([MOVEMENTS()], { ...OPTS, force: true, dryRun });
      expect(result.exitCode).toBe(2);
      expect(result.data).toBeNull();
      expect(result.errors).toEqual([
        { code: "E_BAD_STATUS", msg: `cannot resolve --force from status ${status}`, path: MOVEMENTS() },
      ]);
    }
    expect(raw(MOVEMENTS())).toBe(before);
    // Without --force an existing sidecar is kept whatever its status.
    const plain = await cmdResolve([MOVEMENTS()], OPTS);
    expect(plain.exitCode).toBe(0);
    expect(plain.data!.kept).toEqual([MOVEMENTS()]);
    expect(raw(MOVEMENTS())).toBe(before);
    setStatus(file(MOVEMENTS()), "resolved");
  });
}

test("resolve --force on a path holding several roots: one envelope, the others rebuilt, exit 1", () => {
  setStatus(file(MOVEMENTS()), "placed");
  const before = raw(MOVEMENTS());
  const proc = Bun.spawnSync([process.execPath, "run", CLI, "resolve", SOLAR(), "--force", "--json"], {
    env: { ...process.env, INTAKE_RULES_DIR: corpus.rules },
  });
  expect(proc.exitCode).toBe(1);
  const lines = proc.stdout.toString().trimEnd().split("\n");
  expect(lines.length).toBe(1);
  const env = JSON.parse(lines[0]!);
  expect(env.ok).toBe(false);
  expect(env.errors).toEqual([
    { code: "E_BAD_STATUS", msg: "cannot resolve --force from status placed", path: MOVEMENTS() },
  ]);
  expect(env.data.written.map((w: { root_path: string }) => w.root_path).sort()).toEqual([REFLECTIVE(), LEAVING()].sort());
  expect(env.data.kept).toEqual([MOVEMENTS()]);
  expect(raw(MOVEMENTS())).toBe(before);
  expect(doc(REFLECTIVE()).history.at(-1)!.event).toBe("re-resolved");
  setStatus(file(MOVEMENTS()), "resolved");
});

test("resolve --force keeps a whole dir when one of its virtual roots may not be rebuilt", async () => {
  const sidecars = () => readdirSync(MIX()).filter(isSidecarName).sort()
    .map((n) => [n, readFileSync(join(MIX(), n), "utf8")] as const);
  const virtuals = rootsFromRefs([MIX()], []);
  expect(virtuals.length).toBeGreaterThan(1);
  setStatus(virtuals[0]!.sidecarPath, "gc_done");
  const before = sidecars();

  const result = await cmdResolve([MIX()], { ...OPTS, force: true });
  expect(result.exitCode).toBe(2);
  expect(result.errors).toEqual([
    { code: "E_BAD_STATUS", msg: "cannot resolve --force from status gc_done", path: MIX() },
  ]);
  expect(sidecars()).toEqual(before); // the siblings were not rebuilt either
  setStatus(virtuals[0]!.sidecarPath, "resolved");
});

// ---- gc -------------------------------------------------------------------------------

test("gc on a named root that is not placed: E_BAD_STATUS (rejected included)", async () => {
  for (const status of ["new", "resolved", "proposed", "approved", "placing", "gc_done", "rejected"] as const) {
    setStatus(file(MOVEMENTS()), status);
    const before = raw(MOVEMENTS());
    const result = await cmdGc([MOVEMENTS()], OPTS);
    expect(result.exitCode).toBe(2);
    expect(result.data).toBeNull();
    expect(result.errors).toEqual([{ code: "E_BAD_STATUS", msg: `cannot gc from status ${status}`, path: MOVEMENTS() }]);
    expect(raw(MOVEMENTS())).toBe(before);
  }
  setStatus(file(MOVEMENTS()), "resolved");
});

test("gc: a placed root proceeds next to a refused one (exit 1); the all-roots form skips silently", async () => {
  expect((await cmdPropose([POLLEN()], OPTS, OFFLINE)).errors).toEqual([]);
  expect(cmdApprove([POLLEN()], OPTS).errors).toEqual([]);
  expect((await cmdExecute([POLLEN()], OPTS)).errors).toEqual([]);
  expect(doc(POLLEN()).status).toBe("placed");

  const named = await cmdGc([POLLEN(), MOVEMENTS()], { ...OPTS, dryRun: true });
  expect(named.exitCode).toBe(1);
  expect(named.data!.map((r) => [r.root_path, r.dry_run])).toEqual([[POLLEN(), true]]);
  expect(named.errors).toEqual([{ code: "E_BAD_STATUS", msg: "cannot gc from status resolved", path: MOVEMENTS() }]);

  const all = await cmdGc([], { ...ALL, dryRun: true });
  expect(all.errors).toEqual([]);
  expect(all.exitCode).toBe(0);
  expect(all.data!.map((r) => r.root_path)).toEqual([POLLEN()]);
});

test("scan --force applies the resolve --force guard to the placed root, rebuilds the rest", async () => {
  expect(doc(POLLEN()).status).toBe("placed"); // really placed by the gc test above
  const before = raw(POLLEN());
  const result = await cmdScan([], { ...ALL, force: true });
  expect(result.exitCode).toBe(1);
  expect(result.errors).toEqual([
    { code: "E_BAD_STATUS", msg: "cannot scan --force from status placed", path: POLLEN() },
  ]);
  const blocks = result.data!;
  expect(blocks.map((b) => b.income)).toEqual(["downloads", "slsk", "todo"]);
  expect(blocks.flatMap((b) => b.kept)).toEqual([POLLEN()]);
  expect(blocks.flatMap((b) => b.written).length).toBe(21);
  expect(raw(POLLEN())).toBe(before);

  const plain = await cmdScan([], ALL);
  expect(plain.exitCode).toBe(0);
  expect(plain.errors).toEqual([]);
});
