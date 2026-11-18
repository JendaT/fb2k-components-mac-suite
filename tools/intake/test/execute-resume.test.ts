// `execute <ids> --resume` resumes exactly the named roots. Before this fix it
// resumed every `placing` root in every income folder, so a second resume
// could revert an execute still running elsewhere. No-arg --resume keeps the
// all-placing behaviour; a named root that is not `placing` is refused.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { existsSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdScan, cmdStatus } from "../src/commands.ts";
import { cmdExecute } from "../src/commands-p3.ts";
import { readSidecar, serializeSidecar, type SidecarSummary } from "../src/sidecar.ts";
import type { Sidecar, Status } from "../src/types.ts";
import { setupCorpus, type Corpus } from "./helpers.ts";

const OPTS = {
  json: true, dryRun: false, force: false, filters: {},
  allResolved: false, batch: null, approved: false, resume: false,
  age: null, relocateDj: false,
};

let corpus: Corpus;
let roots: { id: string; file: string }[];

const read = (r: { file: string }): Sidecar => readSidecar(r.file)!;
function setStatus(r: { file: string }, status: Status): void {
  const doc = read(r);
  doc.status = status;
  writeFileSync(r.file, serializeSidecar(doc));
}

beforeAll(async () => {
  corpus = setupCorpus();
  writeFileSync(
    join(corpus.rules, "structure.yaml"),
    `journal:\n  path: ${join(corpus.dir, "journal", "intake-journal.ndjson")}\n`,
  );
  await cmdScan([], { ...OPTS, all: true });
  // Three plain (non-virtual) roots; the crafted `placing` sidecars carry no
  // proposal, so resume reverts them without touching any library path.
  const all = (cmdStatus([], OPTS).data as SidecarSummary[])
    .map((s) => ({ id: s.id, file: join(s.root_path, ".intake.json") }))
    .filter((r) => existsSync(r.file) && read(r).id === r.id);
  roots = all.slice(0, 3);
  expect(roots.length).toBe(3);
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("named --resume touches only the named placing root", async () => {
  const [a, b] = roots as [{ id: string; file: string }, { id: string; file: string }];
  setStatus(a, "placing");
  setStatus(b, "placing");

  const result = await cmdExecute([a.id], { ...OPTS, resume: true });
  expect(result.errors).toEqual([]);
  expect(result.exitCode).toBe(0);
  expect((result.data as { id: string; resumed: string }[]).map((r) => [r.id, r.resumed])).toEqual([
    [a.id, "reverted_to_approved"],
  ]);
  expect(read(a).status).toBe("approved");
  expect(read(b).status).toBe("placing");
});

test("named --resume on a root that is not placing is refused, not executed", async () => {
  const c = roots[2]!;
  const before = serializeSidecar(read(c));
  const result = await cmdExecute([c.id], { ...OPTS, resume: true });
  expect(result.exitCode).toBe(2);
  expect(result.data).toBeNull();
  expect(result.errors.map((e) => e.code)).toEqual(["E_BAD_STATUS"]);
  expect(result.errors[0]!.msg).toContain("cannot resume from status");
  expect(serializeSidecar(read(c))).toBe(before);
});

test("mixed named refs under --resume: partial exit 1", async () => {
  const [a, , c] = roots as { id: string; file: string }[];
  setStatus(a!, "placing");
  const result = await cmdExecute([a!.id, c!.id], { ...OPTS, resume: true });
  expect(result.exitCode).toBe(1);
  expect((result.data as { id: string }[]).map((r) => r.id)).toEqual([a!.id]);
  expect(result.errors.map((e) => e.code)).toEqual(["E_BAD_STATUS"]);
  expect(read(a!).status).toBe("approved");
});

test("no-arg --resume still resumes every placing root", async () => {
  const b = roots[1]!;
  expect(read(b).status).toBe("placing");
  const result = await cmdExecute([], { ...OPTS, resume: true });
  expect(result.errors).toEqual([]);
  expect((result.data as { id: string }[]).map((r) => r.id)).toEqual([b.id]);
  expect(read(b).status).toBe("approved");
});
