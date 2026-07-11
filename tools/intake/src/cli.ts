#!/usr/bin/env bun
// intake CLI entry. Command surface and conventions per
// docs/intake/intake-03-contract-spec.md; scan/resolve/status per doc 01.

import { cmdResolve, cmdScan, cmdStatus, cmdVersion, type CommandResult, type CommonOpts } from "./commands.ts";
import { cmdAssign, cmdBootstrap, cmdCollections, cmdIdentify } from "./commands-p2.ts";
import type { TreeSpec } from "./bootstrap.ts";
import type { Envelope } from "./types.ts";

const USAGE = `usage: intake <command> [options]

commands:
  scan       [<income>|--all]                    discover, unpack archives, then resolve
  resolve    <path> [--force]                    (re)detect release roots, write sidecars
  identify   <root...> [--force]                 establish what each release is
  assign     <root...> [--collection <name>] [--by user|engine]
                                                 rank genre-collection folders
  collections                                    genre map folder list (picker)
  bootstrap  --tree <path> [--prior-weight <w>] [--tree ...] [--out <dir>] [--force]
                                                 build genre/label maps from a tree
  status     [--filter k=v ...]                  sidecar inventory
  version                                        {cli, schema, engine} versions

options:
  --json      machine output (single JSON envelope on stdout)
  --dry-run   compute without writing anything
  --force     redo work that already has output (sidecars/identification/proposal/maps)
`;

interface AllOpts extends CommonOpts {
  all: boolean;
  collection: string | null;
  by: string | null;
  trees: TreeSpec[];
  out: string | null;
}

function parseArgs(argv: string[]): { cmd: string; args: string[]; opts: AllOpts } {
  const opts: AllOpts = {
    json: false,
    dryRun: false,
    force: false,
    all: false,
    filters: {},
    collection: null,
    by: null,
    trees: [],
    out: null,
  };
  const args: string[] = [];
  let cmd = "";
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--json") opts.json = true;
    else if (a === "--dry-run") opts.dryRun = true;
    else if (a === "--force") opts.force = true;
    else if (a === "--all") opts.all = true;
    else if (a === "--filter") {
      const kv = argv[++i];
      const eq = kv?.indexOf("=") ?? -1;
      if (kv && eq > 0) opts.filters[kv.slice(0, eq)] = kv.slice(eq + 1);
    } else if (a === "--collection") opts.collection = argv[++i] ?? null;
    else if (a === "--by") opts.by = argv[++i] ?? null;
    else if (a === "--tree") {
      const p = argv[++i];
      if (p) opts.trees.push({ path: p, weight: 1 });
    } else if (a === "--prior-weight") {
      const w = parseFloat(argv[++i] ?? "");
      const last = opts.trees.at(-1);
      if (last && !Number.isNaN(w)) last.weight = w;
    } else if (a === "--out") opts.out = argv[++i] ?? null;
    else if (!cmd) cmd = a;
    else args.push(a);
  }
  return { cmd, args, opts };
}

function printHuman(cmd: string, result: CommandResult): void {
  const { data, errors } = result;
  if (cmd === "status" && Array.isArray(data)) {
    for (const s of data as Array<Record<string, unknown>>) {
      const c = s.cluster as { albumartist: string | null; album: string | null };
      const flags = s.needs_review ? " [needs_review]" : "";
      console.log(`${s.id}  ${s.status}${flags}  ${c.albumartist ?? "?"} — ${c.album ?? "?"}  (${s.root_path})`);
    }
    console.log(`${(data as unknown[]).length} sidecar(s)`);
  } else if ((cmd === "resolve" || cmd === "scan") && data != null) {
    const blocks = cmd === "scan" ? (data as Array<Record<string, unknown>>) : [data as Record<string, unknown>];
    for (const b of blocks) {
      if (b.income) console.log(`income: ${b.income} (${b.path})`);
      for (const a of (b.archives as Array<Record<string, unknown>>) ?? [])
        console.log(`  archive ${a.action}: ${a.archive}`);
      for (const w of (b.written as Array<Record<string, unknown>>) ?? []) {
        const marks = [
          w.virtual ? "virtual" : null,
          w.singles ? "single" : null,
          w.needs_review ? "needs_review" : null,
        ].filter(Boolean).join(",");
        console.log(
          `  ${w.status} ${w.confidence} ${w.tier_eligible}${marks ? ` [${marks}]` : ""}  ` +
          `${w.albumartist ?? "?"} — ${w.album ?? "?"}  (${w.sidecar_path})`,
        );
      }
      for (const k of (b.kept as string[]) ?? []) console.log(`  kept: ${k}`);
      if (b.dry_run) console.log("  (dry run: nothing written)");
    }
  } else if (data != null) {
    console.log(JSON.stringify(data, null, 2));
  }
  for (const e of errors) console.error(`error ${e.code}: ${e.msg}${e.path ? ` (${e.path})` : ""}`);
}

async function main(): Promise<number> {
  const { cmd, args, opts } = parseArgs(process.argv.slice(2));
  let result: CommandResult;
  switch (cmd) {
    case "scan":
      result = await cmdScan(args, opts);
      break;
    case "resolve":
      result = await cmdResolve(args, opts);
      break;
    case "identify":
      result = await cmdIdentify(args, opts);
      break;
    case "assign":
      result = await cmdAssign(args, opts);
      break;
    case "collections":
      result = cmdCollections();
      break;
    case "bootstrap":
      result = cmdBootstrap(opts);
      break;
    case "status":
      result = cmdStatus(args, opts);
      break;
    case "version":
      result = cmdVersion();
      break;
    default:
      if (!opts.json) {
        console.error(USAGE);
        return 2;
      }
      result = { data: null, errors: [{ code: "E_BAD_ARGS", msg: `unknown command: ${cmd || "(none)"}`, path: null }], exitCode: 2 };
  }
  if (opts.json) {
    const envelope: Envelope = { ok: result.errors.length === 0, data: result.data, errors: result.errors };
    console.log(JSON.stringify(envelope));
  } else {
    printHuman(cmd, result);
  }
  return result.exitCode;
}

process.exit(await main());
