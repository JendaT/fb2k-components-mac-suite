import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";
import type { IncomeFolder, ResolverConfig } from "./types.ts";

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
