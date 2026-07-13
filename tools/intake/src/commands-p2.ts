// P2 commands: identify, assign, collections, bootstrap (doc 02).

import { existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { assign, buildTargetPath, type AssignInput, type AssignProviders } from "./assign.ts";
import { bootstrapTrees, type TreeSpec } from "./bootstrap.ts";
import type { CommandResult, CommonOpts } from "./commands.ts";
import { loadAssignConfig, loadIncome, rulesDir } from "./config.ts";
import { identifyRoot } from "./identify.ts";
import { buildProviders } from "./providers.ts";
import {
  appendOverride, loadGenreMap, loadLabelMap, loadStyleMap, recordFeedback,
  saveGenreMap, saveLabelMap,
} from "./rules.ts";
import { readSidecar, serializeSidecar } from "./sidecar.ts";
import type { JsonError, Proposal, Sidecar } from "./types.ts";
import { RESOLVER_VERSION } from "./types.ts";
import { isSidecarName, isoLocal, round2, walkDirs } from "./util.ts";

function fail(code: string, msg: string, path: string | null = null): CommandResult {
  return { data: null, errors: [{ code, msg, path }], exitCode: 2 };
}

export interface RootRef {
  dir: string;
  sidecarPath: string;
  sidecar: Sidecar;
}

/** Resolve root refs: an existing directory (all sidecars directly in it) or a sidecar id. */
export function rootsFromRefs(refs: string[], errors: JsonError[]): RootRef[] {
  const out: RootRef[] = [];
  for (const ref of refs) {
    if (existsSync(ref) && statSync(ref).isDirectory()) {
      const dir = resolve(ref);
      const names = readdirSync(dir).filter(isSidecarName).sort();
      if (names.length === 0) {
        errors.push({ code: "E_NOT_FOUND", msg: "no sidecar in directory (run resolve first)", path: dir });
        continue;
      }
      for (const n of names) {
        const sc = readSidecar(join(dir, n));
        if (sc) out.push({ dir, sidecarPath: join(dir, n), sidecar: sc });
        else errors.push({ code: "E_PARSE", msg: "unreadable sidecar", path: join(dir, n) });
      }
    } else if (/^itk_[0-9a-f]{8}$/.test(ref)) {
      let found = false;
      for (const inc of loadIncome()) {
        if (!existsSync(inc.path)) continue;
        for (const e of walkDirs(inc.path)) {
          for (const n of readdirSync(e.path).filter(isSidecarName)) {
            const sc = readSidecar(join(e.path, n));
            if (sc?.id === ref) {
              out.push({ dir: e.path, sidecarPath: join(e.path, n), sidecar: sc });
              found = true;
            }
          }
        }
      }
      if (!found) errors.push({ code: "E_NOT_FOUND", msg: `no sidecar with id ${ref}`, path: null });
    } else {
      errors.push({ code: "E_NOT_FOUND", msg: `not a directory or sidecar id: ${ref}`, path: null });
    }
  }
  return out;
}

export function writeSidecarWithEvent(root: RootRef, event: string, dryRun: boolean): void {
  root.sidecar.history.push({ ts: isoLocal(), event, by: `intake@${RESOLVER_VERSION}` });
  if (!dryRun) writeFileSync(root.sidecarPath, serializeSidecar(root.sidecar));
}

// ---- identify ---------------------------------------------------------------

export async function cmdIdentify(args: string[], opts: CommonOpts): Promise<CommandResult> {
  if (args.length === 0) return fail("E_BAD_ARGS", "usage: intake identify <root...>");
  const errors: JsonError[] = [];
  const roots = rootsFromRefs(args, errors);
  if (roots.length === 0) return { data: [], errors, exitCode: 2 };

  const providers = buildProviders();
  const cfg = loadAssignConfig();
  const data: unknown[] = [];
  for (const root of roots) {
    if (root.sidecar.identification && !opts.force) {
      data.push({ id: root.sidecar.id, root_path: root.dir, kept: true, status: root.sidecar.identification.status });
      continue;
    }
    const outcome = await identifyRoot(root.dir, root.sidecar, {
      discogs: providers.discogs,
      shim: providers.shim,
      acceptDistance: cfg.shim_accept_distance,
      now: () => new Date(),
    });
    root.sidecar.identification = outcome.identification;
    root.sidecar.cluster.needs_review = root.sidecar.cluster.needs_review || outcome.needs_review;
    writeSidecarWithEvent(root, "identified", opts.dryRun);
    data.push({
      id: root.sidecar.id,
      root_path: root.dir,
      kept: false,
      status: outcome.identification.status,
      artist: outcome.identification.artist,
      album: outcome.identification.album,
      needs_review: root.sidecar.cluster.needs_review,
      issues: outcome.issues,
    });
  }
  return { data, errors, exitCode: errors.length === 0 ? 0 : 1 };
}

// ---- assign -----------------------------------------------------------------

export interface AssignOpts extends CommonOpts {
  collection: string | null;
  by: string | null;
}

function assignInput(root: RootRef): AssignInput {
  const ident = root.sidecar.identification;
  return {
    artist: ident?.artist ?? root.sidecar.cluster.albumartist,
    album: ident?.album ?? root.sidecar.cluster.album,
    year: ident?.year ?? null,
    label: ident?.label ?? null,
    catno: ident?.catno ?? null,
    styles: ident?.styles ?? [],
    genres: ident?.genres ?? [],
    tier_eligible: root.sidecar.quality.tier_eligible,
    singles: root.sidecar.singles === true,
  };
}

export async function cmdAssign(args: string[], opts: AssignOpts): Promise<CommandResult> {
  if (args.length === 0) return fail("E_BAD_ARGS", "usage: intake assign <root...> [--collection <name>] [--by user|engine]");
  const rdir = rulesDir();
  if (!rdir) return fail("E_NO_RULES", "rules dir not found (INTAKE_RULES_DIR or ~/.config/intake/config.toml)");
  if (opts.collection && opts.by === "engine")
    return fail("E_BAD_ARGS", "--collection implies --by user");

  const errors: JsonError[] = [];
  const roots = rootsFromRefs(args, errors);
  if (roots.length === 0) return { data: [], errors, exitCode: 2 };

  const genre = loadGenreMap(rdir);
  const rules = { genre, labels: loadLabelMap(rdir), styles: loadStyleMap(rdir), config: loadAssignConfig() };
  const providers = buildProviders();
  const assignProviders: AssignProviders = {
    similar: providers.similar,
    aliases: providers.discogs ? (name) => providers.discogs!.artistAliases(name) : null,
  };

  const data: unknown[] = [];
  let genreDirty = false;
  for (const root of roots) {
    const input = assignInput(root);
    if (opts.collection) {
      // User override: authoritative pick + feedback loop (doc 02).
      const prior = root.sidecar.proposal;
      const { target_path, structure_slot } = buildTargetPath(input, opts.collection, rules.config);
      const proposal: Proposal = {
        engine_version: prior?.engine_version ?? "user",
        ranked: prior?.ranked ?? [{
          collection: opts.collection,
          score: 1,
          evidence: { artist_prior: 0, label_prior: 0, similar_vote: 0, style_hint: 0 },
        }],
        target_collection: opts.collection,
        confidence: 1,
        margin: 1,
        target_path,
        structure_slot,
        assigned_by: "user",
        alternates_shown: prior?.alternates_shown ?? false,
      };
      root.sidecar.proposal = proposal;
      writeSidecarWithEvent(root, "assigned", opts.dryRun);
      if (!opts.dryRun) {
        appendOverride(rdir, {
          ts: isoLocal(),
          sidecar_id: root.sidecar.id,
          artist: input.artist,
          collection: opts.collection,
          by: "user",
        });
        if (input.artist) {
          recordFeedback(genre, input.artist, opts.collection);
          genreDirty = true;
        }
      }
      data.push({
        id: root.sidecar.id, root_path: root.dir, target_collection: opts.collection,
        confidence: 1, margin: 1, target_path, assigned_by: "user", kept: false,
      });
      continue;
    }

    if (root.sidecar.proposal && !opts.force) {
      data.push({
        id: root.sidecar.id, root_path: root.dir, kept: true,
        target_collection: root.sidecar.proposal.target_collection,
      });
      continue;
    }
    const outcome = await assign(input, rules, assignProviders);
    for (const [alias, canonical] of Object.entries(outcome.learned_aliases)) {
      genre.aliases[alias] = canonical;
      genreDirty = true;
    }
    if (!outcome.proposal) {
      errors.push({ code: "E_NO_EVIDENCE", msg: `no assignment evidence for ${input.artist ?? "?"}`, path: root.dir });
      continue;
    }
    root.sidecar.proposal = outcome.proposal;
    root.sidecar.cluster.needs_review = root.sidecar.cluster.needs_review || outcome.needs_review;
    writeSidecarWithEvent(root, "assigned", opts.dryRun);
    data.push({
      id: root.sidecar.id,
      root_path: root.dir,
      target_collection: outcome.proposal.target_collection,
      confidence: outcome.proposal.confidence,
      margin: outcome.proposal.margin,
      target_path: outcome.proposal.target_path,
      assigned_by: "engine",
      short_circuited: outcome.short_circuited,
      needs_review: root.sidecar.cluster.needs_review,
      kept: false,
    });
  }
  if (genreDirty && !opts.dryRun) saveGenreMap(rdir, genre);
  const exitCode = errors.length === 0 ? 0 : data.length > 0 ? 1 : 2;
  return { data, errors, exitCode };
}

// ---- collections -------------------------------------------------------------

export function cmdCollections(): CommandResult {
  const rdir = rulesDir();
  if (!rdir) return fail("E_NO_RULES", "rules dir not found");
  const genre = loadGenreMap(rdir);
  const agg = new Map<string, { artists: number; releases: number }>();
  for (const source of [genre.artists, genre.feedback]) {
    for (const counts of Object.values(source)) {
      for (const [collection, n] of Object.entries(counts)) {
        const cur = agg.get(collection) ?? { artists: 0, releases: 0 };
        cur.artists += 1;
        cur.releases += n;
        agg.set(collection, cur);
      }
    }
  }
  const data = [...agg.entries()]
    .sort((a, b) => (a[0] < b[0] ? -1 : 1))
    .map(([collection, v]) => ({ collection, artists: v.artists, releases: round2(v.releases) }));
  return { data, errors: [], exitCode: 0 };
}

// ---- bootstrap ----------------------------------------------------------------

export interface BootstrapOpts extends CommonOpts {
  trees: TreeSpec[];
  out: string | null;
}

export function cmdBootstrap(opts: BootstrapOpts): CommandResult {
  if (opts.trees.length === 0)
    return fail("E_BAD_ARGS", "usage: intake bootstrap --tree <path> [--prior-weight <w>] [--tree ...] [--out <dir>]");
  for (const t of opts.trees) {
    if (!existsSync(t.path) || !statSync(t.path).isDirectory())
      return fail("E_NOT_FOUND", "tree is not a directory", t.path);
  }
  const out = opts.out ?? rulesDir();
  if (!out) return fail("E_NO_RULES", "no output dir (--out or rules dir)");

  const result = bootstrapTrees(opts.trees);
  const genrePath = join(out, "genre-map.yaml");
  const labelPath = join(out, "label-map.yaml");
  if (!opts.force && (existsSync(genrePath) || existsSync(labelPath)))
    return fail("E_EXISTS", "genre-map.yaml/label-map.yaml already exist (use --force to overwrite)", out);

  if (!opts.dryRun) {
    mkdirSync(out, { recursive: true });
    saveGenreMap(out, result.genre);
    saveLabelMap(out, result.labels);
    writeFileSync(join(out, "naming-variants-report.md"), result.report);
  }
  return {
    data: { out, dry_run: opts.dryRun, ...result.stats, trees: opts.trees.map((t) => ({ ...t, path: resolve(t.path) })) },
    errors: [],
    exitCode: 0,
  };
}
