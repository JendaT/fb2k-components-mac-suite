// P3 commands: propose, approve, reject, execute, gc (doc 03 execute protocol
// + status lifecycle). Execute copies and verifies; it never moves or deletes
// income files — deletion is gc's job, after journal re-verification.

import {
  chmodSync, closeSync, copyFileSync, existsSync, fsyncSync, lstatSync, mkdirSync, openSync,
  readFileSync, readdirSync, realpathSync, renameSync, rmdirSync, rmSync, statSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { audioHashAs } from "./audioHash.ts";
import { finish, type CommandResult, type CommonOpts } from "./commands.ts";
import {
  assignRoots, diskLibraryProbe, identifyRoots, refreshTarget, rootsFromRefs, shimNotice, writeSidecarWithEvent,
  type P2Deps, type RootRef,
} from "./commands-p2.ts";
import { loadAssignConfig, loadIncome, loadP3Config, rulesDir } from "./config.ts";
import { clearImmutableTree, immutablePaths, setImmutable } from "./fflags.ts";
import { CLI_VERSION, type JsonError, type Status, type StructureSlot, type TierDef } from "./types.ts";
import { appendJournal, findPlacedRecord, findRecord, nextSeq } from "./journal.ts";
import { writeProvenance, type ProvenanceTags } from "./provenance.ts";
import { loadGenreMap, loadLabelMap, loadStyleMap, recordPlacement, saveGenreMap, type GenreMap } from "./rules.ts";
import { readSidecar } from "./sidecar.ts";
import { targetTierProblem, type MountFs } from "./tierroot.ts";
import {
  GC_STAGE_PREFIX, IO_CONCURRENCY, isJunkFile, isoLocal, isSidecarName, isVariousArtists, mapLimit, sha1Hex, walkDirs,
} from "./util.ts";

function fail(code: string, msg: string, path: string | null = null): CommandResult<null> {
  return { data: null, errors: [{ code, msg, path }], exitCode: 2 };
}

/**
 * A placement target is only honored if it lands under a configured tier root.
 * Engine-built targets already do (assign.buildTargetPath), but execute/gc also
 * act on `target_path` re-read from a sidecar — an untrusted value that must not
 * be allowed to write/delete outside the library. If no tiers are configured the
 * check cannot be enforced, so it is skipped (unconfigured setups are unchanged).
 */
function targetUnderTierRoot(target: string, tiers: Record<string, TierDef>): boolean {
  const roots = Object.values(tiers);
  if (roots.length === 0) return true;
  if (!isAbsolute(target)) return false;
  const t = resolve(target);
  return roots.some((def) => {
    const root = resolve(def.root);
    return t === root || t.startsWith(root + "/");
  });
}

/** All sidecars across the configured income folders. */
function allRoots(errors: JsonError[]): RootRef[] {
  const out: RootRef[] = [];
  for (const inc of loadIncome()) {
    if (!existsSync(inc.path)) continue;
    for (const e of walkDirs(inc.path)) {
      let names: string[];
      try {
        names = readdirSync(e.path).filter(isSidecarName).sort();
      } catch {
        continue;
      }
      for (const n of names) {
        const sc = readSidecar(join(e.path, n));
        if (sc) out.push({ dir: e.path, sidecarPath: join(e.path, n), sidecar: sc });
        else errors.push({ code: "E_PARSE", msg: "unreadable sidecar", path: join(e.path, n) });
      }
    }
  }
  return out;
}

/** Row shapes for the P3 command payloads (doc 03 `--json` data). */
export interface ProposeRow {
  id: string;
  root_path: string;
  status?: "proposed";
  target_path?: string;
  /** The proposal's structure_slot (doc 02 layout), alongside target_path. */
  structure_slot?: StructureSlot | null;
  confidence?: number;
  /** Proposal's restructure_candidates (existing releases now due an artist folder); only when non-empty. */
  restructure_candidates?: string[];
  skipped?: "needs_review";
}

export interface ApproveRow {
  id: string;
  root_path: string;
  status: "approved";
}

export interface RejectRow {
  id: string;
  root_path: string;
  status: "rejected";
  dry_run?: true;
}

export interface ExecuteRow {
  id: string;
  root_path: string;
  target_path?: string;
  journal_seq?: number;
  files?: number;
  artifacts?: number;
  skipped_shadows?: number;
  issues?: string[];
  dry_run?: true;
  resumed?: "completed" | "reverted_to_approved";
}

export interface GcRow {
  id: string;
  root_path: string;
  action?: "delete" | "relocate_dj";
  dj_dest?: string | null;
  files?: number;
  skipped?: "too_young";
  dry_run?: true;
  issues?: string[]; // on a delete/relocate row: `cleared_readonly_flag: <n> file(s)`
}

// ---- propose ------------------------------------------------------------------

export interface ProposeOpts extends CommonOpts {
  allResolved: boolean;
}

/**
 * Human-mode notices for a propose run: the beets shim failures (shimNotice),
 * and in auto mode the resolved roots skipped for review. `reviewSkipped`
 * counts both kinds: roots flagged before the run (never picked up) and roots
 * whose identify/assign raised the flag during it (`skipped` rows). Only clean
 * resolved roots are auto-eligible (doc 01 "Thresholds"), so these wait for an
 * explicit `propose <id>`.
 */
function proposeNotices(shimErrors: string[], reviewSkipped: number): string[] | undefined {
  const notices: string[] = [];
  const shim = shimNotice(shimErrors);
  if (shim) notices.push(shim);
  if (reviewSkipped > 0) notices.push(`skipped ${reviewSkipped} resolved root(s) that need review; propose them by id`);
  return notices.length > 0 ? notices : undefined;
}

export async function cmdPropose(args: string[], opts: ProposeOpts, deps: P2Deps = {}): Promise<CommandResult<ProposeRow[] | null>> {
  const errors: JsonError[] = [];
  let roots: RootRef[];
  let flaggedBefore = 0; // auto mode: resolved roots already needs_review, never picked up
  if (opts.allResolved) {
    // Auto mode: only clean resolved roots (never needs_review, never reject).
    const resolved = allRoots(errors).filter((r) => r.sidecar.status === "resolved");
    roots = resolved.filter((r) => !r.sidecar.cluster.needs_review);
    flaggedBefore = resolved.length - roots.length;
  } else {
    if (args.length === 0) return fail("E_BAD_ARGS", "usage: intake propose <root...>|--all-resolved");
    roots = rootsFromRefs(args, errors);
  }
  if (roots.length === 0) {
    const result: CommandResult<ProposeRow[] | null> =
      { data: errors.length ? null : [], errors, exitCode: errors.length ? 2 : 0 };
    const notices = proposeNotices([], flaggedBefore);
    if (notices) result.notices = notices;
    return result;
  }

  const data: ProposeRow[] = [];
  const shimErrors: string[] = [];
  // One library probe for the run: its listings are shared by every root.
  const library = deps.library ?? diskLibraryProbe();
  const p2deps: P2Deps = { ...deps, library };
  const assignCfg = loadAssignConfig();
  const rdir = rulesDir();
  // The maps assign reads, read before any root is touched: a malformed one
  // fails the command (E_BAD_RULES) before identify writes a sidecar or an
  // earlier root is proposed. assignRoots reads them again for each root.
  if (rdir) {
    loadGenreMap(rdir);
    loadLabelMap(rdir);
    loadStyleMap(rdir);
  }
  for (const root of roots) {
    if (root.sidecar.status !== "resolved") {
      errors.push({ code: "E_BAD_STATUS", msg: `cannot propose from status ${root.sidecar.status}`, path: root.dir });
      continue;
    }
    // propose = identify + assign + naming (doc 03); run whichever is missing.
    // Driven on this RootRef, so the results are visible even under --dry-run,
    // where nothing is written to read back. Sub-stage errors stay internal:
    // the outcome is reported as E_NO_TARGET below, as before.
    if (!root.sidecar.identification || !root.sidecar.proposal) {
      if (!root.sidecar.identification) shimErrors.push(...(await identifyRoots([root], opts, p2deps)).shimErrors);
      if (!root.sidecar.proposal && rdir) {
        await assignRoots([root], { ...opts, collection: null, by: null }, rdir, p2deps);
      }
    }
    // The layout is read at propose time (doc 02), also for a proposal that an
    // earlier `assign` built: same collection, target from the library now.
    refreshTarget(root, library, assignCfg);
    const target = root.sidecar.proposal?.target_path;
    if (!target) {
      const why = root.sidecar.singles ? "singles slot pending"
        : !root.sidecar.proposal ? "no assignment evidence"
        : "no target path (tier reject?)";
      errors.push({ code: "E_NO_TARGET", msg: `cannot propose: ${why}`, path: root.dir });
      continue;
    }
    // A missing or unmounted tier root reads as an empty library, so the
    // layout above cannot be trusted: refuse this root, the others proceed.
    const tierProblem = targetTierProblem(target, assignCfg.tiers, deps.mountFs);
    if (tierProblem) {
      errors.push({ code: "E_NO_TARGET", msg: `cannot propose: ${tierProblem}`, path: root.dir });
      continue;
    }
    if (opts.allResolved && root.sidecar.cluster.needs_review) {
      // identify/assign may have raised the flag; auto mode skips those.
      data.push({ id: root.sidecar.id, root_path: root.dir, skipped: "needs_review" });
      continue;
    }
    root.sidecar.status = "proposed";
    writeSidecarWithEvent(root, "proposed", opts.dryRun);
    const row: ProposeRow = {
      id: root.sidecar.id, root_path: root.dir, status: "proposed",
      target_path: target, structure_slot: root.sidecar.proposal!.structure_slot,
      confidence: root.sidecar.proposal!.confidence,
    };
    const restructure = root.sidecar.proposal!.restructure_candidates;
    if (restructure && restructure.length > 0) row.restructure_candidates = restructure;
    data.push(row);
  }
  const result: CommandResult<ProposeRow[] | null> = finish(data, errors);
  const skippedRows = data.filter((r) => r.skipped === "needs_review").length;
  const notices = proposeNotices(shimErrors, flaggedBefore + skippedRows);
  if (notices) result.notices = notices;
  return result;
}

// ---- approve ------------------------------------------------------------------

export interface ApproveOpts extends CommonOpts {
  batch: string | null;
}

/**
 * Positional refs plus `--batch <file>` (one id or path per line; blank lines
 * and `#` comments skipped), or `{missing}` naming a batch file that is absent.
 */
function refsWithBatch(args: string[], batch: string | null): string[] | { missing: string } {
  const refs = [...args];
  if (batch) {
    if (!existsSync(batch)) return { missing: batch };
    refs.push(...readFileSync(batch, "utf8").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#")));
  }
  return refs;
}

export function cmdApprove(args: string[], opts: ApproveOpts): CommandResult<ApproveRow[] | null> {
  const refs = refsWithBatch(args, opts.batch);
  if (!Array.isArray(refs)) return fail("E_NOT_FOUND", "batch file not found", refs.missing);
  if (refs.length === 0) return fail("E_BAD_ARGS", "usage: intake approve <root...>|--batch <file>");

  const errors: JsonError[] = [];
  const roots = rootsFromRefs(refs, errors);
  const data: ApproveRow[] = [];
  for (const root of roots) {
    if (root.sidecar.status !== "proposed") {
      errors.push({ code: "E_BAD_STATUS", msg: `cannot approve from status ${root.sidecar.status}`, path: root.dir });
      continue;
    }
    root.sidecar.status = "approved";
    // Doc 03: needs_review is sticky and approve is the one command that
    // clears it (a user approval is the review).
    root.sidecar.cluster.needs_review = false;
    writeSidecarWithEvent(root, "approved", opts.dryRun);
    data.push({ id: root.sidecar.id, root_path: root.dir, status: "approved" });
  }
  return finish(data, errors);
}

// ---- reject -------------------------------------------------------------------

export interface RejectOpts extends CommonOpts {
  batch: string | null;
  reason: string | null;
}

/**
 * Doc 03 "reject semantics": legal before anything reaches the library. A
 * placing/placed/gc_done release is (or may be) in the library, and withdrawing
 * it is un-specced; `rejected` itself is terminal.
 */
const REJECTABLE: ReadonlySet<Status> = new Set<Status>(["new", "resolved", "proposed", "approved"]);

/**
 * State change only: flips the sidecar to `rejected` and appends a history
 * entry carrying the reason. No tags, no audio, no journal, no deletion — the
 * local bytes stay put and are not gc-eligible (gc touches only `placed`).
 */
export function cmdReject(args: string[], opts: RejectOpts): CommandResult<RejectRow[] | null> {
  const refs = refsWithBatch(args, opts.batch);
  if (!Array.isArray(refs)) return fail("E_NOT_FOUND", "batch file not found", refs.missing);
  if (refs.length === 0) return fail("E_BAD_ARGS", 'usage: intake reject <root...>|--batch <file> [--reason "<text>"]');

  const errors: JsonError[] = [];
  const data: RejectRow[] = [];
  // The same root may be named twice (id and path, or a repeated batch line):
  // reject it once rather than append a second history entry or refuse it.
  const seen = new Set<string>();
  for (const root of rootsFromRefs(refs, errors)) {
    if (seen.has(root.sidecarPath)) continue;
    seen.add(root.sidecarPath);
    if (!REJECTABLE.has(root.sidecar.status)) {
      errors.push({ code: "E_BAD_STATUS", msg: `cannot reject from status ${root.sidecar.status}`, path: root.dir });
      continue;
    }
    root.sidecar.status = "rejected";
    writeSidecarWithEvent(root, "rejected", opts.dryRun, opts.reason ?? undefined);
    const row: RejectRow = { id: root.sidecar.id, root_path: root.dir, status: "rejected" };
    if (opts.dryRun) row.dry_run = true;
    data.push(row);
  }
  return finish(data, errors);
}

// ---- execute ------------------------------------------------------------------

export interface ExecuteOpts extends CommonOpts {
  approved: boolean;
  resume: boolean;
}

interface PlacePlan {
  audio: { from: string; to: string; hash: string }[]; // relative "to" inside release
  artifacts: { from: string; to: string }[];
  skippedShadows: number;
}

function planFiles(root: RootRef): PlacePlan {
  const plan: PlacePlan = { audio: [], artifacts: [], skippedShadows: 0 };
  for (const f of root.sidecar.files) {
    if (f.quality_shadow) {
      plan.skippedShadows++;
      continue;
    }
    plan.audio.push({ from: join(root.dir, f.path), to: f.path, hash: f.audio_hash });
  }
  if (!root.sidecar.virtual) {
    // Whole-dir roots bring their artifacts (covers, cues, logs, ...).
    const audioSet = new Set(root.sidecar.files.map((f) => f.path));
    for (const e of walkDirs(root.dir)) {
      const relBase = e.path === root.dir ? "" : e.path.slice(root.dir.length + 1) + "/";
      for (const n of e.otherFiles) {
        if (isJunkFile(n) || isSidecarName(n)) continue;
        const rel = relBase + n;
        if (!audioSet.has(rel)) plan.artifacts.push({ from: join(root.dir, rel), to: rel });
      }
    }
  }
  return plan;
}

/**
 * Every file's hash must match the sidecar (doc 03 execute step 3, and gc's
 * pre-deletion re-verification). Hashing runs concurrently but the reported
 * failure is still the first one in file order, so messages stay deterministic;
 * a failing tree is hashed in full rather than short-circuiting, which costs
 * I/O only in the exceptional case.
 */
async function verifyTree(base: string, audio: { to: string; hash: string }[]): Promise<string | null> {
  const results = await mapLimit(audio, IO_CONCURRENCY, async (a) => {
    const p = join(base, a.to);
    if (!existsSync(p)) return `missing: ${a.to}`;
    const r = await audioHashAs(p, a.hash);
    if (r.hash === a.hash) return null;
    // An unset-MD5 FLAC keyed by its decoded audio cannot be re-checked
    // without the decoder; say so instead of reporting a corrupt copy.
    return r.issues.includes("flac_decoder_missing") ? `flac decoder missing: ${a.to}` : `hash mismatch: ${a.to}`;
  });
  return results.find((r) => r !== null) ?? null;
}

function fsyncFile(path: string): void {
  const fd = openSync(path, "r+");
  try {
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
}

export interface ExecuteDeps {
  /** Filesystem facts for the tier root check; defaults to the real disk. */
  mountFs?: MountFs;
}

export async function cmdExecute(
  args: string[],
  opts: ExecuteOpts,
  deps: ExecuteDeps = {},
): Promise<CommandResult<ExecuteRow[] | null>> {
  const cfg = loadP3Config();
  if (!cfg.journal_path) return fail("E_NO_JOURNAL", "structure.yaml journal.path is not configured");
  const tiers = loadAssignConfig().tiers;
  const errors: JsonError[] = [];
  const wantStatus = opts.resume ? "placing" : "approved";
  let roots: RootRef[];
  if (args.length > 0) {
    // Named roots are the whole work set, with or without --resume/--approved:
    // `execute <ids> --resume` must not touch other placing roots (resume
    // reverts an interrupted root, which would clobber an execute still
    // running elsewhere).
    roots = rootsFromRefs(args, errors);
  } else if (opts.approved || opts.resume) {
    roots = allRoots(errors).filter((r) => r.sidecar.status === wantStatus);
  } else {
    return fail("E_BAD_ARGS", "usage: intake execute <root...>|--approved [--resume]");
  }
  if (roots.length === 0) return { data: errors.length ? null : [], errors, exitCode: errors.length ? 2 : 0 };

  const batch = "b" + sha1Hex(isoLocal() + ":" + process.pid).slice(0, 10);
  const data: ExecuteRow[] = [];
  // Read the genre map once per command, before anything is placed (it was
  // re-read and re-parsed for every placed root, and a malformed map then
  // failed a root after its commit point); still saved per placement, so a
  // crash mid-batch cannot lose the counts of releases already in the library.
  const rdir = rulesDir();
  const genre: GenreMap | null = rdir ? loadGenreMap(rdir) : null;

  for (const root of roots) {
    const sc = root.sidecar;
    const target = sc.proposal?.target_path;

    if (opts.resume) {
      // Crash recovery only (doc 03): a named root that is not `placing` is
      // refused, never executed fresh under --resume.
      if (sc.status !== "placing") {
        errors.push({ code: "E_BAD_STATUS", msg: `cannot resume from status ${sc.status}`, path: root.dir });
        continue;
      }
      // An unmounted share would read as "copy missing" and revert a root
      // whose copy may be complete on the share: leave it `placing`.
      const resumeProblem = target ? targetTierProblem(target, tiers, deps.mountFs) : null;
      if (resumeProblem) {
        errors.push({ code: "E_NO_TARGET", msg: `cannot resume: ${resumeProblem}`, path: root.dir });
        continue;
      }
      data.push(await resumeRoot(root, cfg.journal_path, opts));
      continue;
    }
    if (sc.status !== "approved") {
      errors.push({ code: "E_BAD_STATUS", msg: `cannot execute from status ${sc.status}`, path: root.dir });
      continue;
    }
    if (!target) {
      errors.push({ code: "E_NO_TARGET", msg: "approved sidecar has no target_path", path: root.dir });
      continue;
    }
    if (!targetUnderTierRoot(target, tiers)) {
      errors.push({ code: "E_NO_TARGET", msg: "target_path is outside all configured tier roots", path: target });
      continue;
    }
    // Never write the library copy onto a missing tier root or a stale mount
    // point dir on the local disk (share not mounted).
    const tierProblem = targetTierProblem(target, tiers, deps.mountFs);
    if (tierProblem) {
      errors.push({ code: "E_NO_TARGET", msg: `cannot execute: ${tierProblem}`, path: root.dir });
      continue;
    }
    if (existsSync(target)) {
      errors.push({ code: "E_TARGET_EXISTS", msg: "target path already exists", path: target });
      continue;
    }
    const plan = planFiles(root);
    if (opts.dryRun) {
      data.push({
        id: sc.id, root_path: root.dir, target_path: target, dry_run: true,
        files: plan.audio.length, artifacts: plan.artifacts.length, skipped_shadows: plan.skippedShadows,
      });
      continue;
    }

    // 0. Mark transient state (crash-recovery anchor for --resume).
    sc.status = "placing";
    writeSidecarWithEvent(root, "placing", false);

    const tmp = join(dirname(target), `.intake-tmp-${sc.id}`);
    const issues: string[] = [];
    // The rename in step 4 is the commit point: after it the release IS in the
    // library, so a later failure must never be treated as "did not happen".
    let committed = false;
    try {
      // 1+2. Copy into a temp dir on the target volume, tag the copies, fsync.
      removeTemp(tmp);
      mkdirSync(tmp, { recursive: true });
      const tags: ProvenanceTags = {
        INTAKE_DATE: isoLocal().slice(0, 10),
        INTAKE_SOURCE: sc.source.source_type,
        INTAKE_BATCH: batch,
      };
      const copies = [...plan.audio, ...plan.artifacts].map((item) => ({ from: item.from, dest: join(tmp, item.to) }));
      for (const c of copies) {
        mkdirSync(dirname(c.dest), { recursive: true });
        copyFileSync(c.from, c.dest);
      }
      // copyFileSync clones a file over 128 KiB on APFS, flags included, so a
      // uchg original (an SMB share's read-only attribute) gives a uchg copy,
      // which cannot be chmodded or tagged. uchg off on the copies, one spawn
      // for the temp dir; the income original is never changed.
      clearImmutableTree(tmp);
      for (const c of copies) {
        // copyFileSync keeps the original's mode, and a 0444 copy cannot be
        // tagged (metaflac: "ERROR: writing FLAC file"). u+w on the copy
        // only; the income original is never changed.
        chmodSync(c.dest, (statSync(c.dest).mode & 0o7777) | 0o200);
      }
      for (const a of plan.audio) {
        const r = await writeProvenance(join(tmp, a.to), tags, a.hash);
        if (r.issue) {
          // A skipped write (no tags to an fsha1:-keyed FLAC, a format with
          // no writer) is an issue on a placed root. A failed one
          // (metaflac_missing, metaflac_failed, provenance_write_failed)
          // fails the root before the commit point: step 2 writes the tags.
          if (!r.issue.startsWith("provenance_tags_skipped:")) throw new Error(`tag write failed: ${a.to} (${r.issue})`);
          issues.push(r.issue);
        }
        fsyncFile(join(tmp, a.to));
      }
      // 3. Verify hashes + count on the copies.
      const bad = await verifyTree(tmp, plan.audio);
      if (bad) throw new Error(`verify failed: ${bad}`);

      // 4. Atomic rename into place — the commit point.
      mkdirSync(dirname(target), { recursive: true });
      renameSync(tmp, target);
      committed = true;

      // 5. Journal + genre-map counts + sidecar flip.
      const seq = nextSeq(cfg.journal_path);
      appendJournal(cfg.journal_path, {
        seq, ts: isoLocal(), event: "placed", sidecar_id: sc.id,
        audio_hashes: plan.audio.map((a) => a.hash), target_path: target, cli_version: CLI_VERSION,
      });
      const artist = sc.identification?.artist ?? sc.cluster.albumartist;
      // No count for a Various Artists credit (doc 02, amendment 003): it would
      // build the artist prior that assign ignores for VA, as assign's
      // feedback does not record one either.
      if (rdir && genre && artist && !isVariousArtists(artist) && sc.proposal) {
        recordPlacement(genre, artist, sc.proposal.target_collection);
        saveGenreMap(rdir, genre);
      }
      sc.placed = { target_path: target, verified: true, journal_seq: seq };
      sc.status = "placed";
      writeSidecarWithEvent(root, "placed", false);
      data.push({
        id: sc.id, root_path: root.dir, target_path: target, journal_seq: seq,
        files: plan.audio.length, artifacts: plan.artifacts.length,
        skipped_shadows: plan.skippedShadows, issues,
      });
    } catch (e) {
      const msg = String(e instanceof Error ? e.message : e);
      if (committed) {
        // Past the commit point (journal append, genre-map write or the sidecar
        // flip failed). The release is in the library, so the target is left
        // alone and the sidecar stays `placing` — exactly the state
        // `execute --resume` is built to finish. Reverting to `approved` here
        // would strand a placed release behind E_TARGET_EXISTS forever.
        errors.push({
          code: "E_VERIFY",
          msg: `placed at ${target} but bookkeeping failed (${msg}); rerun with --resume`,
          path: root.dir,
        });
      } else {
        removeTemp(tmp);
        sc.status = "approved";
        writeSidecarWithEvent(root, "execute_failed", false);
        errors.push({ code: "E_VERIFY", msg, path: root.dir });
      }
    }
  }
  return finish(data, errors);
}

/**
 * Remove execute's temp dir. A copy that still carries uchg from its original
 * (a copy loop that failed, or a run that died, before the flags were cleared)
 * makes the removal fail with EPERM: then uchg is cleared on the temp dir's
 * tree and the removal runs again.
 */
function removeTemp(tmp: string): void {
  try {
    rmSync(tmp, { recursive: true, force: true });
    return;
  } catch (e) {
    if (errCode(e) !== "EPERM") throw e;
  }
  clearImmutableTree(tmp);
  rmSync(tmp, { recursive: true, force: true });
}

/** Crash recovery: placing -> placed (target verifies) or back to approved. */
async function resumeRoot(root: RootRef, journalPath: string, opts: CommonOpts): Promise<ExecuteRow> {
  const sc = root.sidecar;
  const target = sc.proposal?.target_path ?? null;
  const plan = planFiles(root);
  if (target && existsSync(target) && (await verifyTree(target, plan.audio)) === null) {
    let record = findPlacedRecord(journalPath, sc.id);
    if (!record && !opts.dryRun) {
      const seq = nextSeq(journalPath);
      record = {
        seq, ts: isoLocal(), event: "placed", sidecar_id: sc.id,
        audio_hashes: plan.audio.map((a) => a.hash), target_path: target, cli_version: CLI_VERSION,
      };
      appendJournal(journalPath, record);
    }
    sc.placed = { target_path: target, verified: true, journal_seq: record?.seq ?? -1 };
    sc.status = "placed";
    writeSidecarWithEvent(root, "placed", opts.dryRun);
    return { id: sc.id, root_path: root.dir, resumed: "completed", target_path: target };
  }
  if (target) removeTemp(join(dirname(target), `.intake-tmp-${sc.id}`));
  sc.status = "approved";
  writeSidecarWithEvent(root, "execute_reverted", opts.dryRun);
  return { id: sc.id, root_path: root.dir, resumed: "reverted_to_approved" };
}

// ---- gc -----------------------------------------------------------------------

export interface GcOpts extends CommonOpts {
  all?: boolean; // --all: every placed root in every income folder
  age: number | null; // days
  relocateDj: boolean;
}

/** Whether something (a symlink included) is at `p`. */
function present(p: string): boolean {
  try {
    lstatSync(p);
    return true;
  } catch {
    return false;
  }
}

/** A path counts as inside `rootReal` (a realpath) when its own realpath is it or under it. */
function insideDir(p: string, rootReal: string): boolean {
  try {
    const real = realpathSync(p);
    return real === rootReal || real.startsWith(rootReal + "/");
  } catch {
    return false;
  }
}

/**
 * Delete a placed root's local files, or relocate them into `destDir` (the
 * dj zone; artifacts are still deleted), all of them or none.
 *
 * Every file is first renamed: an audio file to its dj destination when
 * relocating, everything else into the stage dir `.intake-gc-<id>/` inside
 * the root's dir, keeping its path relative to the root (flattening to
 * basename() collides across discs that number tracks independently). A
 * rename fails for every cause a deletion would (no write on the parent dir,
 * an immutable or append-only flag, ...), so when one fails the renames
 * already done are reversed and the dirs this run created are removed:
 * nothing of the root is deleted or moved, and the error names the file. A
 * dj destination that already exists fails the same way, as a rename would
 * replace it. Only after every rename succeeded are the staged files deleted;
 * that runs in a dir this run made, where those causes do not apply. If a
 * delete still fails (an I/O error), the files not yet deleted are renamed
 * back and the error says how many were deleted.
 *
 * A dir inside the root's dir without u+w (a read-only disc dir, e.g. from
 * an archive) gets u+w while gc works, and its mode back afterwards if it
 * still exists. Nothing outside the root's dir is chmodded.
 *
 * The user-immutable flag (uchg: an SMB share's DOS read-only attribute,
 * src/fflags.ts) is cleared first on the files gc renames and on the dirs
 * inside the root's dir that a rename or the cleanup goes through (the root's
 * dir, the files' dirs, a whole-dir root's disc dirs): one stat spawn reads
 * them all, one chflags spawn clears the flagged ones. When gc fails, every
 * one still there gets uchg back (after the modes), so the root is left as it
 * was; when it succeeds, the dirs still there do. The row's `issues` counts
 * the files cleared (`cleared_readonly_flag: <n> file(s)`). No other flag is
 * changed (uappnd, schg and sappnd still fail the rename), and nothing
 * outside the root's dir: a relocated file arrives in the dj zone unflagged.
 *
 * Then, for a whole-dir root, the now-empty disc dirs (junk files included)
 * go; that is cleanup after the files are gone and does not fail the root.
 * The archive and the `.unpacked` dir of an archive-sourced root are not
 * touched: only the root's own files are.
 */
function disposeLocal(root: RootRef, plan: PlacePlan, destDir: string | null): { error: JsonError } | { issues: string[] } {
  const sc = root.sidecar;
  const stage = join(root.dir, `${GC_STAGE_PREFIX}${sc.id}`); // never walked (walkDirs)
  const moves: { from: string; to: string; rel: string; relocated: boolean }[] = [];
  // Shadows included: all local copies go.
  for (const f of sc.files) {
    const from = join(root.dir, f.path);
    if (present(from)) moves.push({ from, to: join(destDir ?? stage, f.path), rel: f.path, relocated: destDir !== null });
  }
  if (!sc.virtual) {
    // Whole-dir root: its artifacts were copied at execute.
    for (const a of plan.artifacts) {
      const from = join(root.dir, a.to);
      if (present(from)) moves.push({ from, to: join(stage, a.to), rel: a.to, relocated: false });
    }
  }

  let rootReal: string;
  try {
    rootReal = realpathSync(root.dir);
  } catch (e) {
    return { error: { code: "E_VERIFY", msg: `cannot read the root dir (${errCode(e)}); nothing of the root was changed`, path: root.dir } };
  }
  const isKind = (p: string, dir: boolean): boolean => {
    try {
      const st = lstatSync(p);
      return dir ? st.isDirectory() : st.isFile();
    } catch {
      return false;
    }
  };
  let flaggedFiles: string[] = [];
  let flaggedDirs: string[] = [];
  if (moves.length > 0) {
    const files = moves.map((m) => m.from).filter((p) => isKind(p, false) && insideDir(dirname(p), rootReal));
    const dirs = [...new Set([
      root.dir, ...moves.map((m) => dirname(m.from)), ...(sc.virtual ? [] : walkDirs(root.dir).map((e) => e.path)),
    ])].filter((d) => isKind(d, true) && insideDir(d, rootReal));
    const flagged = new Set(immutablePaths([...files, ...dirs]));
    flaggedFiles = files.filter((p) => flagged.has(p));
    flaggedDirs = dirs.filter((d) => flagged.has(d));
    // A clear that fails shows as the rename's EPERM below.
    setImmutable([...flaggedFiles, ...flaggedDirs], false);
  }
  const chmodded: { dir: string; mode: number }[] = [];
  const ensureWritable = (dir: string): void => {
    if (chmodded.some((c) => c.dir === dir) || !insideDir(dir, rootReal)) return;
    try {
      const st = lstatSync(dir);
      if (!st.isDirectory() || st.mode & 0o200) return;
      chmodSync(dir, (st.mode & 0o7777) | 0o200);
      chmodded.push({ dir, mode: st.mode & 0o7777 });
    } catch {
      // the rename below then fails and reports it
    }
  };
  const created: string[] = [];
  const mkdirTracked = (dir: string): void => {
    const missing: string[] = [];
    for (let d = dir; !present(d); d = dirname(d)) missing.push(d);
    if (missing.length === 0) return;
    mkdirSync(dir, { recursive: true });
    created.push(...missing.reverse());
  };
  const done: typeof moves = [];
  /** Rename back what is still staged or relocated; drop the dirs this run created. Returns the files left out. */
  const rollback = (): string[] => {
    const stuck: string[] = [];
    for (const m of [...done].reverse()) {
      try {
        renameSync(m.to, m.from);
      } catch {
        stuck.push(m.to);
      }
    }
    for (const d of [...created].reverse()) {
      try {
        rmdirSync(d);
      } catch {
        // not empty: something could not be renamed back
      }
    }
    return stuck;
  };
  const failure = (verb: string, m: { from: string; rel: string }, why: string, code = "E_VERIFY", deleted = 0) => {
    const stuck = rollback();
    const state = deleted === 0
      ? `nothing of the root was ${destDir ? "moved or deleted" : "deleted"}`
      : `${deleted} staged file(s) were already deleted, the rest renamed back`;
    const left = stuck.length > 0 ? `; renaming back failed for ${stuck.map((p) => `"${p}"`).join(", ")}` : "";
    return { error: { code, msg: `cannot ${verb} "${m.rel}" (${why}); ${state}${left}`, path: m.from } };
  };

  let disposed = false;
  try {
    if (moves.some((m) => !m.relocated)) ensureWritable(root.dir);
    for (const m of moves) ensureWritable(dirname(m.from));
    for (const m of moves) {
      const verb = m.relocated ? "relocate" : "delete";
      if (m.relocated && present(m.to)) return failure(verb, m, `"${m.to}" already exists`, "E_TARGET_EXISTS");
      try {
        mkdirTracked(dirname(m.to));
        renameSync(m.from, m.to);
      } catch (e) {
        return failure(verb, m, errCode(e));
      }
      done.push(m);
    }
    // Every file is staged or relocated: delete the staged ones.
    const staged = moves.filter((x) => !x.relocated);
    for (const [i, m] of staged.entries()) {
      try {
        rmSync(m.to);
      } catch (e) {
        const gone = new Set(staged.slice(0, i).map((x) => x.to));
        done.splice(0, done.length, ...done.filter((x) => !gone.has(x.to)));
        return failure("delete", m, errCode(e), "E_VERIFY", i);
      }
    }
    try {
      rmSync(stage, { recursive: true, force: true });
    } catch {
      // only empty stage dirs are left
    }
    if (!sc.virtual) {
      // Now-empty disc dirs (junk files included); the sidecar stays as a
      // gc_done tombstone in the root's dir.
      for (const e of walkDirs(root.dir)) {
        if (e.path === root.dir) continue;
        try {
          if (readdirSync(e.path).filter((n) => !isJunkFile(n)).length > 0) continue;
          ensureWritable(e.path);
          ensureWritable(dirname(e.path));
          rmSync(e.path, { recursive: true, force: true });
        } catch {
          // an empty dir left behind; the root's files are gone
        }
      }
    }
    disposed = true;
    const n = flaggedFiles.length;
    return { issues: n > 0 ? [`cleared_readonly_flag: ${n} file(s)`] : [] };
  } finally {
    for (const c of chmodded.reverse()) {
      try {
        if (present(c.dir)) chmodSync(c.dir, c.mode);
      } catch {
        // left owner-writable
      }
    }
    // After the modes: a uchg dir cannot be chmodded. The tombstone write
    // that follows a success is unaffected: it rewrites the existing sidecar
    // in place, which neither the root dir's mode nor its uchg blocks.
    setImmutable((disposed ? flaggedDirs : [...flaggedFiles, ...flaggedDirs]).filter(present), true);
  }
}

const errCode = (e: unknown): string =>
  (e as NodeJS.ErrnoException)?.code ?? (e instanceof Error ? e.message : String(e));

export async function cmdGc(args: string[], opts: GcOpts): Promise<CommandResult<GcRow[] | null>> {
  // Doc 03 `gc` semantics: roots or --all; an empty ref list never means
  // every root. Named roots are the whole work set, with or without --all.
  if (args.length === 0 && !opts.all)
    return fail("E_BAD_ARGS", "usage: intake gc <root...>|--all [--age <days>] [--relocate-dj]");
  const cfg = loadP3Config();
  if (!cfg.journal_path) return fail("E_NO_JOURNAL", "structure.yaml journal.path is not configured");
  const tiers = loadAssignConfig().tiers;
  const errors: JsonError[] = [];
  let roots: RootRef[];
  if (args.length > 0) {
    // Doc 03 legal source statuses: a named root that is not `placed`
    // (`rejected` included) is refused, not skipped.
    roots = [];
    for (const r of rootsFromRefs(args, errors)) {
      if (r.sidecar.status === "placed") roots.push(r);
      else errors.push({ code: "E_BAD_STATUS", msg: `cannot gc from status ${r.sidecar.status}`, path: r.dir });
    }
  } else {
    // --all selects `placed` roots and skips the rest silently.
    roots = allRoots(errors).filter((r) => r.sidecar.status === "placed");
  }
  const data: GcRow[] = [];

  for (const root of roots) {
    const sc = root.sidecar;
    const placed = sc.placed;
    if (!placed) {
      errors.push({ code: "E_BAD_STATUS", msg: "placed sidecar without placed info", path: root.dir });
      continue;
    }
    if (opts.age != null) {
      const ev = [...sc.history].reverse().find((h) => h.event === "placed");
      const ageDays = ev ? (Date.now() - new Date(ev.ts).getTime()) / 86_400_000 : 0;
      if (ageDays < opts.age) {
        data.push({ id: sc.id, root_path: root.dir, skipped: "too_young" });
        continue;
      }
    }
    if (!targetUnderTierRoot(placed.target_path, tiers)) {
      errors.push({ code: "E_VERIFY", msg: "placed target_path is outside all configured tier roots", path: placed.target_path });
      continue;
    }
    // Re-verify against the journal before touching anything (doc 03).
    const record = findRecord(cfg.journal_path, placed.journal_seq);
    if (!record || record.event !== "placed" || record.target_path !== placed.target_path) {
      errors.push({ code: "E_NO_JOURNAL", msg: "journal record missing or mismatched", path: root.dir });
      continue;
    }
    const plan = planFiles(root);
    const bad = await verifyTree(placed.target_path, plan.audio);
    if (bad) {
      errors.push({ code: "E_VERIFY", msg: `target re-verification failed: ${bad}`, path: placed.target_path });
      continue;
    }

    const relocate =
      opts.relocateDj && cfg.gc.dj_zone !== null &&
      sc.proposal !== null && cfg.gc.dj_collections.includes(sc.proposal.target_collection);
    const localAudio = sc.files.map((f) => join(root.dir, f.path)); // shadows included: all local copies go
    if (opts.dryRun) {
      data.push({
        id: sc.id, root_path: root.dir, dry_run: true,
        action: relocate ? "relocate_dj" : "delete", files: localAudio.length,
      });
      continue;
    }
    const destDir = relocate ? join(cfg.gc.dj_zone!, basename(placed.target_path)) : null;
    const disposal = disposeLocal(root, plan, destDir);
    if ("error" in disposal) {
      errors.push(disposal.error);
      continue;
    }
    const event = relocate ? "gc_relocated" : "gc_done";
    appendJournal(cfg.journal_path, {
      seq: nextSeq(cfg.journal_path), ts: isoLocal(), event, sidecar_id: sc.id,
      audio_hashes: plan.audio.map((a) => a.hash), target_path: placed.target_path, cli_version: CLI_VERSION,
    });
    sc.status = "gc_done";
    writeSidecarWithEvent(root, event, false);
    data.push({
      id: sc.id, root_path: root.dir, action: relocate ? "relocate_dj" : "delete", dj_dest: destDir,
      issues: disposal.issues,
    });
  }
  return finish(data, errors);
}
