// The real Python shim (shim/beets_identify.py) against stub beets packages,
// one per API shape (test/fakes/beets-1.6, test/fakes/beets-2.x). No real
// beets, no network. `python3 -S` keeps the host's site-packages (and any
// real beets in them) out; PYTHONPATH still applies.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { subprocessShim } from "../src/providers.ts";

const SHIM = join(import.meta.dir, "..", "shim", "beets_identify.py");
const STUBS = join(import.meta.dir, "fakes");
type Stub = "beets-1.6" | "beets-2.x";

let tmp: string;
let release: string;
let noAudio: string;

beforeAll(() => {
  tmp = mkdtempSync(join(tmpdir(), "intake-shim-"));
  release = join(tmp, "Stub Artist - Stub Album");
  mkdirSync(release);
  for (const name of ["01 - Alpha.flac", "02 - Beta.mp3", "cover.jpg", "._01 - Alpha.flac"]) {
    writeFileSync(join(release, name), "");
  }
  noAudio = join(tmp, "no audio");
  mkdirSync(noAudio);
  writeFileSync(join(noAudio, "cover.jpg"), "");
});

afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

function shimEnv(stub: Stub | null, extra: Record<string, string> = {}): Record<string, string> {
  return {
    PATH: process.env.PATH ?? "",
    PYTHONDONTWRITEBYTECODE: "1",
    ...(stub ? { PYTHONPATH: join(STUBS, stub) } : {}),
    ...extra,
  };
}

function runShim(args: string[], stub: Stub | null, extra: Record<string, string> = {}) {
  const proc = Bun.spawnSync(["python3", "-S", SHIM, ...args], {
    env: shimEnv(stub, extra),
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = proc.stdout.toString();
  return { code: proc.exitCode, doc: JSON.parse(stdout), stderr: proc.stderr.toString() };
}

const MAPPING = { "01 - Alpha.flac": "Alpha", "02 - Beta.mp3": "Beta" };

function stub2(source: "mb" | "discogs", release_id: string, distance: number) {
  return {
    source,
    release_id,
    artist: "Stub Artist",
    album: "Stub Album",
    year: "2012",
    label: "Stub Label",
    catno: "STUB-2",
    distance,
    track_mapping: MAPPING,
  };
}

test("beets 1.6 shape: tag_album(items) 3-tuple, no plugin loading", () => {
  const { code, doc } = runShim([release, "--json"], "beets-1.6");
  expect(code).toBe(0);
  expect(doc).toEqual({
    candidates: [
      {
        source: "mb",
        release_id: "mb-16",
        artist: "Stub Artist",
        album: "Stub Album",
        year: "2012",
        label: "Stub Label",
        catno: "STUB-16",
        distance: 0.0712,
        track_mapping: MAPPING,
      },
    ],
  });
});

test("beets 2.14 shape: Source in, Proposal out, plugins loaded first (default musicbrainz)", () => {
  // Without load_plugins() the stub, like real 2.x, has no metadata source and yields nothing.
  const { code, doc, stderr } = runShim([release, "--json"], "beets-2.x");
  expect(code).toBe(0);
  expect(doc).toEqual({
    candidates: [
      stub2("mb", "mb-1", 0.05),
      stub2("mb", "mb-2", 0.1),
      stub2("mb", "mb-3", 0.15),
      stub2("mb", "mb-4", 0.2),
      stub2("mb", "mb-5", 0.25),
    ],
  });
  expect(stderr).toContain("stub beets: loading plugins ['musicbrainz']"); // printed by beets, kept off stdout
});

test("beets 2.x: configured plugin list respected; non-MB/Discogs sources dropped; top 5", () => {
  const { code, doc } = runShim([release, "--json"], "beets-2.x", { STUB_BEETS_PLUGINS: "musicbrainz,discogs,spotify" });
  expect(code).toBe(0);
  expect(doc).toEqual({
    candidates: [
      stub2("mb", "mb-1", 0.05),
      stub2("discogs", "1234", 0.08),
      stub2("mb", "mb-2", 0.1),
      stub2("mb", "mb-3", 0.15),
      stub2("mb", "mb-4", 0.2),
    ],
  });
});

test("beets 2.x: a plugin list without musicbrainz is not overridden", () => {
  const { code, doc } = runShim([release, "--json"], "beets-2.x", { STUB_BEETS_PLUGINS: "discogs" });
  expect(code).toBe(0);
  expect(doc).toEqual({ candidates: [stub2("discogs", "1234", 0.08)] });
});

test("beets 2.4-2.13 shape: tag_album(items) 3-tuple, plugins loaded first", () => {
  const { code, doc } = runShim([release, "--json"], "beets-2.x", { STUB_BEETS_API: "2.4" });
  expect(code).toBe(0);
  expect(doc.candidates.map((c: { release_id: string }) => c.release_id)).toEqual(["mb-1", "mb-2", "mb-3", "mb-4", "mb-5"]);
});

test("interactive plugin prompt gets EOF instead of blocking on an open stdin", async () => {
  const proc = Bun.spawn(["python3", "-S", SHIM, release, "--json"], {
    env: shimEnv("beets-2.x", { STUB_BEETS_PLUGINS: "prompt,musicbrainz" }),
    stdin: "pipe", // left open: a prompt reading the real stdin would hang
    stdout: "pipe",
    stderr: "pipe",
  });
  const timer = setTimeout(() => proc.kill(), 5000);
  const code = await proc.exited;
  clearTimeout(timer);
  const doc = JSON.parse(await new Response(proc.stdout).text());
  expect(code).toBe(0);
  expect(doc.candidates).toHaveLength(5);
});

test("beets missing: exit 3, beets_unavailable", () => {
  const { code, doc } = runShim([release, "--json"], null);
  expect(code).toBe(3);
  expect(doc).toEqual({ error: "beets_unavailable" });
});

test("bad invocation: exit 2", () => {
  const usage = { error: "usage: beets_identify.py <release_dir> --json" };
  for (const args of [["--json"], [join(tmp, "missing"), "--json"], [release, release, "--json"]]) {
    const { code, doc } = runShim(args, "beets-2.x");
    expect(code).toBe(2);
    expect(doc).toEqual(usage);
  }
  const { code, doc } = runShim([noAudio, "--json"], "beets-2.x");
  expect(code).toBe(2);
  expect(doc).toEqual({ error: "no_audio_files" });
});

test("CLI consumer parses the real shim's output (subprocessShim)", async () => {
  const prev = { PYTHONPATH: process.env.PYTHONPATH, PYTHONDONTWRITEBYTECODE: process.env.PYTHONDONTWRITEBYTECODE };
  process.env.PYTHONPATH = join(STUBS, "beets-2.x");
  process.env.PYTHONDONTWRITEBYTECODE = "1";
  try {
    const result = await subprocessShim(["python3", "-S", SHIM]).identify(release);
    expect(result).toEqual({
      candidates: [
        stub2("mb", "mb-1", 0.05),
        stub2("mb", "mb-2", 0.1),
        stub2("mb", "mb-3", 0.15),
        stub2("mb", "mb-4", 0.2),
        stub2("mb", "mb-5", 0.25),
      ],
    });
    process.env.PYTHONPATH = join(tmp, "no-beets-here");
    expect(await subprocessShim(["python3", "-S", SHIM]).identify(release)).toEqual({ error: "beets_unavailable" });
  } finally {
    for (const [k, v] of Object.entries(prev)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
});
