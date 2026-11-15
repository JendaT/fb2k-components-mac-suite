// P2 commands: identify, assign, collections, bootstrap (doc 02).

import { existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { assign, buildTargetPath, type AssignInput, type AssignProviders } from "./assign.ts";
import { bootstrapTrees, type TreeSpec } from "./bootstrap.ts";
import { finish, type CommandResult, type CommonOpts } from "./commands.ts";
import { loadAssignConfig, loadIncome, rulesDir } from "./config.ts";
import { identifyRoot } from "./identify.ts";
import type { LibraryProbe } from "./layout.ts";
import type { MountFs } from "./tierroot.ts";
import { buildProviders, type Providers } from "./providers.ts";
import {
  appendOverride, loadGenreMap, loadLabelMap, loadStyleMap, recordFeedback,
  saveGenreMap, saveLabelMap,
} from "./rules.ts";
import { readSidecar, serializeSidecar } from "./sidecar.ts";
import type { AssignConfig, HistoryEvent, JsonError, Proposal, Sidecar } from "./types.ts";
import { CLI_VERSION, PRE_LIBRARY_STATUSES } from "./types.ts";
import { isSidecarName, isVariousArtists, isoLocal, round2, walkDirs } from "./util.ts";

function fail(code: string, msg: string, path: string | null = null): CommandResult<null> {
  return { data: null, errors: [{ code, msg, path }], exitCode: 2 };
}

export interface RootRef {
  dir: string;
  sidecarPath: string;
  sidecar: Sidecar;
}

const SIDECAR_ID_RE = /^itk_[0-9a-f]{8}$/;

/**
 * One pass over the income tree collecting the sidecars whose id was asked for.
 * Previously each id ref triggered its own full walk, parsing every sidecar in
 * income again — so `approve --batch` of N ids did N walks. A ref list may
 * legitimately name several ids in the same dir (virtual roots), hence a list
 * per id rather than a single entry.
 */
function indexById(ids: Set<string>): Map<string, RootRef[]> {
  const index = new Map<string, RootRef[]>();
  for (const inc of loadIncome()) {
    if (!existsSync(inc.path)) continue;
    for (const e of walkDirs(inc.path)) {
      for (const n of readdirSync(e.path).filter(isSidecarName)) {
        const sc = readSidecar(join(e.path, n));
        if (!sc || !ids.has(sc.id)) continue;
        const list = index.get(sc.id) ?? [];
        list.push({ dir: e.path, sidecarPath: join(e.path, n), sidecar: sc });
        index.set(sc.id, list);
      }
    }
  }
  return index;
}

/** Resolve root refs: an existing directory (all sidecars directly in it) or a sidecar id. */
export function rootsFromRefs(refs: string[], errors: JsonError[]): RootRef[] {
  const out: RootRef[] = [];
  const wantedIds = new Set(refs.filter((r) => SIDECAR_ID_RE.test(r)));
  const byId = wantedIds.size > 0 ? indexById(wantedIds) : new Map<string, RootRef[]>();
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
    } else if (SIDECAR_ID_RE.test(ref)) {
      const hits = byId.get(ref) ?? [];
      if (hits.length === 0) errors.push({ code: "E_NOT_FOUND", msg: `no sidecar with id ${ref}`, path: null });
      out.push(...hits);
    } else {
      errors.push({ code: "E_NOT_FOUND", msg: `not a directory or sidecar id: ${ref}`, path: null });
    }
  }
  return out;
}

export function writeSidecarWithEvent(root: RootRef, event: string, dryRun: boolean, reason?: string): void {
  const entry: HistoryEvent = { ts: isoLocal(), event, by: `intake@${CLI_VERSION}` };
  if (reason) entry.reason = reason;
  root.sidecar.history.push(entry);
  if (!dryRun) writeFileSync(root.sidecarPath, serializeSidecar(root.sidecar));
}

/** Row shapes for the P2 command payloads (doc 03 `--json` data). */
export interface IdentifyRow {
  id: string;
  root_path: string;
  kept: boolean;
  status: string;
  artist?: string | null;
  album?: string | null;
  needs_review?: boolean;
  issues?: string[];
}

export interface AssignRow {
  id: string;
  root_path: string;
  kept: boolean;
  target_collection: string;
  confidence?: number;
  margin?: number;
  target_path?: string | null;
  assigned_by?: "user" | "engine";
  short_circuited?: boolean;
  needs_review?: boolean;
}

// ---- identify ---------------------------------------------------------------

/**
 * Engine dependencies a caller may substitute. Commands default to
 * `buildProviders()` (env-configured HTTP + subprocess shim); tests and
 * `propose` pass their own, so nothing below the command layer needs env vars.
 */
export interface P2Deps {
  providers?: Providers;
  /** Collection dir listings for the library layout; defaults to diskLibraryProbe(). */
  library?: LibraryProbe;
  /** Filesystem facts for the tier root check (propose); defaults to the real disk. */
  mountFs?: MountFs;
}

/**
 * The disk-reading LibraryProbe: immediate subdirectory names (symlinks not
 * followed), null when the dir does not exist. Listings are cached for the
 * probe's lifetime, one command run: nothing in propose/assign writes to the
 * library. Any other read error is thrown rather than read as an empty
 * collection, which would silently send an artist's release to `[Releases]`.
 */
export function diskLibraryProbe(): LibraryProbe {
  const cache = new Map<string, string[] | null>();
  return (dir) => {
    if (cache.has(dir)) return cache.get(dir)!;
    let names: string[] | null;
    try {
      names = readdirSync(dir, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name).sort();
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      if (code !== "ENOENT" && code !== "ENOTDIR") throw e;
      names = null;
    }
    cache.set(dir, names);
    return names;
  };
}

