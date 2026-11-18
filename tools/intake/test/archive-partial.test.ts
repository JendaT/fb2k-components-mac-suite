// Archive extraction is published only on success: the tool writes into the
// sibling `<name>.unpacked.partial/`, which becomes `<name>.unpacked/` only
// after a clean exit. A failed extraction leaves neither dir (so the next scan
// retries), and a leftover partial dir from a crashed run is never resolved.
// Archives are built in the test (test/zipbuild.ts); the corrupt one carries a
// member with a wrong CRC, so unzip writes files and then exits non-zero.

import { afterAll, beforeAll, beforeEach, expect, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { unpackArchive } from "../src/archive.ts";
import { cmdResolve, cmdScan } from "../src/commands.ts";
import { collectSidecars, FIXTURES, setupCorpus, type Corpus } from "./helpers.ts";
import { buildZip } from "./zipbuild.ts";

const SRC_ALBUM = join(FIXTURES, "income", "downloads", "Sync24 [2024] Omnimotion Remixed");
const TRACKS = ["01 - Omnimotion.flac", "02 - Dance of the Droids.flac", "03 - Cargo.flac"];
const ALBUM = "Synthetic Artist - Partial Test (2020)";

let corpus: Corpus;
let income: string; // income folder "arc", holding only what each test puts there
const opts = { json: true, dryRun: false, force: false, all: false, filters: {} };

function albumZip(corruptLast: boolean): Uint8Array {
  return buildZip(
    TRACKS.map((t, i) => ({
      name: `${ALBUM}/${t}`,
      data: new Uint8Array(readFileSync(join(SRC_ALBUM, t))),
      badCrc: corruptLast && i === TRACKS.length - 1,
    })),
  );
}

beforeAll(() => {
  corpus = setupCorpus();
  income = join(corpus.dir, "arc");
  writeFileSync(
    join(corpus.rules, "income.yaml"),
    ["income:", "  - name: arc", `    path: ${income}`, "    source_type: web", ""].join("\n"),
  );
});

beforeEach(() => {
  rmSync(income, { recursive: true, force: true });
  mkdirSync(income, { recursive: true });
});

afterAll(() => {
  rmSync(corpus.dir, { recursive: true, force: true });
});

test("unpackArchive: a failing extraction publishes nothing and removes its partial dir", async () => {
  const zip = join(income, `${ALBUM}.zip`);
  writeFileSync(zip, albumZip(true));
  const r = await unpackArchive(zip, false);
  expect(r.action).toBe("failed");
  expect(r.error).toBeTruthy();
  expect(readdirSync(income)).toEqual([`${ALBUM}.zip`]);
});

test("scan: failed unpack is E_ARCHIVE with no .unpacked, no .partial, no sidecar; the next scan retries", async () => {
  const zip = join(income, `${ALBUM}.zip`);
  writeFileSync(zip, albumZip(true));

  const first = await cmdScan(["arc"], opts);
  expect(first.errors.map((e) => [e.code, e.path])).toEqual([["E_ARCHIVE", zip]]);
  const block = (first.data as { archives: { action: string }[] }[])[0]!;
  expect(block.archives.map((a) => a.action)).toEqual(["failed"]);
  expect(readdirSync(income)).toEqual([`${ALBUM}.zip`]);
  expect(collectSidecars(income)).toEqual([]);

  // Same archive name, now intact: the scan retries instead of reporting
  // already_unpacked, and the result resolves.
  writeFileSync(zip, albumZip(false));
  const second = await cmdScan(["arc"], opts);
  expect(second.errors).toEqual([]);
  const block2 = (second.data as { archives: { action: string }[]; written: { root_path: string }[] }[])[0]!;
  expect(block2.archives.map((a) => a.action)).toEqual(["unpacked"]);
  expect(block2.written.map((w) => w.root_path)).toEqual([join(income, `${ALBUM}.unpacked`, ALBUM)]);
  expect(readdirSync(join(income, `${ALBUM}.unpacked`, ALBUM)).sort()).toEqual([".intake.json", ...TRACKS]);
});

test("a leftover .partial holding audio is never resolved, and scan removes it before retrying", async () => {
  const zip = join(income, `${ALBUM}.zip`);
  writeFileSync(zip, albumZip(false));
  const leftover = join(income, `${ALBUM}.unpacked.partial`, ALBUM);
  mkdirSync(leftover, { recursive: true });
  for (const t of TRACKS.slice(0, 2)) copyFileSync(join(SRC_ALBUM, t), join(leftover, t));

  // resolve never unpacks: the leftover stays, and is not a root.
  const resolved = await cmdResolve([income], { json: true, dryRun: false, force: false, filters: {} });
  expect(resolved.errors).toEqual([]);
  expect(resolved.data?.written).toEqual([]);
  expect(collectSidecars(income)).toEqual([]);
  // Not even when it is the target itself.
  const direct = await cmdResolve([leftover], { json: true, dryRun: false, force: false, filters: {} });
  expect(direct.data?.written).toEqual([]);
  expect(collectSidecars(income)).toEqual([]);

  const scanned = await cmdScan(["arc"], opts);
  expect(scanned.errors).toEqual([]);
  const block = (scanned.data as { archives: { action: string }[]; written: { root_path: string }[] }[])[0]!;
  expect(block.archives.map((a) => a.action)).toEqual(["unpacked"]);
  expect(existsSync(join(income, `${ALBUM}.unpacked.partial`))).toBe(false);
  expect(block.written.map((w) => w.root_path)).toEqual([join(income, `${ALBUM}.unpacked`, ALBUM)]);
  expect(readdirSync(join(income, `${ALBUM}.unpacked`, ALBUM)).sort()).toEqual([".intake.json", ...TRACKS]);
});

test("a successful unpack lands in .unpacked, leaves no .partial, and a rescan keeps it", async () => {
  const zip = join(income, `${ALBUM}.zip`);
  writeFileSync(zip, albumZip(false));
  const r = await unpackArchive(zip, false);
  expect(r).toEqual({ archive: zip, target: join(income, `${ALBUM}.unpacked`), action: "unpacked" });
  expect(readdirSync(income).sort()).toEqual([`${ALBUM}.unpacked`, `${ALBUM}.zip`]);
  expect(readdirSync(join(income, `${ALBUM}.unpacked`, ALBUM)).sort()).toEqual(TRACKS);

  const scanned = await cmdScan(["arc"], opts);
  expect(scanned.errors).toEqual([]);
  const block = (scanned.data as { archives: { action: string }[]; written: { root_path: string }[] }[])[0]!;
  expect(block.archives.map((a) => a.action)).toEqual(["already_unpacked"]);
  expect(block.written.map((w) => w.root_path)).toEqual([join(income, `${ALBUM}.unpacked`, ALBUM)]);
});
