// Read-only modes in an archive. The tools restore them: bsdtar keeps a RAR5
// entry's 0555 dir / 0444 file even with `--no-same-permissions`, and unzip
// restores a Unix-host zip entry's mode. A 0555 dir holding a file cannot be
// removed by its owner (rmSync fails with ENOTEMPTY), so a failed unpack used
// to leave its `.partial` behind and every later scan failed removing it; a
// good unpack left a tree whose files could not be tagged after a copy.
// unpackArchive makes the extracted tree owner-writable after every tool run
// and before removing a partial dir, clearing the user-immutable flag (uchg,
// an SMB share's DOS read-only attribute) as well: a uchg file in a leftover
// partial dir made every later unpack of that archive fail.
//
// Archives are built in the test (test/rarbuild.ts, test/zipbuild.ts). Every
// temp tree has its flags cleared and is made writable again before it is
// removed.

import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { unpackArchive } from "../src/archive.ts";
import { makeTreeWritable } from "./helpers.ts";
import { buildRar5 } from "./rarbuild.ts";
import { buildZip } from "./zipbuild.ts";

const BSDTAR = "/usr/bin/bsdtar";
const ALBUM = "Synthetic Artist - Read Only (2020)";
const TRACK = new TextEncoder().encode("synthetic payload\n".repeat(64));

let work: string;
let income: string;

/** Every dir and file under `dir` (dir included) whose mode lacks u+rwx (dirs) or u+rw (files). */
function notOwnerWritable(dir: string): string[] {
  const out: string[] = [];
  const walk = (p: string) => {
    const st = lstatSync(p);
    if (st.isDirectory()) {
      if ((st.mode & 0o700) !== 0o700) out.push(`${p} ${(st.mode & 0o777).toString(8)}`);
      for (const n of readdirSync(p)) walk(join(p, n));
    } else if (st.isFile() && (st.mode & 0o600) !== 0o600) {
      out.push(`${p} ${(st.mode & 0o777).toString(8)}`);
    }
  };
  walk(dir);
  return out;
}

beforeAll(() => {
  work = mkdtempSync(join(tmpdir(), "intake-readonly-"));
});

beforeEach(() => {
  income = join(work, "arc");
  mkdirSync(income, { recursive: true });
});

const clearFlags = (dir: string) => Bun.spawnSync(["/usr/bin/chflags", "-R", "nouchg,nouappnd", dir]);

afterEach(() => {
  clearFlags(income);
  makeTreeWritable(income);
  rmSync(income, { recursive: true, force: true });
});

afterAll(() => {
  clearFlags(work);
  makeTreeWritable(work);
  rmSync(work, { recursive: true, force: true });
});

const readOnlyRar = (badCrc: boolean) =>
  buildRar5([
    { name: ALBUM, dir: true, mode: 0o40555 },
    { name: `${ALBUM}/01 - Track.txt`, data: TRACK, mode: 0o100444, badCrc },
  ]);

describe.skipIf(!existsSync(BSDTAR))("rar with bsdtar", () => {
  test("RAR5 with a 0555 dir and a 0444 file unpacks to an owner-writable tree", async () => {
    const rar = join(income, `${ALBUM}.rar`);
    writeFileSync(rar, readOnlyRar(false));
    const r = await unpackArchive(rar, false);
    expect(r.error).toBeUndefined();
    expect(r.action).toBe("unpacked");
    const target = join(income, `${ALBUM}.unpacked`);
    expect(readFileSync(join(target, ALBUM, "01 - Track.txt"))).toEqual(Buffer.from(TRACK));
    expect(notOwnerWritable(target)).toEqual([]);
    expect(readdirSync(income).sort()).toEqual([`${ALBUM}.rar`, `${ALBUM}.unpacked`]);
  });

  test("the same layout with a bad CRC fails and leaves no .partial", async () => {
    const rar = join(income, `${ALBUM}.rar`);
    writeFileSync(rar, readOnlyRar(true));
    const r = await unpackArchive(rar, false);
    expect(r.action).toBe("failed");
    expect(r.error).toBe(`rar entry "${ALBUM}/01 - Track.txt": CRC32 mismatch`);
    expect(readdirSync(income)).toEqual([`${ALBUM}.rar`]);
  });

  test("a read-only .partial left by an earlier run is removed and the unpack succeeds", async () => {
    const rar = join(income, `${ALBUM}.rar`);
    writeFileSync(rar, readOnlyRar(false));
    const leftover = join(income, `${ALBUM}.unpacked.partial`, ALBUM);
    mkdirSync(leftover, { recursive: true });
    writeFileSync(join(leftover, "stale.txt"), "half written\n");
    chmodSync(join(leftover, "stale.txt"), 0o444);
    chmodSync(leftover, 0o555);

    const r = await unpackArchive(rar, false);
    expect(r.error).toBeUndefined();
    expect(r.action).toBe("unpacked");
    expect(readdirSync(income).sort()).toEqual([`${ALBUM}.rar`, `${ALBUM}.unpacked`]);
    expect(readdirSync(join(income, `${ALBUM}.unpacked`, ALBUM))).toEqual(["01 - Track.txt"]);
  });
});

test("a Unix-host zip with a 0555 dir and a 0444 file, through unzip, ends owner-writable", async () => {
  const zip = join(income, `${ALBUM}.zip`);
  writeFileSync(
    zip,
    buildZip([
      { name: `${ALBUM}/`, data: new Uint8Array(), host: 3, mode: 0o40555 },
      { name: `${ALBUM}/01 - Track.txt`, data: TRACK, host: 3, mode: 0o100444 },
    ]),
  );
  const r = await unpackArchive(zip, false);
  expect(r.error).toBeUndefined();
  expect(r.action).toBe("unpacked");
  const target = join(income, `${ALBUM}.unpacked`);
  expect(readFileSync(join(target, ALBUM, "01 - Track.txt"))).toEqual(Buffer.from(TRACK));
  expect(notOwnerWritable(target)).toEqual([]);
});

test("a .partial holding a uchg file, left by an earlier run, is removed and the unpack succeeds", async () => {
  const zip = join(income, `${ALBUM}.zip`);
  writeFileSync(zip, buildZip([{ name: `${ALBUM}/01 - Track.txt`, data: TRACK }]));
  const leftover = join(income, `${ALBUM}.unpacked.partial`, ALBUM);
  mkdirSync(leftover, { recursive: true });
  const stale = join(leftover, "stale.txt");
  writeFileSync(stale, "half written\n");
  try {
    const flag = Bun.spawnSync(["/usr/bin/chflags", "uchg", stale]);
    expect(flag.exitCode).toBe(0);

    const r = await unpackArchive(zip, false);
    expect(r.error).toBeUndefined();
    expect(r.action).toBe("unpacked");
    expect(readdirSync(income).sort()).toEqual([`${ALBUM}.unpacked`, `${ALBUM}.zip`]);
    expect(readdirSync(join(income, `${ALBUM}.unpacked`, ALBUM))).toEqual(["01 - Track.txt"]);
  } finally {
    clearFlags(income);
  }
});
