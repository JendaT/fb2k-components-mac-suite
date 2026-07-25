// P3 commands: propose, approve, execute, gc (doc 03 execute protocol +
// status lifecycle). Execute copies and verifies; it never moves or deletes
// income files — deletion is gc's job, after journal re-verification.

import {
  closeSync, copyFileSync, existsSync, fsyncSync, mkdirSync, openSync,
  readFileSync, readdirSync, renameSync, rmSync,
} from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { audioHash } from "./audioHash.ts";
import type { CommandResult, CommonOpts } from "./commands.ts";
import { cmdAssign, cmdIdentify, rootsFromRefs, writeSidecarWithEvent, type RootRef } from "./commands-p2.ts";
import { loadAssignConfig, loadIncome, loadP3Config, rulesDir } from "./config.ts";
import type { TierDef } from "./types.ts";
import { appendJournal, findPlacedRecord, findRecord, nextSeq } from "./journal.ts";
import { writeProvenance, type ProvenanceTags } from "./provenance.ts";
import { loadGenreMap, recordPlacement, saveGenreMap, type GenreMap } from "./rules.ts";
import { readSidecar } from "./sidecar.ts";
import type { JsonError } from "./types.ts";
import { IO_CONCURRENCY, isJunkFile, isoLocal, isSidecarName, mapLimit, sha1Hex, walkDirs } from "./util.ts";

const CLI_VERSION = "0.1.0";

