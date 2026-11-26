// The beets shim runs under a time limit, in its own process group
// (subprocessShim through runTool, src/proc.ts). Fake shims only: small sh
// and bun scripts in a temp dir; no beets, no network. The hanging fake
// starts `sleep` in the background, records "<own pid> <sleep pid>" and
// waits, so the tests see that a kill reaches the whole shim. Every test
// kills what it started, even when it fails.
// - time limit: shim_timeout, and both processes gone;
// - output: a result over 1 MB parsed, error exits as before;
// - SIGTERM: a bun child running the shim, signalled while the fake hangs;
// - propose: one stalled root does not stall the batch (limit from
//   structure.yaml, fake shim via INTAKE_BEETS_SHIM);
// - config: assign.shim_timeout_s default, read, refused.

import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { cmdResolve } from "../src/commands.ts";
import { cmdPropose } from "../src/commands-p3.ts";
import { DEFAULT_ASSIGN_CONFIG, loadAssignConfig, RulesError } from "../src/config.ts";
import { subprocessShim } from "../src/providers.ts";
import { readSidecar } from "../src/sidecar.ts";
import type { IdentCandidate, Sidecar } from "../src/types.ts";
import { FIXTURES, setupCorpus, useTempLibrary, type Corpus } from "./helpers.ts";

const PROVIDERS_TS = join(import.meta.dir, "..", "src", "providers.ts");
const CLI = join(import.meta.dir, "..", "src", "cli.ts");

// The limit must leave the fake time to start sh and sleep and record both
// PIDs (the archive timeout tests' lesson: 400 ms was too short when loaded).
const LIMIT_MS = 2000;

const QUICK: IdentCandidate = {
  source: "mb",
  release_id: "mb-quick",
  artist: "Hilyard",
  album: "Division Cycle",
  year: "2019",
  label: null,
  catno: null,
  distance: 0.05,
  track_mapping: null,
};

let tmp: string;
let pidFile: string;
/** `/bin/sh <fake>`: hangs for a root dir whose name contains "Stalled", else prints QUICK. */
let shim: string[];

beforeAll(() => {
  tmp = mkdtempSync(join(tmpdir(), "intake-shimtimeout-"));
  pidFile = join(tmp, "fake.pids");
  shim = ["/bin/sh", fake("shim.sh", [
    'case "$1" in',
    "  *Stalled*)",
    "    /bin/sleep 30 &",
    `    echo "$$ $!" > '${pidFile}.tmp' && mv '${pidFile}.tmp' '${pidFile}'`,
    "    wait",
    "    exit 0",
    "    ;;",
    "esac",
    `printf '%s\\n' '${JSON.stringify({ candidates: [QUICK] })}'`,
  ])];
});

beforeEach(() => {
  rmSync(pidFile, { force: true });
});

afterEach(() => {
  for (const pid of fakePids()) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {
      // gone, as it should be
    }
  }
});

afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

/** A script in the temp dir; returns its path. */
function fake(name: string, lines: string[]): string {
  const path = join(tmp, name);
  writeFileSync(path, lines.join("\n") + "\n");
  return path;
}

function fakePids(): number[] {
  return existsSync(pidFile) ? readFileSync(pidFile, "utf8").trim().split(" ").map(Number) : [];
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code !== "ESRCH";
  }
}

async function waitFor(cond: () => boolean, ms: number): Promise<boolean> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (cond()) return true;
    await Bun.sleep(20);
  }
  return cond();
}

/** Both PIDs of the hanging fake were recorded, and both are gone. */
async function expectGroupGone(): Promise<void> {
  const pids = fakePids();
  expect(pids).toHaveLength(2);
  for (const pid of pids) expect(await waitFor(() => !alive(pid), 2000)).toBe(true);
}

const FILES = ["01 - Track.flac"];
const stalledDir = () => join(tmp, "Synthetic Artist - Stalled Album");

// ---- time limit, output, error exits ------------------------------------------

test("a shim past the time limit gives shim_timeout, and its whole process group is killed", async () => {
  const started = Date.now();
  expect(await subprocessShim(shim, LIMIT_MS).identify(stalledDir(), FILES)).toEqual({ error: "shim_timeout" });
  expect(Date.now() - started).toBeLessThan(LIMIT_MS + 3000);
  await expectGroupGone();
}, 15_000);

test("a shim within the limit is unaffected", async () => {
  expect(await subprocessShim(shim, LIMIT_MS).identify(join(tmp, "Quick Album"), FILES)).toEqual({ candidates: [QUICK] });
});

