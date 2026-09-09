import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import type { AssignConfig, IncomeFolder, P3Config, ResolverConfig, TierDef } from "./types.ts";

export const DEFAULT_CONFIG: ResolverConfig = {
  weights: { purity: 0.35, seq: 0.25, artifacts: 0.15, name_parse: 0.15, quality_homog: 0.1 },
  thresholds: { resolved: 0.8, review: 0.5 },
  lossy_tolerance_kbps: 256,
  hires: { bit_depth_over: 16, sample_rate_over: 48000 },
};

/** Locate the rules dir: INTAKE_RULES_DIR env, else ~/.config/intake/config.toml. */
export function rulesDir(): string | null {
  const env = process.env.INTAKE_RULES_DIR;
  if (env) return resolve(env);
  const tomlPath = join(homedir(), ".config", "intake", "config.toml");
  if (existsSync(tomlPath)) {
    try {
      const parsed = Bun.TOML.parse(readFileSync(tomlPath, "utf8")) as Record<string, unknown>;
      const dir = parsed["rules_dir"];
      if (typeof dir === "string") return resolve(dir.replace(/^~(?=\/)/, homedir()));
    } catch {
      // fall through to null
    }
  }
  return null;
}

function readYaml(path: string): Record<string, unknown> | null {
  if (!existsSync(path)) return null;
  const parsed = Bun.YAML.parse(readFileSync(path, "utf8"));
  return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : null;
}

/** Load resolver config: structure.yaml `resolver:` section merged over defaults. */
export function loadConfig(dir: string | null = rulesDir()): ResolverConfig {
  const cfg: ResolverConfig = structuredClone(DEFAULT_CONFIG);
  if (!dir) return cfg;
  const doc = readYaml(join(dir, "structure.yaml"));
  const r = doc?.["resolver"] as Record<string, unknown> | undefined;
  if (!r) return cfg;
  const weights = r["weights"] as Partial<ResolverConfig["weights"]> | undefined;
  if (weights) Object.assign(cfg.weights, weights);
  const thresholds = r["thresholds"] as Partial<ResolverConfig["thresholds"]> | undefined;
  if (thresholds) Object.assign(cfg.thresholds, thresholds);
  if (typeof r["lossy_tolerance_kbps"] === "number") cfg.lossy_tolerance_kbps = r["lossy_tolerance_kbps"];
  const hires = r["hires"] as Partial<ResolverConfig["hires"]> | undefined;
  if (hires) Object.assign(cfg.hires, hires);
  return cfg;
}

export const DEFAULT_ASSIGN_CONFIG: AssignConfig = {
  weights: { artist: 0.5, label: 0.25, similar: 0.15, style: 0.1 },
  short_circuit: { min_releases: 2, confidence: 0.95 },
  needs_review: { confidence: 0.6, margin: 0.2 },
  shim_accept_distance: 0.15,
  naming: {
    release: "{artist} [{year}] {album} ({label}; {catno})",
    release_no_label: "{artist} [{year}] {album}",
  },
  tiers: {},
};

/** Load assign config: structure.yaml `assign:`/`naming:`/`tiers:` over defaults. */
export function loadAssignConfig(dir: string | null = rulesDir()): AssignConfig {
  const cfg: AssignConfig = structuredClone(DEFAULT_ASSIGN_CONFIG);
  if (!dir) return cfg;
  const doc = readYaml(join(dir, "structure.yaml"));
  if (!doc) return cfg;
  const a = doc["assign"] as Record<string, unknown> | undefined;
  if (a) {
    const weights = a["weights"] as Partial<AssignConfig["weights"]> | undefined;
    if (weights) Object.assign(cfg.weights, weights);
    const sc = a["short_circuit"] as Partial<AssignConfig["short_circuit"]> | undefined;
    if (sc) Object.assign(cfg.short_circuit, sc);
    const nr = a["needs_review"] as Partial<AssignConfig["needs_review"]> | undefined;
    if (nr) Object.assign(cfg.needs_review, nr);
    if (typeof a["shim_accept_distance"] === "number") cfg.shim_accept_distance = a["shim_accept_distance"];
  }
  const naming = doc["naming"] as Partial<AssignConfig["naming"]> | undefined;
  if (naming) Object.assign(cfg.naming, naming);
  const tiers = doc["tiers"] as Record<string, unknown> | undefined;
  if (tiers) {
    for (const [name, def] of Object.entries(tiers)) {
      if (typeof def !== "object" || def === null) continue;
      const { root, gate, growth } = def as Record<string, unknown>;
      if (typeof root !== "string") continue;
      cfg.tiers[name] = {
        root,
        gate: typeof gate === "string" ? gate : "none",
        growth: typeof growth === "string" ? growth : "primary",
      } satisfies TierDef;
    }
  }
  return cfg;
}

/** Load execute/gc config: structure.yaml `journal:` and `gc:` sections. */
export function loadP3Config(dir: string | null = rulesDir()): P3Config {
  const cfg: P3Config = { journal_path: null, gc: { dj_zone: null, dj_collections: [] } };
  if (!dir) return cfg;
  const doc = readYaml(join(dir, "structure.yaml"));
  if (!doc) return cfg;
  const journal = doc["journal"] as Record<string, unknown> | undefined;
  if (typeof journal?.["path"] === "string") {
    const p = journal["path"].replace(/^~(?=\/)/, homedir());
    cfg.journal_path = isAbsolute(p) ? p : resolve(dir, p);
  }
  const gc = doc["gc"] as Record<string, unknown> | undefined;
  if (gc) {
    if (typeof gc["dj_zone"] === "string") cfg.gc.dj_zone = gc["dj_zone"];
    if (Array.isArray(gc["dj_collections"]))
      cfg.gc.dj_collections = gc["dj_collections"].filter((x): x is string => typeof x === "string");
  }
  return cfg;
}

/** Load income folders from income.yaml. Relative paths resolve against the rules dir. */
export function loadIncome(dir: string | null = rulesDir()): IncomeFolder[] {
  if (!dir) return [];
  const doc = readYaml(join(dir, "income.yaml"));
  const list = doc?.["income"];
  if (!Array.isArray(list)) return [];
  const out: IncomeFolder[] = [];
  for (const item of list) {
    if (typeof item !== "object" || item === null) continue;
    const { name, path, source_type } = item as Record<string, unknown>;
    if (typeof name !== "string" || typeof path !== "string") continue;
    const p = path.replace(/^~(?=\/)/, homedir());
    out.push({
      name,
      path: isAbsolute(p) ? p : resolve(dir, p),
      source_type: typeof source_type === "string" ? source_type : "unknown",
    });
  }
  return out;
}

/** Find the income folder containing the given absolute path, if any. */
export function incomeFor(path: string, income: IncomeFolder[]): IncomeFolder | null {
  const p = resolve(path);
  let best: IncomeFolder | null = null;
  for (const inc of income) {
    const root = resolve(inc.path);
    if (p === root || p.startsWith(root + "/")) {
      if (!best || root.length > resolve(best.path).length) best = inc;
    }
  }
  return best;
}
