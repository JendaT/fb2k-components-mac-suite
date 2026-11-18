// A placement must never land on a missing tier root, nor on a stale mount
// point: when a share is not mounted, /Volumes/<share> can still exist as an
// empty dir on the local disk. propose (which would read every collection as
// empty) and execute (which would write the library copy there) refuse such a
// root with E_NO_TARGET, per root; execute --resume leaves it `placing`.
//
// Nothing here touches the real /Volumes: the fake MountFs answers for
// /Volumes/fakeshare, and the tier roots are temp dirs.

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { basename, join } from "node:path";
import { cmdScan } from "../src/commands.ts";
import type { P2Deps } from "../src/commands-p2.ts";
import { cmdApprove, cmdExecute, cmdPropose } from "../src/commands-p3.ts";
import type { Providers } from "../src/providers.ts";
import { readSidecar, serializeSidecar } from "../src/sidecar.ts";
import { tierOf, tierRootProblem, type MountFs } from "../src/tierroot.ts";
import type { Sidecar, TierDef } from "../src/types.ts";
import { makeTierRoots, setupCorpus, type Corpus } from "./helpers.ts";

const SHARE = "/Volumes/fakeshare";

/** Fake filesystem facts: `map` gives canonical paths, `devs` st_dev values. */
function fakeFs(map: Record<string, string | null>, devs: Record<string, number>): MountFs {
  return {
    realDir: (p) => (p in map ? map[p]! : null),
    dev: (p) => devs[p] ?? null,
  };
}

/**
 * `root` (a real temp dir) answers as SHARE/<basename>; SHARE is a mount point
 * when `mounted` (own st_dev), a leftover dir on the local disk otherwise.
 * Any other path answers from its own existence, never from /Volumes.
 */
function fakeShare(root: string, mounted: boolean): MountFs {
  return {
    realDir: (p) => (p === root ? `${SHARE}/${basename(root)}` : existsSync(p) ? p : null),
    dev: (p) => (p === "/Volumes" ? 1 : p === SHARE ? (mounted ? 2 : 1) : null),
  };
}

const tier = (root: string): TierDef => ({ root, gate: "none", growth: "primary" });

describe("tierRootProblem / tierOf", () => {
  test("a missing root: not found, naming the tier and the path", () => {
    expect(tierRootProblem("music.hq", "/lib/music.hq", fakeFs({}, {}))).toBe(
      "tier music.hq root not found: /lib/music.hq",
    );
  });

  test("a root under /Volumes/<share> with the same st_dev as /Volumes: not a mount point", () => {
    const fs = fakeFs({ "/lib/music.hq": "/Volumes/share/music.hq" }, { "/Volumes": 7, "/Volumes/share": 7 });
    expect(tierRootProblem("music.hq", "/lib/music.hq", fs)).toBe(
      "tier music.hq root /lib/music.hq is not on a mounted volume (/Volumes/share is not a mount point)",
    );
  });

  test("a root on a mounted share (different st_dev): no problem", () => {
    const fs = fakeFs({ "/lib/music.hq": "/Volumes/share/music.hq" }, { "/Volumes": 7, "/Volumes/share": 8 });
    expect(tierRootProblem("music.hq", "/lib/music.hq", fs)).toBeNull();
  });

  test("an existing root outside /Volumes: no problem", () => {
    expect(tierRootProblem("music.hq", "/srv/music.hq", fakeFs({ "/srv/music.hq": "/srv/music.hq" }, {}))).toBeNull();
  });

  test("tierOf picks the longest matching root, on path boundaries", () => {
    const tiers = { music: tier("/lib/music"), "music.deep": tier("/lib/music/deep") };
    expect(tierOf("/lib/music/deep/A/B", tiers)).toEqual({ name: "music.deep", root: "/lib/music/deep" });
    expect(tierOf("/lib/music/A/B", tiers)).toEqual({ name: "music", root: "/lib/music" });
    expect(tierOf("/lib/musicx/A", tiers)).toBeNull();
    expect(tierOf("/elsewhere/A", tiers)).toBeNull();
  });
});