function fail(code: string, msg: string, path: string | null = null): CommandResult {
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

function exitFor(errors: JsonError[], data: unknown[]): 0 | 1 | 2 {
  return errors.length === 0 ? 0 : data.length > 0 ? 1 : 2;
}

// ---- propose ------------------------------------------------------------------

export interface ProposeOpts extends CommonOpts {
  allResolved: boolean;
}

export async function cmdPropose(args: string[], opts: ProposeOpts): Promise<CommandResult> {
  const errors: JsonError[] = [];
  let roots: RootRef[];
  if (opts.allResolved) {
    // Auto mode: only clean resolved roots (never needs_review, never reject).
    roots = allRoots(errors).filter(
      (r) => r.sidecar.status === "resolved" && !r.sidecar.cluster.needs_review,
    );
  } else {
    if (args.length === 0) return fail("E_BAD_ARGS", "usage: intake propose <root...>|--all-resolved");
    roots = rootsFromRefs(args, errors);
  }
  if (roots.length === 0) return { data: [], errors, exitCode: errors.length ? 2 : 0 };

  const data: unknown[] = [];
  for (const root of roots) {
    if (root.sidecar.status !== "resolved") {
      errors.push({ code: "E_BAD_STATUS", msg: `cannot propose from status ${root.sidecar.status}`, path: root.dir });
      continue;
    }
    // propose = identify + assign + naming (doc 03); run whichever is missing.
    if (!root.sidecar.identification || !root.sidecar.proposal) {
      if (!root.sidecar.identification) await cmdIdentify([root.sidecar.id], opts);
      if (!root.sidecar.proposal) {
        await cmdAssign([root.sidecar.id], { ...opts, collection: null, by: null });
      }
      const reread = readSidecar(root.sidecarPath);
      if (reread) root.sidecar = reread;
    }
    const target = root.sidecar.proposal?.target_path;
    if (!target) {
      const why = root.sidecar.singles ? "singles slot pending" : !root.sidecar.proposal ? "no assignment evidence" : "no target path (tier reject?)";
      errors.push({ code: "E_NO_TARGET", msg: `cannot propose: ${why}`, path: root.dir });
      continue;
    }
    if (opts.allResolved && root.sidecar.cluster.needs_review) {
      // identify/assign may have raised the flag; auto mode skips those.
      data.push({ id: root.sidecar.id, root_path: root.dir, skipped: "needs_review" });
      continue;
    }
    root.sidecar.status = "proposed";
    writeSidecarWithEvent(root, "proposed", opts.dryRun);
    data.push({
      id: root.sidecar.id, root_path: root.dir, status: "proposed",
      target_path: target, confidence: root.sidecar.proposal!.confidence,
    });
  }
  return { data, errors, exitCode: exitFor(errors, data) };
}

// ---- approve ------------------------------------------------------------------

export interface ApproveOpts extends CommonOpts {
  batch: string | null;
}

export function cmdApprove(args: string[], opts: ApproveOpts): CommandResult {
  const refs = [...args];
  if (opts.batch) {
    if (!existsSync(opts.batch)) return fail("E_NOT_FOUND", "batch file not found", opts.batch);
    refs.push(...readFileSync(opts.batch, "utf8").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#")));
  }
  if (refs.length === 0) return fail("E_BAD_ARGS", "usage: intake approve <root...>|--batch <file>");

  const errors: JsonError[] = [];
  const roots = rootsFromRefs(refs, errors);
  const data: unknown[] = [];
  for (const root of roots) {
    if (root.sidecar.status !== "proposed") {
      errors.push({ code: "E_BAD_STATUS", msg: `cannot approve from status ${root.sidecar.status}`, path: root.dir });
      continue;
    }
    root.sidecar.status = "approved";
    writeSidecarWithEvent(root, "approved", opts.dryRun);
    data.push({ id: root.sidecar.id, root_path: root.dir, status: "approved" });
  }
  return { data, errors, exitCode: exitFor(errors, data) };
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
    return (await audioHash(p)).hash !== a.hash ? `hash mismatch: ${a.to}` : null;
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

export async function cmdExecute(args: string[], opts: ExecuteOpts): Promise<CommandResult> {
  const cfg = loadP3Config();
  if (!cfg.journal_path) return fail("E_NO_JOURNAL", "structure.yaml journal.path is not configured");
  const tiers = loadAssignConfig().tiers;
  const errors: JsonError[] = [];
  const wantStatus = opts.resume ? "placing" : "approved";
  let roots: RootRef[];
  if (opts.approved || opts.resume) {
    roots = allRoots(errors).filter((r) => r.sidecar.status === wantStatus);
  } else {
    if (args.length === 0) return fail("E_BAD_ARGS", "usage: intake execute <root...>|--approved [--resume]");
    roots = rootsFromRefs(args, errors);
  }
  if (roots.length === 0) return { data: [], errors, exitCode: errors.length ? 2 : 0 };

  const batch = "b" + sha1Hex(isoLocal() + ":" + process.pid).slice(0, 10);
  const data: unknown[] = [];
  // Read the genre map at most once per command (it was re-read and re-parsed
  // for every placed root); still saved per placement, so a crash mid-batch
  // cannot lose the counts of releases already in the library.
  const rdir = rulesDir();
  let genre: GenreMap | null = null;

  for (const root of roots) {
    const sc = root.sidecar;
    const target = sc.proposal?.target_path;

    if (opts.resume && sc.status === "placing") {
      const outcome = await resumeRoot(root, cfg.journal_path, opts);
      data.push(outcome);
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
      rmSync(tmp, { recursive: true, force: true });
      mkdirSync(tmp, { recursive: true });
      const tags: ProvenanceTags = {
        INTAKE_DATE: isoLocal().slice(0, 10),
        INTAKE_SOURCE: sc.source.source_type,
        INTAKE_BATCH: batch,
      };
      for (const item of [...plan.audio, ...plan.artifacts]) {
        const dest = join(tmp, item.to);
        mkdirSync(dirname(dest), { recursive: true });
        copyFileSync(item.from, dest);
      }
      for (const a of plan.audio) {
        const r = await writeProvenance(join(tmp, a.to), tags);
        if (r.issue) issues.push(r.issue);
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
      if (rdir && artist && sc.proposal) {
        genre ??= loadGenreMap(rdir);
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
        rmSync(tmp, { recursive: true, force: true });
        sc.status = "approved";
        writeSidecarWithEvent(root, "execute_failed", false);
        errors.push({ code: "E_VERIFY", msg, path: root.dir });
      }
    }
  }
  return { data, errors, exitCode: exitFor(errors, data) };
}

/** Crash recovery: placing -> placed (target verifies) or back to approved. */
async function resumeRoot(root: RootRef, journalPath: string, opts: CommonOpts): Promise<unknown> {
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
  if (target) rmSync(join(dirname(target), `.intake-tmp-${sc.id}`), { recursive: true, force: true });
  sc.status = "approved";
  writeSidecarWithEvent(root, "execute_reverted", opts.dryRun);
  return { id: sc.id, root_path: root.dir, resumed: "reverted_to_approved" };
}

// ---- gc -----------------------------------------------------------------------

export interface GcOpts extends CommonOpts {
  age: number | null; // days
  relocateDj: boolean;
}

export async function cmdGc(args: string[], opts: GcOpts): Promise<CommandResult> {
  const cfg = loadP3Config();
  if (!cfg.journal_path) return fail("E_NO_JOURNAL", "structure.yaml journal.path is not configured");
  const tiers = loadAssignConfig().tiers;
  const errors: JsonError[] = [];
  const roots = (args.length > 0 ? rootsFromRefs(args, errors) : allRoots(errors)).filter(
    (r) => r.sidecar.status === "placed",
  );
  const data: unknown[] = [];

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
    let destDir: string | null = null;
    if (relocate) {
      destDir = join(cfg.gc.dj_zone!, basename(placed.target_path));
      // Keep each file's path relative to the release root. Flattening to
      // basename() collides whenever discs number tracks independently
      // (CD1/01.flac + CD2/01.flac), and renameSync overwrites in silence.
      for (const f of sc.files) {
        const from = join(root.dir, f.path);
        if (!existsSync(from)) continue;
        const to = join(destDir, f.path);
        mkdirSync(dirname(to), { recursive: true });
        renameSync(from, to);
      }
    } else {
      for (const p of localAudio.filter(existsSync)) rmSync(p);
    }
    if (!sc.virtual) {
      // Whole-dir root: artifacts were copied at execute; clear them and any
      // now-empty disc dirs. The sidecar stays as a gc_done tombstone.
      for (const a of plan.artifacts) rmSync(join(root.dir, a.to), { force: true });
      for (const e of walkDirs(root.dir)) {
        if (e.path !== root.dir && readdirSync(e.path).filter((n) => !isJunkFile(n)).length === 0)
          rmSync(e.path, { recursive: true, force: true });
      }
    }
    const event = relocate ? "gc_relocated" : "gc_done";
    appendJournal(cfg.journal_path, {
      seq: nextSeq(cfg.journal_path), ts: isoLocal(), event, sidecar_id: sc.id,
      audio_hashes: plan.audio.map((a) => a.hash), target_path: placed.target_path, cli_version: CLI_VERSION,
    });
    sc.status = "gc_done";
    writeSidecarWithEvent(root, event, false);
    data.push({ id: sc.id, root_path: root.dir, action: relocate ? "relocate_dj" : "delete", dj_dest: destDir });
  }
  return { data, errors, exitCode: exitFor(errors, data) };
}