/**
 * Identify an already-resolved RootRef list in place. Split out of cmdIdentify
 * so `propose` can drive it on the RootRef it already holds instead of
 * re-resolving by id and re-reading the sidecar from disk — a round-trip that
 * silently made `propose --dry-run` a no-op, since the sub-command had written
 * nothing for it to read back.
 */
export async function identifyRoots(
  roots: RootRef[],
  opts: CommonOpts,
  deps: P2Deps = {},
): Promise<{ data: IdentifyRow[]; errors: JsonError[] }> {
  const errors: JsonError[] = [];
  const providers = deps.providers ?? buildProviders();
  const cfg = loadAssignConfig();
  const data: IdentifyRow[] = [];
  for (const root of roots) {
    // Doc 03 legal source statuses: never on a rejected root or one that has
    // reached the library.
    if (!PRE_LIBRARY_STATUSES.has(root.sidecar.status)) {
      errors.push({ code: "E_BAD_STATUS", msg: `cannot identify from status ${root.sidecar.status}`, path: root.dir });
      continue;
    }
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
  return { data, errors };
}

export async function cmdIdentify(args: string[], opts: CommonOpts, deps: P2Deps = {}): Promise<CommandResult<IdentifyRow[] | null>> {
  if (args.length === 0) return fail("E_BAD_ARGS", "usage: intake identify <root...>");
  const refErrors: JsonError[] = [];
  const roots = rootsFromRefs(args, refErrors);
  if (roots.length === 0) return { data: null, errors: refErrors, exitCode: 2 };
  const { data, errors } = await identifyRoots(roots, opts, deps);
  return finish(data, [...refErrors, ...errors]);
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

/**
 * Recompute a proposal's target from the library as it is now, keeping its
 * collection (doc 02: "already has" is read from disk at propose time). A
 * target built by an earlier `assign` may predate releases added to the
 * collection since, or the layout itself (a compilation assigned before
 * amendment 003 has no target).
 */
export function refreshTarget(root: RootRef, library: LibraryProbe, cfg: AssignConfig = loadAssignConfig()): void {
  const p = root.sidecar.proposal;
  if (!p) return;
  const plan = buildTargetPath(assignInput(root), p.target_collection, cfg, library);
  p.target_path = plan.target_path;
  p.structure_slot = plan.structure_slot;
  if (plan.restructure_candidates.length > 0) p.restructure_candidates = plan.restructure_candidates;
  else delete p.restructure_candidates;
}

/** Assign an already-resolved RootRef list in place (see identifyRoots). */
export async function assignRoots(
  roots: RootRef[],
  opts: AssignOpts,
  rdir: string,
  deps: P2Deps = {},
): Promise<{ data: AssignRow[]; errors: JsonError[] }> {
  const errors: JsonError[] = [];
  const genre = loadGenreMap(rdir);
  const rules = { genre, labels: loadLabelMap(rdir), styles: loadStyleMap(rdir), config: loadAssignConfig() };
  const providers = deps.providers ?? buildProviders();
  const library = deps.library ?? diskLibraryProbe();
  const assignProviders: AssignProviders = {
    similar: providers.similar,
    aliases: providers.discogs ? (name) => providers.discogs!.artistAliases(name) : null,
    library,
  };

  const data: AssignRow[] = [];
  let genreDirty = false;
  for (const root of roots) {
    // Doc 03 legal source statuses, as for identify.
    if (!PRE_LIBRARY_STATUSES.has(root.sidecar.status)) {
      errors.push({ code: "E_BAD_STATUS", msg: `cannot assign from status ${root.sidecar.status}`, path: root.dir });
      continue;
    }
    const input = assignInput(root);
    if (opts.collection) {
      // User override: authoritative pick + feedback loop (doc 02).
      const prior = root.sidecar.proposal;
      const { target_path, structure_slot, restructure_candidates } =
        buildTargetPath(input, opts.collection, rules.config, library);
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
      if (restructure_candidates.length > 0) proposal.restructure_candidates = restructure_candidates;
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
        // No feedback for a VA credit: it would rebuild, under feedback:, the
        // artist prior that assign() ignores for Various Artists.
        if (input.artist && !isVariousArtists(input.artist)) {
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
  return { data, errors };
}

export async function cmdAssign(args: string[], opts: AssignOpts, deps: P2Deps = {}): Promise<CommandResult<AssignRow[] | null>> {
  if (args.length === 0) return fail("E_BAD_ARGS", "usage: intake assign <root...> [--collection <name>] [--by user|engine]");
  const rdir = rulesDir();
  if (!rdir) return fail("E_NO_RULES", "rules dir not found (INTAKE_RULES_DIR or ~/.config/intake/config.toml)");
  if (opts.collection && opts.by === "engine")
    return fail("E_BAD_ARGS", "--collection implies --by user");

  const refErrors: JsonError[] = [];
  const roots = rootsFromRefs(args, refErrors);
  if (roots.length === 0) return { data: null, errors: refErrors, exitCode: 2 };

  const { data, errors } = await assignRoots(roots, opts, rdir, deps);
  return finish(data, [...refErrors, ...errors]);
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
    // The rules repo keeps reports under docs/, next to the structure notes.
    const docsDir = join(out, "docs");
    mkdirSync(docsDir, { recursive: true });
    writeFileSync(join(docsDir, "naming-variants-report.md"), result.report);
  }
  return {
    data: { out, dry_run: opts.dryRun, ...result.stats, trees: opts.trees.map((t) => ({ ...t, path: resolve(t.path) })) },
    errors: [],
    exitCode: 0,
  };
}
