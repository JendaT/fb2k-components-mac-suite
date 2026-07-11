import { existsSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { unpackArchive, type UnpackResult } from "./archive.ts";
import { incomeFor, loadConfig, loadIncome, rulesDir } from "./config.ts";
import { Resolver, type ResolveContext } from "./resolver.ts";
import { readSidecar, summarize, writeRoot, type SidecarSummary } from "./sidecar.ts";
import type { IncomeFolder, JsonError, Sidecar } from "./types.ts";
import { ARCHIVE_EXTS, ext, isSidecarName, walkDirs } from "./util.ts";

export interface CommandResult {
  data: unknown;
  errors: JsonError[];
  exitCode: 0 | 1 | 2;
}

export interface CommonOpts {
  json: boolean;
  dryRun: boolean;
  force: boolean;
  filters: Record<string, string>;
}

function fail(code: string, msg: string, path: string | null = null): CommandResult {
  return { data: null, errors: [{ code, msg, path }], exitCode: 2 };
}

interface WrittenRoot {
  id: string;
  root_path: string;
  sidecar_path: string;
  status: string;
  needs_review: boolean;
  confidence: number;
  tier_eligible: string;
  virtual: boolean;
  singles: boolean;
  albumartist: string | null;
  album: string | null;
}

async function resolveInto(
  target: string,
  income: IncomeFolder | null,
  opts: CommonOpts,
): Promise<{ written: WrittenRoot[]; kept: string[] }> {
  const ctx: ResolveContext = {
    config: loadConfig(),
    income: income ? { name: income.name, source_type: income.source_type, root: income.path } : null,
    force: opts.force,
    now: () => new Date(),
  };
  const { roots, kept } = await new Resolver(ctx).resolveTree(target);
  const written: WrittenRoot[] = [];
  for (const root of roots) {
    let sidecarPath = join(root.dir, root.sidecarName);
    if (!opts.dryRun) sidecarPath = writeRoot(root).path;
    const s = root.sidecar;
    written.push({
      id: s.id,
      root_path: root.dir,
      sidecar_path: sidecarPath,
      status: s.status,
      needs_review: s.cluster.needs_review,
      confidence: s.cluster.confidence,
      tier_eligible: s.quality.tier_eligible,
      virtual: s.virtual,
      singles: s.singles === true,
      albumartist: s.cluster.albumartist,
      album: s.cluster.album,
    });
  }
  return { written, kept };
}

export async function cmdResolve(args: string[], opts: CommonOpts): Promise<CommandResult> {
  const targetArg = args[0];
  if (!targetArg) return fail("E_BAD_ARGS", "usage: intake resolve <path> [--force]");
  const target = resolve(targetArg);
  if (!existsSync(target) || !statSync(target).isDirectory())
    return fail("E_NOT_FOUND", "not a directory", target);
  const income = incomeFor(target, loadIncome());
  const { written, kept } = await resolveInto(target, income, opts);
  return {
    data: { target, dry_run: opts.dryRun, written, kept },
    errors: [],
    exitCode: 0,
  };
}

function findArchives(root: string): string[] {
  const out: string[] = [];
  for (const e of walkDirs(root)) {
    if (e.path.endsWith(".unpacked") || e.path.includes(".unpacked/")) continue;
    for (const n of e.otherFiles) if (ARCHIVE_EXTS.has(ext(n))) out.push(join(e.path, n));
  }
  return out.sort();
}

export async function cmdScan(args: string[], opts: CommonOpts & { all: boolean }): Promise<CommandResult> {
  const income = loadIncome();
  if (income.length === 0)
    return fail("E_NO_RULES", `no income folders configured (rules dir: ${rulesDir() ?? "not found"})`);

  let targets: IncomeFolder[];
  if (opts.all) {
    targets = income;
  } else {
    const sel = args[0];
    if (!sel) return fail("E_BAD_ARGS", "usage: intake scan <income>|--all");
    const match = income.find((i) => i.name === sel || resolve(i.path) === resolve(sel));
    if (!match) return fail("E_NOT_FOUND", `unknown income folder: ${sel}`);
    targets = [match];
  }

  const errors: JsonError[] = [];
  const data: unknown[] = [];
  for (const inc of targets) {
    if (!existsSync(inc.path)) {
      errors.push({ code: "E_NOT_FOUND", msg: `income path missing: ${inc.name}`, path: inc.path });
      continue;
    }
    const archives: UnpackResult[] = [];
    for (const arc of findArchives(inc.path)) {
      const r = await unpackArchive(arc, opts.dryRun);
      archives.push(r);
      if (r.action === "failed")
        errors.push({ code: "E_ARCHIVE", msg: r.error ?? "unpack failed", path: r.archive });
      if (r.action === "tool_missing")
        errors.push({ code: "E_ARCHIVE_TOOL", msg: r.error ?? "tool missing", path: r.archive });
    }
    const { written, kept } = await resolveInto(inc.path, inc, opts);
    data.push({
      income: inc.name,
      path: inc.path,
      dry_run: opts.dryRun,
      archives: archives.map((a) => ({ archive: a.archive, target: a.target, action: a.action })),
      written,
      kept,
    });
  }
  const exitCode = errors.length === 0 ? 0 : data.length > 0 ? 1 : 2;
  return { data, errors, exitCode };
}

function sidecarField(s: Sidecar, dir: string, key: string): string {
  switch (key) {
    case "status": return s.status;
    case "needs_review": return String(s.cluster.needs_review);
    case "income_folder": return s.source.income_folder ?? "";
    case "source_type": return s.source.source_type;
    case "tier": case "tier_eligible": return s.quality.tier_eligible;
    case "virtual": return String(s.virtual);
    case "singles": return String(s.singles === true);
    case "albumartist": return s.cluster.albumartist ?? "";
    case "album": return s.cluster.album ?? "";
    case "root_path": return dir;
    default: return "";
  }
}

export function cmdStatus(_args: string[], opts: CommonOpts): CommandResult {
  const income = loadIncome();
  if (income.length === 0)
    return fail("E_NO_RULES", `no income folders configured (rules dir: ${rulesDir() ?? "not found"})`);

  const summaries: (SidecarSummary & { _sort: string })[] = [];
  const errors: JsonError[] = [];
  for (const inc of income) {
    if (!existsSync(inc.path)) continue;
    for (const e of walkDirs(inc.path)) {
      let names: string[];
      try {
        names = readdirSync(e.path);
      } catch {
        continue;
      }
      for (const n of names.filter(isSidecarName).sort()) {
        const p = join(e.path, n);
        const sc = readSidecar(p);
        if (!sc) {
          errors.push({ code: "E_PARSE", msg: "unreadable sidecar", path: p });
          continue;
        }
        const match = Object.entries(opts.filters).every(([k, v]) => sidecarField(sc, e.path, k) === v);
        if (match) summaries.push({ ...summarize(sc, e.path), _sort: p });
      }
    }
  }
  summaries.sort((a, b) => a._sort.localeCompare(b._sort));
  const data = summaries.map(({ _sort, ...rest }) => rest);
  return { data, errors, exitCode: errors.length === 0 ? 0 : 1 };
}

export function cmdVersion(): CommandResult {
  return { data: { cli: "0.1.0", schema: 1, engine: null }, errors: [], exitCode: 0 };
}
