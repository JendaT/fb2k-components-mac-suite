#!/usr/bin/env bun
// intake CLI entry. Command surface and conventions per
// docs/intake/intake-03-contract-spec.md; scan/resolve/status per doc 01.

import {
  cmdIncome, cmdResolve, cmdScan, cmdStatus, cmdVersion, finish,
  type CommandResult, type CommonOpts, type IncomeRow, type ResolveData, type ScanBlock,
} from "./commands.ts";
import { RulesError } from "./config.ts";
import type { SidecarSummary } from "./sidecar.ts";
import { cmdAssign, cmdBootstrap, cmdCollections, cmdIdentify } from "./commands-p2.ts";
import { cmdApprove, cmdExecute, cmdGc, cmdPropose, cmdReject } from "./commands-p3.ts";
import type { TreeSpec } from "./bootstrap.ts";
import type { Envelope, JsonError } from "./types.ts";

const USAGE = `usage: intake <command> [options]

commands:
  scan       [<income>|--all]                    discover, unpack archives, then resolve
  resolve    <path> [--force]                    (re)detect release roots, write sidecars
  identify   <root...> [--force]                 establish what each release is
  assign     <root...> [--collection <name>] [--by user|engine]
                                                 rank genre-collection folders
  propose    <root...>|--all-resolved            identify+assign+naming, flip to proposed
  approve    <root...>|--batch <file>            proposed -> approved
  reject     <root...>|--batch <file> [--reason "<text>"]
                                                 new/resolved/proposed/approved -> rejected
                                                 (state change only; local files kept)
  execute    <root...>|--approved [--resume]     copy to target, verify, journal, place
  gc         <root...>|--all [--age <days>] [--relocate-dj]
                                                 re-verify + delete local originals of placed roots
  collections                                    genre map folder list (picker)
  income                                         income folders from income.yaml {name, path, exists}
  bootstrap  --tree <path> [--prior-weight <w>] [--tree ...] [--out <dir>] [--force]
                                                 build genre/label maps from a tree
  status     [--filter k=v ...]                  sidecar inventory; filters on different keys all match
                                                 keys: id status needs_review income_folder source_type
                                                 tier (alias tier_eligible) virtual singles albumartist
                                                 album root_path
  version                                        {cli, schema, engine, commands}

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
  allResolved: boolean;
  batch: string | null;
  reason: string | null;
  approved: boolean;
  resume: boolean;
  age: number | null;
  relocateDj: boolean;
}

/** Parse argv; `errors` holds malformed options (E_BAD_ARGS, reported before dispatch). */
function parseArgs(argv: string[]): { cmd: string; args: string[]; opts: AllOpts; errors: JsonError[] } {
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
    allResolved: false,
    batch: null,
    reason: null,
    approved: false,
    resume: false,
    age: null,
    relocateDj: false,
  };
  const args: string[] = [];
  const errors: JsonError[] = [];
  const badArgs = (msg: string) => errors.push({ code: "E_BAD_ARGS", msg, path: null });
  let cmd = "";
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]!;
    if (a === "--json") opts.json = true;
    else if (a === "--dry-run") opts.dryRun = true;
    else if (a === "--force") opts.force = true;
    else if (a === "--all") opts.all = true;
    else if (a === "--filter") {
      // Doc 03: one value per key. A malformed or repeated filter is an error,
      // never silently dropped or overwritten. An option after --filter is not
      // its argument (no filter key starts with "--"), so `--filter --json`
      // still answers with an envelope.
      const kv = argv[i + 1];
      if (kv === undefined || kv.startsWith("--")) {
        badArgs("--filter needs an argument: k=v");
        continue;
      }
      i++;
      const eq = kv.indexOf("=");
      if (eq <= 0) badArgs(`malformed --filter "${kv}": expected k=v`);
      else if (Object.hasOwn(opts.filters, kv.slice(0, eq))) badArgs(`--filter key given twice: ${kv.slice(0, eq)}`);
      else opts.filters[kv.slice(0, eq)] = kv.slice(eq + 1);
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
    else if (a === "--all-resolved") opts.allResolved = true;
    else if (a === "--batch") opts.batch = argv[++i] ?? null;
    else if (a === "--reason") opts.reason = argv[++i] ?? null;
    else if (a === "--approved") opts.approved = true;
    else if (a === "--resume") opts.resume = true;
    else if (a === "--age") {
      const days = parseFloat(argv[++i] ?? "");
      if (!Number.isNaN(days)) opts.age = days;
    } else if (a === "--relocate-dj") opts.relocateDj = true;
    else if (!cmd) cmd = a;
    else args.push(a);
  }
  return { cmd, args, opts, errors };
}

function printStatus(rows: SidecarSummary[]): void {
  for (const s of rows) {
    const flags = s.needs_review ? " [needs_review]" : "";
    console.log(
      `${s.id}  ${s.status}${flags}  ${s.cluster.albumartist ?? "?"} — ${s.cluster.album ?? "?"}  (${s.root_path})`,
    );
  }
  console.log(`${rows.length} sidecar(s)`);
}

function printBlocks(blocks: (ScanBlock | ResolveData)[]): void {
  for (const b of blocks) {
    if ("income" in b && b.income) console.log(`income: ${b.income} (${b.path})`);
    if ("archives" in b) {
      for (const a of b.archives) {
        const cp = a.code_page ? ` (names ${a.code_page.cp}, by ${a.code_page.by})` : "";
        console.log(`  archive ${a.action}: ${a.archive}${cp}`);
      }
    }
    for (const w of b.written) {
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
    for (const k of b.kept) console.log(`  kept: ${k}`);
    if (b.dry_run) console.log("  (dry run: nothing written)");
  }
}

function printHuman(cmd: string, result: CommandResult): void {
  const { data, errors } = result;
  if (cmd === "status" && Array.isArray(data)) {
    printStatus(data as SidecarSummary[]);
  } else if (cmd === "income" && Array.isArray(data)) {
    for (const i of data as IncomeRow[]) console.log(`${i.name}  ${i.path}${i.exists ? "" : "  (missing)"}`);
  } else if (cmd === "scan" && Array.isArray(data)) {
    printBlocks(data as ScanBlock[]);
  } else if (cmd === "resolve" && data != null) {
    printBlocks([data as ResolveData]);
  } else if (data != null) {
    console.log(JSON.stringify(data, null, 2));
  }
  // Human mode only: the --json envelope never carries notices.
  for (const n of result.notices ?? []) console.error(`notice: ${n}`);
  for (const e of errors) console.error(`error ${e.code}: ${e.msg}${e.path ? ` (${e.path})` : ""}`);
}

type Handler = (args: string[], opts: AllOpts) => CommandResult | Promise<CommandResult>;

/**
 * The dispatch table: every command this CLI accepts. `version` reports its
 * keys as `commands` (doc 03 Versioning), so the list cannot drift from what
 * is dispatched.
 */
const COMMANDS: Record<string, Handler> = {
  scan: (args, opts) => cmdScan(args, opts),
  resolve: (args, opts) => cmdResolve(args, opts),
  identify: (args, opts) => cmdIdentify(args, opts),
  assign: (args, opts) => cmdAssign(args, opts),
  propose: (args, opts) => cmdPropose(args, opts),
  approve: (args, opts) => cmdApprove(args, opts),
  reject: (args, opts) => cmdReject(args, opts),
  execute: (args, opts) => cmdExecute(args, opts),
  gc: (args, opts) => cmdGc(args, opts),
  status: (args, opts) => cmdStatus(args, opts),
  collections: () => cmdCollections(),
  income: () => cmdIncome(),
  version: () => cmdVersion(Object.keys(COMMANDS)),
  bootstrap: (_args, opts) => cmdBootstrap(opts),
};

async function main(): Promise<number> {
  const { cmd, args, opts, errors: argErrors } = parseArgs(process.argv.slice(2));
  let result: CommandResult;
  const handler = Object.hasOwn(COMMANDS, cmd) ? COMMANDS[cmd] : undefined;
  if (handler && argErrors.length > 0) {
    result = { data: null, errors: argErrors, exitCode: 2 };
  } else if (handler) {
    try {
      result = await handler(args, opts);
    } catch (e) {
      // A rules file the command loaded is unusable (config.ts RulesError).
      if (!(e instanceof RulesError)) throw e;
      result = finish([], [{ code: "E_BAD_RULES", msg: e.message, path: e.file }]);
    }
  } else {
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

/**
 * Doc 03: every `--json` invocation emits exactly one envelope. An uncaught
 * throw (an I/O error; a malformed rules file is E_BAD_RULES, in main) must
 * not leave stdout empty, so it becomes `E_INTERNAL` with exit 2. Nothing is
 * printed before main() returns, so there is no partial output to collide
 * with.
 */
async function run(): Promise<number> {
  try {
    return await main();
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    if (process.argv.slice(2).includes("--json")) {
      const envelope: Envelope = { ok: false, data: null, errors: [{ code: "E_INTERNAL", msg, path: null }] };
      console.log(JSON.stringify(envelope));
    } else {
      console.error(`error E_INTERNAL: ${msg}`);
    }
    return 2;
  }
}

process.exit(await run());
