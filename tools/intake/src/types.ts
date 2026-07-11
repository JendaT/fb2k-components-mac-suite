// Sidecar schema v1 and resolver types, per docs/intake/intake-01-resolver-spec.md
// (status lifecycle and audio_hash per docs/intake/intake-03-contract-spec.md).

export const SCHEMA_VERSION = 1;
export const RESOLVER_VERSION = "0.1.0";

export type Status =
  | "new"
  | "resolved"
  | "proposed"
  | "approved"
  | "placing"
  | "placed"
  | "gc_done"
  | "rejected";

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
  identification: null;
  proposal: null;
  status: Status;
  history: HistoryEvent[];
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
