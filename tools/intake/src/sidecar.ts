import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Proposal, ResolvedRoot, Sidecar } from "./types.ts";
import { isSafeRelPath } from "./util.ts";

export function readSidecar(path: string): Sidecar | null {
  try {
    const doc = JSON.parse(readFileSync(path, "utf8"));
    if (typeof doc !== "object" || doc === null || doc.schema !== 1) return null;
    // Income is untrusted: a hand-crafted sidecar must not be able to steer
    // execute/gc at a path outside its own release root. Reject any file entry
    // whose relative path escapes (absolute or contains a `..` segment).
    if (Array.isArray(doc.files)) {
      for (const f of doc.files) {
        if (typeof f?.path !== "string" || !isSafeRelPath(f.path)) return null;
      }
    }
    return doc as Sidecar;
  } catch {
    return null;
  }
}

export function serializeSidecar(s: Sidecar): string {
  return JSON.stringify(s, null, 2) + "\n";
}

/**
 * Write a resolved root's sidecar. If one already exists (--force re-resolve),
 * its id and history are preserved and a re-resolved event is appended.
 */
export function writeRoot(root: ResolvedRoot): { path: string; updated: boolean } {
  let target = join(root.dir, root.sidecarName);
  let sidecar = root.sidecar;
  const existing = readSidecar(target);
  if (existing) {
    const ts = sidecar.resolved_at;
    sidecar = {
      ...sidecar,
      id: existing.id,
      history: [...existing.history, { ts, event: "re-resolved", by: sidecar.history[0]!.by }],
    };
    if (root.sidecarName !== ".intake.json") {
      // Virtual sidecar names embed the id; keep the existing file name.
      target = join(root.dir, `.intake.${existing.id}.json`);
    }
  }
  writeFileSync(target, serializeSidecar(sidecar));
  return { path: target, updated: existing !== null };
}

export interface RankedSummary {
  collection: string;
  confidence: number;
}

export interface ProposalSummary {
  target_collection: string;
  confidence: number;
  ranked: RankedSummary[];
  assigned_by: Proposal["assigned_by"];
  target_path: string | null; // planned placement; null when no target can be built
}

export interface SidecarSummary {
  id: string;
  root_path: string;
  status: string;
  needs_review: boolean;
  cluster: { albumartist: string | null; album: string | null };
  proposal: ProposalSummary | null;
  placed: { verified: boolean; target_path: string } | null;
}

/** Doc 03: `proposal.ranked` carries the engine's top 5 candidates. */
export const RANKED_LIMIT = 5;

/**
 * The assignment engine's candidate list, in stored order (best first), top
 * RANKED_LIMIT, `score` reported as `confidence`. A user-only proposal
 * (`intake assign --collection` with no prior engine run) stores a synthetic
 * one-entry list that is not engine output, so it reports `[]`. A user
 * override on top of an engine proposal keeps the engine's list untouched, so
 * `target_collection` may be absent from it (doc 03 allows that).
 */
function rankedSummary(p: Proposal): RankedSummary[] {
  if (p.engine_version === "user" || !Array.isArray(p.ranked)) return [];
  return p.ranked.slice(0, RANKED_LIMIT).map((r) => ({ collection: r.collection, confidence: r.score }));
}

/** Summary shape per docs/intake/intake-03-contract-spec.md (`status --json`). */
export function summarize(sidecar: Sidecar, dir: string): SidecarSummary {
  const p = sidecar.proposal;
  return {
    id: sidecar.id,
    root_path: dir,
    status: sidecar.status,
    needs_review: sidecar.cluster.needs_review,
    cluster: { albumartist: sidecar.cluster.albumartist, album: sidecar.cluster.album },
    proposal: p
      ? {
        target_collection: p.target_collection,
        confidence: p.confidence,
        ranked: rankedSummary(p),
        assigned_by: p.assigned_by,
        target_path: p.target_path ?? null,
      }
      : null,
    placed: sidecar.placed ? { verified: sidecar.placed.verified, target_path: sidecar.placed.target_path } : null,
  };
}
