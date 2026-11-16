// Unpack tool time limit and stop signals. A fake 7zz on a temp PATH writes
// into its -o dir, then runs `sleep` as a child and waits, the way Homebrew's
// `7z` shell wrapper runs p7zip, and records both PIDs. So the tests see that
// the kill reaches the whole tool, not just the process intake started.
// - time limit: unpackArchive with a short timeoutMs, in a subprocess (the
//   fake must be first on PATH, and Bun.which reads PATH at process start);
// - signals: the CLI as a subprocess, signalled while the fake sleeps.
// Every test kills what it started, even when it fails.

import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setupCorpus, type Corpus } from "./helpers.ts";

const CLI = join(import.meta.dir, "..", "src", "cli.ts");
const ARCHIVE_TS = join(import.meta.dir, "..", "src", "archive.ts");
const SYS_PATH = "/usr/bin:/bin";
const NAME = "Synthetic - Hung Tool (2020).7z";

let corpus: Corpus;
let income: string;
let bin: string;
let pidFile: string;
let archive: string;
let stem: string;

/** Writes Album/fake.txt into its -o dir, starts `sleep 30`, records "<own pid> <sleep pid>", waits. */
const HANG = `#!/bin/sh
out=
for a in "$@"; do case "$a" in -o?*) out="\${a#-o}";; esac; done
mkdir -p "$out/Album" && printf x > "$out/Album/fake.txt"
/bin/sleep 30 &
echo "$$ $!" > "$FAKE_PIDS.tmp" && mv "$FAKE_PIDS.tmp" "$FAKE_PIDS"
wait
`;

beforeAll(() => {
  corpus = setupCorpus();
  income = join(corpus.dir, "arc");
  bin = join(corpus.dir, "bin-hang");
  pidFile = join(corpus.dir, "fake.pids");
  writeFileSync(
    join(corpus.rules, "income.yaml"),
    ["income:", "  - name: arc", `    path: ${income}`, "    source_type: web", ""].join("\n"),
  );
  mkdirSync(bin, { recursive: true });
  writeFileSync(join(bin, "7zz"), HANG);
  chmodSync(join(bin, "7zz"), 0o755);
});

beforeEach(() => {
  rmSync(income, { recursive: true, force: true });
  mkdirSync(income, { recursive: true });
  rmSync(pidFile, { force: true });
  archive = join(income, NAME);
  stem = archive.slice(0, -".7z".length);
  writeFileSync(archive, new Uint8Array([0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]));
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
  rmSync(corpus.dir, { recursive: true, force: true });
});

const env = () => ({ PATH: `${bin}:${SYS_PATH}`, INTAKE_RULES_DIR: corpus.rules, HOME: process.env.HOME ?? "/tmp", FAKE_PIDS: pidFile });

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

// The limit must leave the fake time to start sh, write its file, start sleep
// and record both PIDs; at 400 ms a loaded machine killed it before the PID
// file existed, and the children check had nothing to check.
const LIMIT_MS = 2000;

test("a tool past the time limit is killed with its children: failed, no .partial or .unpacked", async () => {
  const code = [
    `import { unpackArchive } from ${JSON.stringify(ARCHIVE_TS)};`,
    `console.log(JSON.stringify(await unpackArchive(${JSON.stringify(archive)}, false, { timeoutMs: ${LIMIT_MS} })));`,
  ].join("\n");
  const started = Date.now();
  const proc = Bun.spawn([process.execPath, "-e", code], { env: env(), stdout: "pipe", stderr: "pipe" });
  const guard = setTimeout(() => proc.kill("SIGKILL"), 8000);
  try {
    const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    if (!out.trim()) throw new Error(`no result after ${Date.now() - started} ms; stderr: ${err}`);
    expect(JSON.parse(out)).toEqual({
      archive,
      target: `${stem}.unpacked`,
      action: "failed",
      error: "7zz timed out after 2 s",
    });
    const pids = fakePids();
    expect(pids).toHaveLength(2);
    for (const pid of pids) expect(await waitFor(() => !alive(pid), 2000)).toBe(true);
    expect(readdirSync(income)).toEqual([NAME]);
  } finally {
    clearTimeout(guard);
  }
}, 15_000);

for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"] as const) {
  test(`${sig} to intake mid-unpack kills the tool, removes the partial dir, and intake ends by ${sig}`, async () => {
    const proc = Bun.spawn([process.execPath, "run", CLI, "scan", "arc", "--json"], { env: env(), stdout: "pipe", stderr: "pipe" });
    const guard = setTimeout(() => proc.kill("SIGKILL"), 8000);
    try {
      expect(await waitFor(() => existsSync(pidFile), 5000)).toBe(true);
      expect(existsSync(join(`${stem}.unpacked.partial`, "Album", "fake.txt"))).toBe(true);
      proc.kill(sig);
      await proc.exited;
      expect(proc.signalCode).toBe(sig);
      const pids = fakePids();
      expect(pids).toHaveLength(2);
      for (const pid of pids) expect(await waitFor(() => !alive(pid), 2000)).toBe(true);
      expect(readdirSync(income)).toEqual([NAME]);
    } finally {
      clearTimeout(guard);
    }
  }, 15_000);
}
