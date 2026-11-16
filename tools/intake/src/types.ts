// Sidecar schema v1 and resolver types, per docs/intake/intake-01-resolver-spec.md
// (status lifecycle and audio_hash per docs/intake/intake-03-contract-spec.md).

export const SCHEMA_VERSION = 1;
export const RESOLVER_VERSION = "0.2.0";
/** CLI semver (doc 03 Versioning): `intake version` and journal records. */
export const CLI_VERSION = "0.3.0";

export type Status =
  | "new"
  | "resolved"
  | "proposed"
  | "approved"
  | "placing"
  | "placed"
  | "gc_done"
  | "rejected";

/**
 * Doc 03 "Legal source statuses": nothing has reached the library yet. The
 * legal sources of `identify` and `assign`.
 */
export const PRE_LIBRARY_STATUSES: ReadonlySet<Status> = new Set<Status>(["new", "resolved", "proposed", "approved"]);

/**
 * Doc 03 "Legal source statuses": a rebuild (`resolve --force`, and `scan
 * --force`, which resolves the same way) is refused on these, since it would
 * drop the placement record and its journal link.
 */
export const NO_REBUILD_STATUSES: ReadonlySet<Status> = new Set<Status>(["placing", "placed", "gc_done"]);

export type Tier = "uhq" | "hq" | "reject";

export interface TagSnapshot {
  albumartist: string | null;
  artist: string | null;
  album: string | null;
  title: string | null;
  tracknumber: number | null;
  disc: number | null;
  date: string | null;
}

export interface FileRecord {
  path: string; // relative to the sidecar's directory
  audio_hash: string;
  codec: string;
  lossless: boolean;
  sample_rate: number | null;
  bit_depth: number | null;
  bitrate: number | null; // kbps, lossy only
  duration: number | null; // seconds
  tags: TagSnapshot;
  quality_shadow?: true;
}

export interface Signals {
  purity: number;
  seq: number;
  artifacts: number;
  name_parse: number;
  quality_homog: number;
}

export interface Cluster {
  albumartist: string | null;
  album: string | null;
  confidence: number;
  needs_review: boolean;
  signals: Signals;
}

export interface HistoryEvent {
  ts: string;
  event: string;
  by: string;
  reason?: string; // `rejected` entries only, when `intake reject --reason` was given
}

// ---- identification (doc 02, identify stage) ------------------------------

export interface IdentCandidate {
  source: "discogs" | "mb";
  release_id: string | null;
  artist: string | null;
  album: string | null;
  year: string | null;
  label: string | null;
  catno: string | null;
  distance: number | null;
  track_mapping: Record<string, string> | null;
}

export type IdentStatus = "fast_path" | "shim" | "unconfirmed" | "unidentified";

export interface Identification {
  status: IdentStatus;
  source: "discogs" | "mb" | null;
  release_id: string | null;
  artist: string | null;
  album: string | null;
  year: string | null;
  label: string | null;
  catno: string | null;
  styles: string[];
  genres: string[];
  distance: number | null;
  grammar: string | null; // which folder-name grammar matched (fast path)
  candidates: IdentCandidate[] | null; // top 3 when ambiguous
  identified_at: string;
  /**
   * Each evidence source that failed, e.g. `discogs_unreachable` or the beets
   * shim's error text (`beets_unavailable`, `shim_unavailable`), so an
   * `unconfirmed` status is not read as checked and not found. Present only
   * when non-empty.
   */
  issues?: string[];
}

// ---- proposal (doc 02, assign stage) ---------------------------------------

export interface RankedFolder {
  collection: string;
  score: number;
  evidence: {
    artist_prior: number;
    label_prior: number;
    similar_vote: number;
    style_hint: number;
  };
}

export type StructureSlot = "artist" | "releases" | "compilations" | "singles";

export interface Proposal {
  engine_version: string;
  ranked: RankedFolder[];
  target_collection: string;
  confidence: number;
  margin: number;
  target_path: string | null; // null when tier is reject (no legal target)
  structure_slot: StructureSlot;
  assigned_by: "engine" | "user";
  alternates_shown: boolean;
  /**
   * Doc 02 "Existing library folders": the artist's existing releases in
   * `[Releases]` or loose in the collection that this placement makes belong
   * in an artist folder, relative to the tier root. Present only when
   * non-empty; nothing is moved. Not part of the `status` summary.
   */
  restructure_candidates?: string[];
}

export interface Sidecar {
  schema: typeof SCHEMA_VERSION;
  id: string;
  resolver_version: string;
  resolved_at: string;
  source: {
    income_folder: string | null;
    source_type: string;
    archive: string | null;
  };
  virtual: boolean;
  singles?: true;
  files: FileRecord[];
  discs: { dir: string; disc: number }[] | null;
  cluster: Cluster;
  quality: { tier_eligible: Tier; issues: string[] };
  identification: Identification | null;
  proposal: Proposal | null;
  placed?: PlacedInfo;
  status: Status;
  history: HistoryEvent[];
}

// ---- execute / gc (doc 03 protocol) -----------------------------------------

export interface PlacedInfo {
  target_path: string;
  verified: boolean;
  journal_seq: number;
}

export interface JournalRecord {
  seq: number;
  ts: string;
  event: string; // placed | gc_done | gc_relocated
  sidecar_id: string;
  audio_hashes: string[];
  target_path: string;
  cli_version: string;
}

export interface P3Config {
  journal_path: string | null;
  gc: { dj_zone: string | null; dj_collections: string[] };
}

// A resolved root before sidecar serialization.
export interface ResolvedRoot {
  dir: string; // absolute path of the directory holding the sidecar
  sidecarName: string; // ".intake.json" or ".intake.<id>.json"
  sidecar: Sidecar;
}

export interface IncomeFolder {
  name: string;
  path: string;
  source_type: string;
}

export interface ResolverConfig {
  weights: Signals;
  thresholds: { resolved: number; review: number };
  lossy_tolerance_kbps: number;
  hires: { bit_depth_over: number; sample_rate_over: number };
}

export interface TierDef {
  root: string;
  gate: string;
  growth: string;
}

export interface AssignConfig {
  weights: { artist: number; label: number; similar: number; style: number };
  short_circuit: { min_releases: number; confidence: number };
  needs_review: { confidence: number; margin: number };
  shim_accept_distance: number;
  naming: {
    release: string; // template with {artist} {year} {album} {label} {catno}
    release_no_label: string;
  };
  tiers: Record<string, TierDef>; // "music.uhq" | "music.hq" | ...
}

export interface JsonError {
  code: string;
  msg: string;
  path: string | null;
}

export interface Envelope {
  ok: boolean;
  data: unknown;
  errors: JsonError[];
}