test("a valid result over 1 MB on stdout is parsed (with 1 MB on stderr too)", async () => {
  const album = "x".repeat(1_200_000);
  const big = fake("big.ts", [
    `process.stderr.write("e".repeat(1_100_000));`,
    `console.log(JSON.stringify({ candidates: [{ ...${JSON.stringify(QUICK)}, album: "x".repeat(1_200_000) }] }));`,
  ]);
  const result = await subprocessShim([process.execPath, big], 10_000).identify(join(tmp, "Big Album"), FILES);
  expect(result).toEqual({ candidates: [{ ...QUICK, album }] });
}, 15_000);

test("error exits give the same results as before", async () => {
  const run = (name: string, lines: string[]) =>
    subprocessShim(["/bin/sh", fake(name, lines)], 10_000).identify(join(tmp, "Any Album"), FILES);
  // Non-zero with {"error": ...}: that error.
  expect(await run("err.sh", [`printf '%s\\n' '{"error": "beets_error: stub failure"}'`, "exit 3"]))
    .toEqual({ error: "beets_error: stub failure" });
  // Non-zero without one: the exit code.
  expect(await run("crash.sh", ["echo Traceback", "echo 'Traceback (most recent call last):' >&2", "exit 1"]))
    .toEqual({ error: "shim_exit_1" });
  expect(await run("silent.sh", ["exit 5"])).toEqual({ error: "shim_exit_5" });
  // Exit 0 without candidates.
  expect(await run("garbage.sh", ["echo not json"])).toEqual({ error: "shim_bad_output" });
  expect(await run("nocands.sh", [`printf '%s\\n' '{"result": []}'`])).toEqual({ error: "shim_bad_output" });
  // Not startable.
  expect(await subprocessShim([join(tmp, "no-such-python3")], 10_000).identify(join(tmp, "Any Album"), FILES))
    .toEqual({ error: "shim_unavailable" });
});

// ---- stop signals -------------------------------------------------------------

test("SIGTERM to intake mid-shim kills the shim's process group, and intake ends by SIGTERM", async () => {
  const code = [
    `import { subprocessShim } from ${JSON.stringify(PROVIDERS_TS)};`,
    `const r = await subprocessShim(${JSON.stringify(shim)}, 60_000).identify(${JSON.stringify(stalledDir())}, ${JSON.stringify(FILES)});`,
    `console.log("returned", JSON.stringify(r));`,
  ].join("\n");
  const proc = Bun.spawn([process.execPath, "-e", code], { stdout: "pipe", stderr: "pipe" });
  const guard = setTimeout(() => proc.kill("SIGKILL"), 10_000);
  try {
    expect(await waitFor(() => existsSync(pidFile), 5000)).toBe(true);
    proc.kill("SIGTERM");
    await proc.exited;
    expect(proc.signalCode).toBe("SIGTERM");
    expect(await new Response(proc.stdout).text()).toBe("");
    await expectGroupGone();
  } finally {
    clearTimeout(guard);
  }
}, 15_000);

// ---- propose: one root cannot stall a batch ---------------------------------------

const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
};
const doc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;

interface ProposeCorpus {
  corpus: Corpus;
  stalled: string;
  quick: string;
  structure: string;
}

/**
 * Run `fn` on a fresh corpus with two roots renamed to synthetic names and
 * resolved, a temp library, `assign.shim_timeout_s` set to LIMIT_MS and the
 * fake shim as INTAKE_BEETS_SHIM; all of it undone afterwards.
 */
async function withProposeCorpus(fn: (p: ProposeCorpus) => Promise<void>): Promise<void> {
  delete process.env.DISCOGS_TOKEN;
  delete process.env.LASTFM_API_KEY;
  process.env.INTAKE_BEETS_SHIM = shim.join(" ");
  const corpus = setupCorpus();
  try {
    const todo = join(corpus.income, "todo");
    const stalled = join(todo, "Synthetic Artist [2020] Stalled Album");
    const quick = join(todo, "Synthetic Artist [2021] Quick Album");
    renameSync(join(todo, "Bluetech [2011] Cosmic Dubwise"), stalled);
    renameSync(join(todo, "Hilyard [2019] Division Cycle"), quick);
    useTempLibrary(corpus);
    const structure = join(corpus.rules, "structure.yaml");
    const text = readFileSync(structure, "utf8");
    const withLimit = text.replace("  shim_accept_distance: 0.15\n", `  shim_accept_distance: 0.15\n  shim_timeout_s: ${LIMIT_MS / 1000}\n`);
    expect(withLimit).not.toBe(text);
    writeFileSync(structure, withLimit);
    for (const dir of [stalled, quick]) {
      expect((await cmdResolve([dir], OPTS)).errors).toEqual([]);
      expect(doc(dir).status).toBe("resolved");
    }
    await fn({ corpus, stalled, quick, structure });
  } finally {
    delete process.env.INTAKE_BEETS_SHIM;
    rmSync(corpus.dir, { recursive: true, force: true });
  }
}

