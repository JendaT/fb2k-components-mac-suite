// Default beets shim command: the interpreter comes from the shebang of the
// `beet` found on PATH. Fake `beet` files in temp dirs on a temp PATH only;
// nothing here runs beets or the shim.

import { afterAll, beforeAll, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { shimCommand } from "../src/providers.ts";

const SHIM = join(import.meta.dir, "..", "shim", "beets_identify.py");

let tmp: string;
let n = 0;

beforeAll(() => {
  tmp = mkdtempSync(join(tmpdir(), "intake-shimcmd-"));
});

afterAll(() => {
  rmSync(tmp, { recursive: true, force: true });
});

/** A fresh dir holding one `beet` with the given content and mode; returns the dir. */
function fakeBeet(content: string | Uint8Array, mode = 0o755): string {
  const dir = join(tmp, `bin${n++}`);
  mkdirSync(dir);
  writeFileSync(join(dir, "beet"), content);
  chmodSync(join(dir, "beet"), mode);
  return dir;
}

const commandFor = (content: string | Uint8Array, mode?: number) =>
  shimCommand({ PATH: fakeBeet(content, mode) });

test("absolute Python shebang: that interpreter runs the shim", () => {
  const homebrew = "/opt/homebrew/opt/python@3.10/bin/python3.10";
  expect(commandFor(`#!${homebrew}\n# -*- coding: utf-8 -*-\nimport re\n`)).toEqual([homebrew, SHIM]);
  expect(commandFor("#!/usr/bin/python3\n")).toEqual(["/usr/bin/python3", SHIM]);
  // pipx / uv venvs name plain `python`.
  expect(commandFor("#!/Users/u/.local/pipx/venvs/beets/bin/python\n")).toEqual([
    "/Users/u/.local/pipx/venvs/beets/bin/python", SHIM,
  ]);
  // Interpreter flags are dropped; a CRLF line ending is not part of the path.
  expect(commandFor("#!/usr/local/bin/python3.12 -I\n")).toEqual(["/usr/local/bin/python3.12", SHIM]);
  expect(commandFor("#!/usr/bin/python3\r\nimport sys\r\n")).toEqual(["/usr/bin/python3", SHIM]);
});

test("env shebang: the bare name, resolved on PATH at spawn", () => {
  expect(commandFor("#!/usr/bin/env python3.10\n")).toEqual(["python3.10", SHIM]);
  expect(commandFor("#!/usr/bin/env python3\n")).toEqual(["python3", SHIM]);
  expect(commandFor("#!/usr/bin/env -S python3.11 -u\n")).toEqual(["python3.11", SHIM]);
});

test("no usable Python shebang: python3 as before", () => {
  // A binary (Mach-O magic, no line break), a shell wrapper, an env shebang
  // naming something else, a relative interpreter, a file with no shebang.
  const machO = new Uint8Array(4096);
  machO.set([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]);
  for (const content of [
    machO,
    '#!/bin/bash\nexec "/opt/homebrew/Cellar/beets/2.3.0/libexec/bin/beet" "$@"\n',
    "#!/usr/bin/env bash\n",
    "#!/usr/bin/env -S\n",
    "#!python3\n",
    "import beets\n",
    "",
  ]) {
    expect(commandFor(content)).toEqual(["python3", SHIM]);
  }
});

test.skipIf(process.getuid?.() === 0)("unreadable beet (execute-only): python3", () => {
  expect(commandFor("#!/usr/bin/python3.10\n", 0o111)).toEqual(["python3", SHIM]);
});

test("no beet on PATH, or no PATH: python3", () => {
  const empty = join(tmp, "empty");
  mkdirSync(empty);
  expect(shimCommand({ PATH: empty })).toEqual(["python3", SHIM]);
  expect(shimCommand({})).toEqual(["python3", SHIM]);
});

test("the first beet on PATH is the one read", () => {
  const first = fakeBeet("#!/first/python3.10\n");
  const second = fakeBeet("#!/second/python3.9\n");
  expect(shimCommand({ PATH: `${join(tmp, "nowhere")}:${first}:${second}` })).toEqual(["/first/python3.10", SHIM]);
});

test("INTAKE_BEETS_SHIM still wins over beet's interpreter", () => {
  const dir = fakeBeet("#!/opt/homebrew/opt/python@3.10/bin/python3.10\n");
  expect(shimCommand({ PATH: dir, INTAKE_BEETS_SHIM: "/x/python3.9  /y/shim.py" })).toEqual(["/x/python3.9", "/y/shim.py"]);
});

test("the file read is injectable", () => {
  const dir = fakeBeet("#!/on/disk/python3\n");
  const seen: string[] = [];
  const cmd = shimCommand({ PATH: dir }, (file) => {
    seen.push(file);
    return "#!/injected/python3.13";
  });
  expect(cmd).toEqual(["/injected/python3.13", SHIM]);
  expect(seen).toEqual([join(dir, "beet")]);
  expect(shimCommand({ PATH: dir }, () => null)).toEqual(["python3", SHIM]);
});
