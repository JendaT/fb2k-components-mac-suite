// Release-root resolver, passes 1-4 per docs/intake/intake-01-resolver-spec.md.
// Pure: computes sidecars, never writes or mutates files (writing is the
// caller's job so --dry-run stays trivial).

import { existsSync, readdirSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { audioHash } from "./audioHash.ts";
import { parseDirName } from "./naming.ts";
import { readSnapshot, parseFilename, type AudioSnapshot } from "./tags.ts";
import type {
  Cluster, FileRecord, ResolvedRoot, ResolverConfig, Sidecar, Signals, Tier,
} from "./types.ts";
import { RESOLVER_VERSION, SCHEMA_VERSION } from "./types.ts";
import { DISC_DIR_RE, discNumberFromDirName, ext, IO_CONCURRENCY, isoLocal, makeId, mapLimit, normAlbum, normKey, round2, walkDirs, type DirEntry } from "./util.ts";

export interface ResolveContext {
  config: ResolverConfig;
  income: { name: string | null; source_type: string; root: string } | null;
  force: boolean;
  now: () => Date;
}

export interface ResolveResult {
  roots: ResolvedRoot[];
  kept: string[]; // dirs with pre-existing sidecars, trusted (no --force)
}

interface CandFile {
  rel: string; // relative to the candidate dir
  abs: string;
  snap: AudioSnapshot;
  hash: string;
  hashIssues: string[];
  shadow: boolean;
}

interface Candidate {
  dir: string;
  files: CandFile[];
  artifactNames: string[]; // non-audio files at the root (and disc dirs)
  discs: { dir: string; disc: number }[] | null;
}

const UNTAGGED = "\u0000untagged";

function clusterKey(f: CandFile): string {
  const aa = normKey(f.snap.tags.albumartist);
  const al = normAlbum(f.snap.tags.album);
  const ar = normKey(f.snap.tags.artist);
  if (aa) return `${aa}|${al}`;
  if (al) return `*|${al}`;
  if (ar) return `${ar}|`;
  return UNTAGGED;
}

function majority<T>(values: (T | null)[]): T | null {
  const counts = new Map<T, number>();
  for (const v of values) if (v != null) counts.set(v, (counts.get(v) ?? 0) + 1);
  let best: T | null = null;
  let n = 0;
  for (const [v, c] of counts) if (c > n) { best = v; n = c; }
  return best;
}

function trackOf(f: CandFile): number | null {
  return f.snap.tags.tracknumber ?? parseFilename(basename(f.rel)).tracknumber;
}

/** Mark lossy duplicates of lossless tracks as quality shadows (same disc+track). */
function markShadows(files: CandFile[]): void {
  const groups = new Map<string, CandFile[]>();
  for (const f of files) {
    const t = trackOf(f);
    if (t == null) continue;
    const key = `${f.snap.tags.disc ?? 1}:${t}:${normKey(f.snap.tags.title ?? "")}`;
    const g = groups.get(key) ?? [];
    g.push(f);
    groups.set(key, g);
  }
  for (const g of groups.values()) {
    if (g.length < 2) continue;
    const rank = (f: CandFile) =>
      (f.snap.lossless ? 1_000_000 : 0) +
      (f.snap.bit_depth ?? 0) * 1000 +
      (f.snap.sample_rate ?? 0) / 1000 +
      (f.snap.bitrate ?? 0);
    const primary = g.reduce((a, b) => (rank(b) > rank(a) ? b : a));
    for (const f of g) if (f !== primary) f.shadow = true;
  }
}

const ART_RE = /^(cover|folder|front)\.(jpe?g|png|gif|webp)$/i;

function artifactScore(names: string[]): number {
  let score = 0;
  const exts = new Set(names.map(ext));
  if (names.some((n) => ART_RE.test(n))) score += 0.5;
  if (exts.has("cue")) score += 0.5;
  if (exts.has("log")) score += 0.25;
  if (exts.has("nfo")) score += 0.25;
  if (exts.has("m3u") || exts.has("m3u8")) score += 0.25;
  return Math.min(1, score);
}

function seqScore(files: CandFile[]): number {
  const byDisc = new Map<number, Set<number>>();
  const countByDisc = new Map<number, number>();
  for (const f of files) {
    const d = f.snap.tags.disc ?? 1;
    countByDisc.set(d, (countByDisc.get(d) ?? 0) + 1);
    const t = trackOf(f);
    if (t == null || t < 1) continue;
    const s = byDisc.get(d) ?? new Set<number>();
    s.add(t);
    byDisc.set(d, s);
  }
  if (countByDisc.size === 0) return 0;
  let total = 0;
  for (const [d, count] of countByDisc) {
    const tracks = byDisc.get(d) ?? new Set<number>();
    const n = Math.max(count, tracks.size === 0 ? 0 : [...tracks].reduce((m, t) => Math.max(m, t), -Infinity));
    const inRange = [...tracks].filter((t) => t >= 1 && t <= n).length;
    total += n === 0 ? 0 : inRange / n;
  }
  return total / countByDisc.size;
}

function qualityHomog(files: CandFile[]): number {
  if (files.length === 0) return 0;
  const profiles = files.map((f) => `${f.snap.codec}|${f.snap.sample_rate}|${f.snap.bit_depth}`);
  const top = majority(profiles);
  return profiles.filter((p) => p === top).length / files.length;
}

function tierOf(files: CandFile[], cfg: ResolverConfig): { tier: Tier; issues: string[] } {
  const issues: string[] = [];
  const primary = files.filter((f) => !f.shadow);
  if (primary.length === 0) return { tier: "reject", issues: ["no_audio_files"] };
  const isDsd = (f: CandFile) => f.snap.codec === "dsf" || f.snap.codec === "dff";
  const isHires = (f: CandFile) =>
    f.snap.lossless &&
    ((f.snap.bit_depth ?? 0) > cfg.hires.bit_depth_over || (f.snap.sample_rate ?? 0) > cfg.hires.sample_rate_over);
  if (primary.some((f) => isDsd(f) || isHires(f))) return { tier: "uhq", issues };
  if (primary.every((f) => f.snap.lossless)) return { tier: "hq", issues };
  const lossy = primary.filter((f) => !f.snap.lossless);
  if (lossy.every((f) => (f.snap.bitrate ?? 0) >= cfg.lossy_tolerance_kbps)) {
    issues.push("lossy");
    return { tier: "hq", issues };
  }
  issues.push("below_lossy_tolerance");
  return { tier: "reject", issues };
}

function toFileRecord(f: CandFile): FileRecord {
  const rec: FileRecord = {
    path: f.rel,
    audio_hash: f.hash,
    codec: f.snap.codec,
    lossless: f.snap.lossless,
    sample_rate: f.snap.sample_rate,
    bit_depth: f.snap.bit_depth,
    bitrate: f.snap.bitrate,
    duration: f.snap.duration,
    tags: f.snap.tags,
  };
  if (f.shadow) rec.quality_shadow = true;
  return rec;
}

export class Resolver {
  constructor(private ctx: ResolveContext) {}

  private relFromIncome(dir: string): string {
    const base = this.ctx.income?.root;
    return base ? relative(base, dir) || "." : basename(dir);
  }

  private archiveFor(dir: string): string | null {
    // Inside a <name>.unpacked dir? Reference the original archive, relative
    // to the sidecar's directory.
    const parts = dir.split("/");
    for (let i = parts.length - 1; i >= 0; i--) {
      const seg = parts[i]!;
      if (!seg.endsWith(".unpacked")) continue;
      const container = parts.slice(0, i).join("/");
      const stem = seg.slice(0, -".unpacked".length);
      for (const arcExt of ["zip", "7z", "rar"]) {
        const cand = join(container, `${stem}.${arcExt}`);
        if (existsSync(cand)) return relative(dir, cand);
      }
    }
    return null;
  }

  private buildSidecar(opts: {
    dir: string;
    files: CandFile[];
    discs: { dir: string; disc: number }[] | null;
    virtual: boolean;
    singles: boolean;
    artifactNames: string[];
    nameParseSource: string; // dir name used for the name_parse signal
    extraIssues?: string[];
  }): ResolvedRoot {
    const { config } = this.ctx;
    const primary = opts.files.filter((f) => !f.shadow);
    const tagged = primary.filter((f) => clusterKey(f) !== UNTAGGED);

    // Signals
    let signals: Signals;
    const parsed = parseDirName(opts.nameParseSource);
    if (opts.singles) {
      signals = {
        purity: tagged.length > 0 ? 1 : 0,
        seq: 1,
        artifacts: 0,
        name_parse: 0,
        quality_homog: 1,
      };
    } else {
      const keys = tagged.map(clusterKey);
      const top = majority(keys);
      signals = {
        purity: primary.length === 0 ? 0 : keys.filter((k) => k === top).length / primary.length,
        seq: seqScore(primary),
        artifacts: opts.virtual ? 0 : artifactScore(opts.artifactNames),
        name_parse: opts.virtual ? 0 : (parsed?.score ?? 0),
        quality_homog: qualityHomog(primary),
      };
    }
    signals = {
      purity: round2(signals.purity),
      seq: round2(signals.seq),
      artifacts: round2(signals.artifacts),
      name_parse: round2(signals.name_parse),
      quality_homog: round2(signals.quality_homog),
    };
    const w = config.weights;
    const confidence = round2(
      signals.purity * w.purity +
        signals.seq * w.seq +
        signals.artifacts * w.artifacts +
        signals.name_parse * w.name_parse +
        signals.quality_homog * w.quality_homog,
    );

    // Cluster display values: tags first, dir-name parse as fallback.
    const albumartist =
      majority(primary.map((f) => f.snap.tags.albumartist)) ??
      (new Set(primary.map((f) => normKey(f.snap.tags.artist)).filter(Boolean)).size === 1
        ? majority(primary.map((f) => f.snap.tags.artist))
        : null) ??
      parsed?.artist ??
      null;
    const album = majority(primary.map((f) => f.snap.tags.album)) ?? parsed?.album ?? null;

    const resolved = confidence >= config.thresholds.resolved;
    const review = !resolved && confidence >= config.thresholds.review;
    const { tier, issues } = tierOf(opts.files, config);
    for (const f of opts.files) for (const iss of f.hashIssues) if (!issues.includes(iss)) issues.push(iss);
    if (opts.files.some((f) => f.shadow)) {
      const codecs = [...new Set(opts.files.filter((f) => f.shadow).map((f) => f.snap.codec))].sort();
      issues.push(`quality_shadow_set:${codecs.join(",")}`);
    }
    for (const iss of opts.extraIssues ?? []) issues.push(iss);

    const needsReview = review || tier === "reject" || opts.singles || confidence < config.thresholds.review;
    const status = resolved || review ? "resolved" : "new";

    const cluster: Cluster = {
      albumartist,
      album: opts.singles ? null : album,
      confidence,
      needs_review: needsReview,
      signals,
    };

    const rel = this.relFromIncome(opts.dir);
    const idSeed = `${this.ctx.income?.name ?? ""}:${rel}:${opts.virtual ? opts.files.map((f) => f.rel).join(",") : ""}`;
    const id = makeId(idSeed);
    const ts = isoLocal(this.ctx.now());
    const sidecar: Sidecar = {
      schema: SCHEMA_VERSION,
      id,
      resolver_version: RESOLVER_VERSION,
      resolved_at: ts,
      source: {
        income_folder: this.ctx.income?.name ?? null,
        source_type: this.ctx.income?.source_type ?? "unknown",
        archive: this.archiveFor(opts.dir),
      },
      virtual: opts.virtual,
      files: opts.files.sort((a, b) => a.rel.localeCompare(b.rel)).map(toFileRecord),
      discs: opts.discs,
      cluster,
      quality: { tier_eligible: tier, issues },
      identification: null,
      proposal: null,
      status,
      history: [{ ts, event: status === "resolved" ? "resolved" : "discovered", by: `intake@${RESOLVER_VERSION}` }],
    };
    if (opts.singles) sidecar.singles = true;
    return {
      dir: opts.dir,
      sidecarName: opts.virtual ? `.intake.${id}.json` : ".intake.json",
      sidecar,
    };
  }

  private hasSidecar(dir: string): boolean {
    try {
      return readdirSync(dir).some((n) => n === ".intake.json" || /^\.intake\.[a-z0-9_]+\.json$/i.test(n));
    } catch {
      return false;
    }
  }

  async resolveTree(target: string): Promise<ResolveResult> {
    const entries = walkDirs(target);
    const byPath = new Map(entries.map((e) => [e.path, e]));
    const roots: ResolvedRoot[] = [];
    const kept: string[] = [];

    // Pass 1 — candidates: dirs directly containing audio. Snapshots (tag
    // headers) are needed here for the pass-2 merge decisions; audio_hash
    // (a full-file read) is deferred to emit time so a directory that already
    // has a sidecar — kept below without --force — is never re-hashed.
    let candidates: Candidate[] = [];
    for (const e of entries) {
      if (e.audioFiles.length === 0) continue;
      const files: CandFile[] = await mapLimit(e.audioFiles, IO_CONCURRENCY, async (name) => {
        const abs = join(e.path, name);
        return { rel: name, abs, snap: await readSnapshot(abs), hash: "", hashIssues: [], shadow: false };
      });
      candidates.push({ dir: e.path, files, artifactNames: [...e.otherFiles], discs: null });
    }

    // Pass 2 — merge disc-named sibling candidates into their parent.
    const byDir = new Map(candidates.map((c) => [c.dir, c]));
    const mergedAway = new Set<string>();
    const parents = new Map<string, Candidate[]>();
    for (const c of candidates) {
      const name = basename(c.dir);
      if (!DISC_DIR_RE.test(name)) continue;
      const parent = c.dir.slice(0, -(name.length + 1));
      if (!byPath.has(parent)) continue; // parent outside the walk
      const list = parents.get(parent) ?? [];
      list.push(c);
      parents.set(parent, list);
    }
    for (const [parent, children] of parents) {
      const clusters = children.map((c) => {
        const tagged = c.files.filter((f) => clusterKey(f) !== UNTAGGED);
        return tagged.length > 0 ? majority(tagged.map(clusterKey)) : null;
      });
      const allUntagged = clusters.every((k) => k === null);
      const oneCluster = !allUntagged && new Set(clusters.filter(Boolean)).size === 1 && !clusters.includes(null);
      const parentParses = parseDirName(basename(parent)) !== null;
      if (!(oneCluster || (allUntagged && parentParses))) continue;

      const parentCand = byDir.get(parent);
      const merged: Candidate = parentCand ?? {
        dir: parent,
        files: [],
        artifactNames: [...(byPath.get(parent)?.otherFiles ?? [])],
        discs: null,
      };
      merged.discs = [];
      children
        .sort((a, b) => a.dir.localeCompare(b.dir))
        .forEach((c, i) => {
          const dirName = basename(c.dir);
          const disc =
            discNumberFromDirName(dirName) ?? majority(c.files.map((f) => f.snap.tags.disc)) ?? i + 1;
          merged.discs!.push({ dir: dirName, disc });
          for (const f of c.files) {
            merged.files.push({ ...f, rel: `${dirName}/${f.rel}`, snap: { ...f.snap, tags: { ...f.snap.tags, disc: f.snap.tags.disc ?? disc } } });
          }
          merged.artifactNames.push(...c.artifactNames);
          mergedAway.add(c.dir);
        });
      if (!parentCand) candidates.push(merged);
    }
    candidates = candidates.filter((c) => !mergedAway.has(c.dir));

    // Passes 3 + 4 per candidate.
    for (const c of candidates) {
      if (this.hasSidecar(c.dir) && !this.ctx.force) {
        kept.push(c.dir);
        continue;
      }
      // Emit-time hashing: only candidates that actually produce a sidecar are
      // read in full (deferred from pass 1). Merged-parent candidates carry the
      // disc children's files, so this covers them too.
      const unhashed = c.files.filter((f) => !f.hash);
      const hashes = await mapLimit(unhashed, IO_CONCURRENCY, (f) => audioHash(f.abs));
      unhashed.forEach((f, i) => {
        f.hash = hashes[i]!.hash;
        f.hashIssues = hashes[i]!.issues;
      });
      markShadows(c.files);
      const emit = (opts: Parameters<Resolver["buildSidecar"]>[0]) => roots.push(this.buildSidecar(opts));

      if (c.discs) {
        // Deliberately merged; never split a multi-disc set.
        emit({ dir: c.dir, files: c.files, discs: c.discs, virtual: false, singles: false, artifactNames: c.artifactNames, nameParseSource: basename(c.dir) });
        continue;
      }

      const clusters = new Map<string, CandFile[]>();
      for (const f of c.files) {
        const k = clusterKey(f);
        const g = clusters.get(k) ?? [];
        g.push(f);
        clusters.set(k, g);
      }
      const taggedKeys = [...clusters.keys()].filter((k) => k !== UNTAGGED);
      const multi = taggedKeys.filter((k) => clusters.get(k)!.length >= 2);

      if (multi.length > 1) {
        // Pass 3 — split into virtual roots; leftovers become singles.
        const inMulti = new Set(multi.flatMap((k) => clusters.get(k)!));
        for (const k of multi.sort()) {
          emit({ dir: c.dir, files: clusters.get(k)!, discs: null, virtual: true, singles: false, artifactNames: [], nameParseSource: "" });
        }
        for (const f of c.files.filter((f) => !inMulti.has(f))) {
          emit({ dir: c.dir, files: [f], discs: null, virtual: true, singles: true, artifactNames: [], nameParseSource: "" });
        }
      } else if (multi.length === 0 && taggedKeys.length >= 2) {
        // All singletons with distinct tags: a loose-singles directory.
        for (const f of c.files) {
          emit({ dir: c.dir, files: [f], discs: null, virtual: true, singles: true, artifactNames: [], nameParseSource: "" });
        }
      } else {
        emit({ dir: c.dir, files: c.files, discs: null, virtual: false, singles: false, artifactNames: c.artifactNames, nameParseSource: basename(c.dir) });
      }
    }

    // Edge case: iso / bin+cue images are flagged, never unpacked.
    for (const e of entries) {
      for (const name of e.otherFiles) {
        const x = ext(name);
        const isIso = x === "iso" || (x === "bin" && e.otherFiles.some((n) => ext(n) === "cue"));
        if (!isIso) continue;
        if (this.hasSidecar(e.path) && !this.ctx.force) {
          if (!kept.includes(e.path)) kept.push(e.path);
          continue;
        }
        const root = this.buildIsoSidecar(e, name);
        roots.push(root);
      }
    }

    return { roots, kept };
  }

  private buildIsoSidecar(e: DirEntry, name: string): ResolvedRoot {
    const parsed = parseDirName(name.replace(/\.[^.]+$/, ""));
    const ts = isoLocal(this.ctx.now());
    const rel = this.relFromIncome(join(e.path, name));
    const id = makeId(`${this.ctx.income?.name ?? ""}:${rel}:iso`);
    const sidecar: Sidecar = {
      schema: SCHEMA_VERSION,
      id,
      resolver_version: RESOLVER_VERSION,
      resolved_at: ts,
      source: {
        income_folder: this.ctx.income?.name ?? null,
        source_type: this.ctx.income?.source_type ?? "unknown",
        archive: name,
      },
      virtual: true,
      files: [],
      discs: null,
      cluster: {
        albumartist: parsed?.artist ?? null,
        album: parsed?.album ?? null,
        confidence: 0,
        needs_review: true,
        signals: { purity: 0, seq: 0, artifacts: 0, name_parse: parsed?.score ?? 0, quality_homog: 0 },
      },
      quality: { tier_eligible: "reject", issues: ["iso_needs_manual_unpack"] },
      identification: null,
      proposal: null,
      status: "new",
      history: [{ ts, event: "discovered", by: `intake@${RESOLVER_VERSION}` }],
    };
    return { dir: e.path, sidecarName: `.intake.${id}.json`, sidecar };
  }
}