test("propose: a stalled root times out into the degraded path, and the next root is proposed", async () => {
  await withProposeCorpus(async ({ stalled, quick }) => {
    const started = Date.now();
    const result = await cmdPropose([stalled, quick], OPTS);
    const elapsed = Date.now() - started;
    expect(result.errors).toEqual([]);
    // Root 1 took its limit; root 2 did not wait for its own.
    expect(elapsed).toBeGreaterThanOrEqual(LIMIT_MS);
    expect(elapsed).toBeLessThan(2 * LIMIT_MS);
    await expectGroupGone();

    const one = doc(stalled);
    expect(one.identification).toMatchObject({ status: "unconfirmed", source: null, issues: ["shim_timeout"] });
    expect(one.cluster.needs_review).toBe(true);
    expect(one.status).toBe("proposed"); // explicit propose carries a flagged root on, as after any shim error
    const two = doc(quick);
    expect(two.status).toBe("proposed");
    expect(two.identification).toMatchObject({ status: "shim", source: "mb", release_id: "mb-quick", distance: 0.05 });
    expect("issues" in two.identification!).toBe(false);
    expect(result.notices).toEqual(["beets shim failed for 1 root(s): shim_timeout"]);
  });
}, 20_000);

test("propose with a bad assign.shim_timeout_s: E_BAD_RULES from the CLI, no root touched", async () => {
  await withProposeCorpus(async ({ corpus, quick, structure }) => {
    writeFileSync(structure, readFileSync(structure, "utf8").replace(`shim_timeout_s: ${LIMIT_MS / 1000}`, "shim_timeout_s: 0"));
    const before = readFileSync(join(quick, ".intake.json"), "utf8");
    const cli = Bun.spawnSync([process.execPath, "run", CLI, "propose", quick, "--json"], {
      env: { ...process.env, INTAKE_RULES_DIR: corpus.rules, INTAKE_BEETS_SHIM: shim.join(" ") },
      timeout: 30_000,
    });
    expect(cli.exitCode).toBe(2);
    expect(JSON.parse(cli.stdout.toString())).toEqual({
      ok: false,
      data: null,
      errors: [{
        code: "E_BAD_RULES",
        msg: `${structure}: assign.shim_timeout_s: must be a number of seconds above 0, got 0`,
        path: structure,
      }],
    });
    expect(readFileSync(join(quick, ".intake.json"), "utf8")).toBe(before);
  });
}, 20_000);

// ---- config -----------------------------------------------------------------------

/** A rules dir holding only structure.yaml with `text`. */
function rulesWith(text: string): string {
  const dir = mkdtempSync(join(tmp, "rules-"));
  writeFileSync(join(dir, "structure.yaml"), text);
  return dir;
}

test("assign.shim_timeout_s: default 180, read from structure.yaml", () => {
  expect(DEFAULT_ASSIGN_CONFIG.shim_timeout_s).toBe(180);
  expect(loadAssignConfig(null).shim_timeout_s).toBe(180);
  expect(loadAssignConfig(join(FIXTURES, "rules")).shim_timeout_s).toBe(180); // no key there
  expect(loadAssignConfig(rulesWith("assign:\n  shim_accept_distance: 0.2\n")).shim_timeout_s).toBe(180);
  expect(loadAssignConfig(rulesWith("assign:\n  shim_timeout_s: 45\n")).shim_timeout_s).toBe(45);
  expect(loadAssignConfig(rulesWith("assign:\n  shim_timeout_s: 0.5\n")).shim_timeout_s).toBe(0.5);
});

test("assign.shim_timeout_s: anything but a finite number above 0 is a RulesError naming the key", () => {
  for (const [value, got] of [
    ["0", "0"],
    ["-30", "-30"],
    ['"30"', '"30"'],
    [".inf", "Infinity"],
    [".nan", "NaN"],
    ["", "null"],
    ["[30]", "a list"],
    ["{ s: 30 }", "a mapping"],
  ]) {
    const dir = rulesWith(`assign:\n  shim_timeout_s: ${value}\n`);
    let thrown: unknown = null;
    try {
      loadAssignConfig(dir);
    } catch (e) {
      thrown = e;
    }
    expect(thrown).toBeInstanceOf(RulesError);
    const file = join(dir, "structure.yaml");
    expect((thrown as RulesError).file).toBe(file);
    expect((thrown as RulesError).key).toBe("assign.shim_timeout_s");
    expect((thrown as RulesError).message).toBe(`${file}: assign.shim_timeout_s: must be a number of seconds above 0, got ${got}`);
  }
});