describe("propose and execute refuse an unusable tier root", () => {
  const OPTS = {
    json: true, dryRun: false, force: false, filters: {}, all: false,
    allResolved: false, batch: null, approved: false, resume: false,
    age: null, relocateDj: false,
  };
  const OFFLINE: P2Deps = { providers: { discogs: null, similar: null, shim: null } as Providers };

  let corpus: Corpus;
  let library: string;
  let hq: string;
  let uhq: string;
  let journalPath: string;

  const POLLEN = () => join(corpus.income, "downloads", "Aes Dana [2012] Pollen (Ultimae Records; inre042)"); // music.hq
  const SYNC24 = () => join(corpus.income, "downloads", "Sync24 [2024] Omnimotion Remixed"); // music.uhq
  const MOVEMENTS = () => join(corpus.income, "slsk", "Solar Fields", "Solar Fields - Movements (2009)"); // music.hq
  const sc = (dir: string): Sidecar => readSidecar(join(dir, ".intake.json"))!;

  beforeAll(async () => {
    corpus = setupCorpus();
    delete process.env.DISCOGS_TOKEN;
    delete process.env.LASTFM_API_KEY;
    delete process.env.INTAKE_BEETS_SHIM;
    library = join(corpus.dir, "library");
    hq = join(library, "music.hq");
    uhq = join(library, "music.uhq");
    journalPath = join(corpus.dir, "journal", "intake-journal.ndjson");
    writeFileSync(
      join(corpus.rules, "structure.yaml"),
      [
        "tiers:",
        `  music.uhq: { root: ${uhq}, gate: hires, growth: active }`,
        `  music.hq: { root: ${hq}, gate: lossless-first, growth: primary }`,
        "journal:",
        `  path: ${journalPath}`,
        "",
      ].join("\n"),
    );
    makeTierRoots(corpus.rules);
    await cmdScan([], { ...OPTS, all: true });
  });

  afterAll(() => {
    rmSync(corpus.dir, { recursive: true, force: true });
  });

  test("propose: the root on an unmounted tier is refused, the other proposed (exit 1)", async () => {
    const result = await cmdPropose([POLLEN(), SYNC24()], OPTS, { ...OFFLINE, mountFs: fakeShare(uhq, false) });
    expect(result.exitCode).toBe(1);
    expect(result.errors.map((e) => [e.code, e.path])).toEqual([["E_NO_TARGET", SYNC24()]]);
    expect(result.errors[0]!.msg).toBe(
      `cannot propose: tier music.uhq root ${uhq} is not on a mounted volume (${SHARE} is not a mount point)`,
    );
    const rows = result.data as { id: string; status: string; target_path: string }[];
    expect(rows.map((r) => [r.id, r.status])).toEqual([[sc(POLLEN()).id, "proposed"]]);
    expect(rows[0]!.target_path.startsWith(hq + "/")).toBe(true);
    expect(sc(POLLEN()).status).toBe("proposed");
    expect(sc(SYNC24()).status).toBe("resolved");
  });

  test("execute: a missing tier root refuses the root, writes nothing, stays approved", async () => {
    expect(cmdApprove([POLLEN()], OPTS).errors).toEqual([]);
    rmSync(hq, { recursive: true });
    try {
      const result = await cmdExecute([POLLEN()], OPTS);
      expect(result.exitCode).toBe(2);
      expect(result.errors).toEqual([
        { code: "E_NO_TARGET", msg: `cannot execute: tier music.hq root not found: ${hq}`, path: POLLEN() },
      ]);
      expect(existsSync(hq)).toBe(false); // no target, no temp dir, no parents
      expect(existsSync(journalPath)).toBe(false);
      expect(sc(POLLEN()).status).toBe("approved");
    } finally {
      mkdirSync(hq, { recursive: true });
    }
  });

  test("execute: a tier root on an unmounted share (stale dir) is refused", async () => {
    const result = await cmdExecute([POLLEN()], OPTS, { mountFs: fakeShare(hq, false) });
    expect(result.exitCode).toBe(2);
    expect(result.errors).toEqual([{
      code: "E_NO_TARGET",
      msg: `cannot execute: tier music.hq root ${hq} is not on a mounted volume (${SHARE} is not a mount point)`,
      path: POLLEN(),
    }]);
    expect(readdirSync(hq)).toEqual([]);
    expect(existsSync(journalPath)).toBe(false);
    expect(sc(POLLEN()).status).toBe("approved");
  });

  test("execute: the same root on a mounted share executes", async () => {
    const target = sc(POLLEN()).proposal!.target_path!;
    const result = await cmdExecute([POLLEN()], OPTS, { mountFs: fakeShare(hq, true) });
    expect(result.errors).toEqual([]);
    expect(sc(POLLEN()).status).toBe("placed");
    expect(sc(POLLEN()).placed!.target_path).toBe(target);
    expect(target.startsWith(hq + "/")).toBe(true);
    expect(existsSync(target)).toBe(true);
  });

  test("execute --resume: a placing root on an unmounted tier stays placing", async () => {
    expect((await cmdPropose([MOVEMENTS()], OPTS, OFFLINE)).errors).toEqual([]);
    expect(cmdApprove([MOVEMENTS()], OPTS).errors).toEqual([]);
    // Interrupted execute: `placing`, and no copy is visible (the share is gone).
    const file = join(MOVEMENTS(), ".intake.json");
    const doc = sc(MOVEMENTS());
    doc.status = "placing";
    writeFileSync(file, serializeSidecar(doc));
    expect(doc.proposal!.target_path!.startsWith(hq + "/")).toBe(true);

    const refused = await cmdExecute([MOVEMENTS()], { ...OPTS, resume: true }, { mountFs: fakeShare(hq, false) });
    expect(refused.exitCode).toBe(2);
    expect(refused.errors).toEqual([{
      code: "E_NO_TARGET",
      msg: `cannot resume: tier music.hq root ${hq} is not on a mounted volume (${SHARE} is not a mount point)`,
      path: MOVEMENTS(),
    }]);
    expect(sc(MOVEMENTS()).status).toBe("placing");

    // Mounted again: resume runs (no copy on the share, so it reverts).
    const resumed = await cmdExecute([MOVEMENTS()], { ...OPTS, resume: true }, { mountFs: fakeShare(hq, true) });
    expect(resumed.errors).toEqual([]);
    expect(sc(MOVEMENTS()).status).toBe("approved");
  });
});
