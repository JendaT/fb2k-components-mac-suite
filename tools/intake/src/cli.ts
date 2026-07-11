#!/usr/bin/env bun
// intake CLI entry. Command surface and conventions per
// docs/intake/intake-03-contract-spec.md; scan/resolve/status per doc 01.

import { cmdResolve, cmdScan, cmdStatus, cmdVersion, type CommandResult, type CommonOpts } from "./commands.ts";
import type { Envelope } from "./types.ts";

const USAGE = `usage: intake <command> [options]

commands:
  scan    [<income>|--all]        discover, unpack archives, then resolve
  resolve <path> [--force]        (re)detect release roots, write sidecars
  status  [--filter k=v ...]      sidecar inventory
  version                         {cli, schema, engine} versions

options:
  --json      machine output (single JSON envelope on stdout)
  --dry-run   compute without writing sidecars or unpacking
  --force     re-resolve dirs that already have sidecars
`;

function parseArgs(argv: string[]): { cmd: string; args: string[]; opts: CommonOpts & { all: boolean } } {
  const opts: CommonOpts & { all: boolean } = {
    json: false,
    dryRun: false,
    force: false,
    all: false,
    filters: {},
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
    } else if (!cmd) cmd = a;
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
