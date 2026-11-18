// Doc 03 v1.2 `status --filter` (CR-004.5): the pinned key list plus `id`;
// a value matches the sidecar's value as a string, exactly (`true`/`false` for
// the flags, "" for an absent value); filters on different keys all match;
// one value per key; an unknown key is E_BAD_ARGS. A malformed --filter
// argument and a key given twice are E_BAD_ARGS too, never silently ignored
// or overwritten.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { cmdScan, cmdStatus } from "../src/commands.ts";
import { rootsFromRefs } from "../src/commands-p2.ts";
import type { SidecarSummary } from "../src/sidecar.ts";
import type { Sidecar } from "../src/types.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const OPTS = { json: true, dryRun: false, force: false, filters: {}, all: false };

let corpus: Corpus;
let rows: SidecarSummary[];
/** Every sidecar with its dir, read the way status reads them. */
let docs: { dir: string; sc: Sidecar }[];

const status = (filters: Record<string, string>) => cmdStatus([], { ...OPTS, filters });
const ids = (r: { data: SidecarSummary[] | null }) => (r.data ?? []).map((s) => s.id).sort();
const idsWhere = (pred: (sc: Sidecar, dir: string) => boolean) =>
  docs.filter((d) => pred(d.sc, d.dir)).map((d) => d.sc.id).sort();

function run(args: string[]) {
  const proc = Bun.spawnSync([process.execPath, "run", CLI, "status", ...args], {
    env: { ...process.env, INTAKE_RULES_DIR: corpus.rules },
  });
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
}

beforeAll(async () => {
  corpus = setupCorpus();
  await cmdScan([], { ...OPTS, all: true });
  rows = status({}).data!;
  expect(rows.length).toBe(22);
  docs = rows.flatMap((r) => rootsFromRefs([r.id], []).map((ref) => ({ dir: ref.dir, sc: ref.sidecar })));
  expect(docs.length).toBe(22);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("id selects exactly that sidecar", () => {
  for (const r of rows) expect(ids(status({ id: r.id }))).toEqual([r.id]);
  expect(status({ id: "itk_00000000" }).data).toEqual([]);
});

test("every pinned key filters on the sidecar's value as a string", () => {
  const solar = join(corpus.income, "slsk", "Solar Fields", "Solar Fields - Movements (2009)");
  const cases: [Record<string, string>, (sc: Sidecar, dir: string) => boolean][] = [
    [{ status: "resolved" }, (sc) => sc.status === "resolved"],
    [{ status: "new" }, (sc) => sc.status === "new"],
    [{ needs_review: "true" }, (sc) => sc.cluster.needs_review],
    [{ needs_review: "false" }, (sc) => !sc.cluster.needs_review],
    [{ income_folder: "slsk" }, (sc) => sc.source.income_folder === "slsk"],
    [{ source_type: "web" }, (sc) => sc.source.source_type === "web"],
    [{ tier: "uhq" }, (sc) => sc.quality.tier_eligible === "uhq"],
    [{ tier_eligible: "reject" }, (sc) => sc.quality.tier_eligible === "reject"],
    [{ virtual: "true" }, (sc) => sc.virtual],
    [{ singles: "true" }, (sc) => sc.singles === true],
    [{ singles: "false" }, (sc) => sc.singles !== true],
    [{ albumartist: "Solar Fields" }, (sc) => sc.cluster.albumartist === "Solar Fields"],
    [{ album: "Movements" }, (sc) => sc.cluster.album === "Movements"],
    [{ root_path: solar }, (_sc, dir) => dir === solar],
    // Different keys must all match.
    [{ status: "resolved", virtual: "true", singles: "false" }, (sc) => sc.status === "resolved" && sc.virtual && sc.singles !== true],
  ];
  for (const [filters, pred] of cases) {
    const want = idsWhere(pred);
    expect({ filters, n: want.length > 0 }).toEqual({ filters, n: true }); // each case selects something
    expect({ filters, got: ids(status(filters)) }).toEqual({ filters, got: want });
  }
  // Exact, not a prefix, a substring or case-insensitive.
  expect(status({ albumartist: "Solar" }).data).toEqual([]);
  expect(status({ albumartist: "solar fields" }).data).toEqual([]);
  expect(status({ needs_review: "1" }).data).toEqual([]);
});

test("an absent value matches the empty string", () => {
  const noAlbum = idsWhere((sc) => sc.cluster.album === null);
  expect(noAlbum.length).toBeGreaterThan(0); // singles carry no album
  expect(ids(status({ album: "" }))).toEqual(noAlbum);
  expect(ids(status({ albumartist: "" }))).toEqual(idsWhere((sc) => sc.cluster.albumartist === null));
  expect(status({ income_folder: "" }).data).toEqual([]); // every fixture root is in an income folder
});

test("an unknown key is E_BAD_ARGS with no data", () => {
  const unknown: Record<string, string>[] = [{ bogus: "1" }, { status: "resolved", artist: "Ott" }, { constructor: "x" }];
  for (const filters of unknown) {
    const r = status(filters);
    expect(r.exitCode).toBe(2);
    expect(r.data).toBeNull();
    expect(r.errors.map((e) => e.code)).toEqual(["E_BAD_ARGS"]);
  }
  const cli = run(["--filter", "bogus=1", "--json"]);
  expect(cli.code).toBe(2);
  const env = JSON.parse(cli.stdout);
  expect(env.ok).toBe(false);
  expect(env.data).toBeNull();
  expect(env.errors).toEqual([{ code: "E_BAD_ARGS", msg: "unknown --filter key: bogus", path: null }]);
});

test("malformed --filter arguments and a key given twice are E_BAD_ARGS", () => {
  const bad: string[][] = [
    ["--filter", "status"], // no "="
    ["--filter", "=resolved"], // empty key
    ["--filter"], // no argument
    ["--filter", "--json"], // an option is not the argument; --json still applies
    ["--filter", "status=new", "--filter", "status=resolved"], // one value per key
    ["--filter", "status=new", "--filter", "status=new"],
    ["--filter", "tier=hq", "--filter", "tier_eligible=hq"], // alias: the same key
  ];
  for (const args of bad) {
    const r = run([...args, "--json"]);
    expect({ args, code: r.code }).toEqual({ args, code: 2 });
    const env = JSON.parse(r.stdout);
    expect(env.data).toBeNull();
    expect({ args, codes: env.errors.map((e: { code: string }) => e.code) }).toEqual({ args, codes: ["E_BAD_ARGS"] });
  }
  const human = run(["--filter", "status"]);
  expect(human.code).toBe(2);
  expect(human.stdout).toBe("");
  expect(human.stderr).toContain("error E_BAD_ARGS:");

  // A value may itself contain "=": only the first one splits.
  const ok = run(["--filter", "album=a=b", "--json"]);
  expect(ok.code).toBe(0);
  expect(JSON.parse(ok.stdout).data).toEqual([]);
});
