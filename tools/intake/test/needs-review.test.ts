// Doc 03 v1.2 (amendment 003, CR-004.11): `needs_review` is sticky. Commands
// may raise it; only `approve` clears it, on the roots it approves. A user
// assignment (`assign --collection`, `--by user`) does NOT clear it. A
// `resolve --force` rebuild starts from scratch.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { cmdResolve, cmdScan, cmdStatus } from "../src/commands.ts";
import { cmdAssign, cmdIdentify } from "../src/commands-p2.ts";
import { cmdApprove, cmdPropose } from "../src/commands-p3.ts";
import type { Providers } from "../src/providers.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, useTempLibrary, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {}, all: false,
  collection: null, by: null, allResolved: false, batch: null,
};
const OFFLINE: { providers: Providers } = { providers: { discogs: null, similar: null, shim: null } };

let corpus: Corpus;
const dirOf = (...seg: string[]) => join(corpus.income, ...seg);
const HILYARD = () => dirOf("todo", "Hilyard [2019] Division Cycle"); // resolver raised needs_review
const POLLEN = () => dirOf("downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)");
const BLUETECH = () => dirOf("todo", "Bluetech [2011] Cosmic Dubwise");
const OTT = () => dirOf("todo", "Ott - Blumenkraft (2003)");
const doc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;
const raw = (dir: string) => readFileSync(join(dir, ".intake.json"), "utf8");
const summary = (dir: string) => cmdStatus([], { ...OPTS, filters: { root_path: dir } }).data![0]!;

beforeAll(async () => {
  corpus = setupCorpus();
  useTempLibrary(corpus); // propose refuses a tier root that does not exist
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  await cmdScan([], { ...OPTS, all: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("a user assignment keeps needs_review set (sticky)", async () => {
  expect(doc(HILYARD()).cluster.needs_review).toBe(true);
  for (const opts of [{ ...OPTS, collection: "[Ambient]" }, { ...OPTS, collection: "[Ambient]", by: "user" }]) {
    const r = await cmdAssign([HILYARD()], opts, OFFLINE);
    expect(r.errors).toEqual([]);
    expect(doc(HILYARD()).proposal!.assigned_by).toBe("user");
    expect(doc(HILYARD()).cluster.needs_review).toBe(true);
  }
  // An engine re-run only ever raises the flag.
  expect((await cmdAssign([HILYARD()], { ...OPTS, force: true }, OFFLINE)).errors).toEqual([]);
  expect(doc(HILYARD()).cluster.needs_review).toBe(true);
  expect((await cmdAssign([HILYARD()], { ...OPTS, collection: "[Ambient]" }, OFFLINE)).errors).toEqual([]);
  expect(summary(HILYARD())).toMatchObject({ needs_review: true, proposal: { assigned_by: "user" } });
});

test("approve clears needs_review on the root it approves (not under --dry-run)", async () => {
  expect((await cmdPropose([HILYARD()], OPTS, OFFLINE)).errors).toEqual([]);
  expect(doc(HILYARD())).toMatchObject({ status: "proposed", cluster: { needs_review: true } });

  const before = raw(HILYARD());
  expect(cmdApprove([HILYARD()], { ...OPTS, dryRun: true }).errors).toEqual([]);
  expect(raw(HILYARD())).toBe(before);

  const r = cmdApprove([HILYARD()], OPTS);
  expect(r.errors).toEqual([]);
  expect(r.data).toEqual([{ id: doc(HILYARD()).id, root_path: HILYARD(), status: "approved" }]);
  expect(doc(HILYARD())).toMatchObject({ status: "approved", cluster: { needs_review: false } });
  expect(summary(HILYARD()).needs_review).toBe(false);
});

test("approve of several roots clears each; a refused root keeps its flag", async () => {
  // Offline identify raises needs_review on these (no provider confirms them).
  for (const dir of [BLUETECH(), OTT()]) {
    expect((await cmdIdentify([dir], OPTS, OFFLINE)).errors).toEqual([]);
    expect(doc(dir).cluster.needs_review).toBe(true);
  }
  expect((await cmdPropose([BLUETECH()], OPTS, OFFLINE)).errors).toEqual([]);
  const r = cmdApprove([BLUETECH(), OTT()], OPTS); // Ott is resolved, not proposed
  expect(r.exitCode).toBe(1);
  expect(r.errors.map((e) => [e.code, e.path])).toEqual([["E_BAD_STATUS", OTT()]]);
  expect(doc(BLUETECH()).cluster.needs_review).toBe(false);
  expect(doc(OTT()).cluster.needs_review).toBe(true);
});

test("a resolve --force rebuild starts from scratch", async () => {
  expect(doc(POLLEN()).cluster.needs_review).toBe(false); // the resolver's verdict
  expect((await cmdIdentify([POLLEN()], OPTS, OFFLINE)).errors).toEqual([]);
  expect(doc(POLLEN()).cluster.needs_review).toBe(true);
  expect((await cmdResolve([POLLEN()], { ...OPTS, force: true })).errors).toEqual([]);
  expect(doc(POLLEN())).toMatchObject({ status: "resolved", identification: null, cluster: { needs_review: false } });
});
