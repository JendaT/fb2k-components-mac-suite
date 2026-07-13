import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ResolvedRoot, Sidecar } from "./types.ts";

export function readSidecar(path: string): Sidecar | null {
  try {
    const doc = JSON.parse(readFileSync(path, "utf8"));
    if (typeof doc !== "object" || doc === null || doc.schema !== 1) return null;
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

export interface SidecarSummary {
  id: string;
  root_path: string;
  status: string;
  needs_review: boolean;
  cluster: { albumartist: string | null; album: string | null };
  proposal: { target_collection: string; confidence: number } | null;
  placed: { verified: boolean; target_path: string } | null;
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
    proposal: p ? { target_collection: p.target_collection, confidence: p.confidence } : null,
    placed: sidecar.placed ? { verified: sidecar.placed.verified, target_path: sidecar.placed.target_path } : null,
  };
}
