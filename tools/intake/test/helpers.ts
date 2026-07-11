import { cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isSidecarName, sha1Hex } from "../src/util.ts";

export const FIXTURES = join(import.meta.dir, "..", "fixtures");

export interface Corpus {
  dir: string; // temp root
  income: string; // <dir>/income
  rules: string; // <dir>/rules
}

/**
 * Copy the committed fixture corpus into a fresh temp dir and inject the
 * junk files the repo .gitignore cannot carry. Sets INTAKE_RULES_DIR.
 */
export function setupCorpus(): Corpus {
  const dir = mkdtempSync(join(tmpdir(), "intake-test-"));
  cpSync(join(FIXTURES, "income"), join(dir, "income"), { recursive: true });
  cpSync(join(FIXTURES, "rules"), join(dir, "rules"), { recursive: true });
  const income = join(dir, "income");

  // Junk files: must be skipped by the resolver and never referenced.
  writeFileSync(join(income, "downloads", ".DS_Store"), new Uint8Array([0, 0, 0, 1]));
  const ott = join(income, "todo", "Ott - Blumenkraft (2003)");
  writeFileSync(join(ott, ".DS_Store"), new Uint8Array([0, 0, 0, 1]));
  writeFileSync(join(ott, "._01 - Jack's Cheese and Bread Snack.flac"), new Uint8Array(82));
  writeFileSync(join(income, "slsk", "loose", "Thumbs.db"), new Uint8Array(16));
  const eaDir = join(income, "slsk", "Solar Fields", "@eaDir");
  mkdirSync(eaDir, { recursive: true });
  writeFileSync(join(eaDir, "SYNO_THUMB.jpg"), new Uint8Array([0xff, 0xd8, 0xff, 0xd9]));

  process.env.INTAKE_RULES_DIR = join(dir, "rules");
  return { dir, income, rules: join(dir, "rules") };
}

/**
 * Mutation-guard tree hash: relpath + content hash of every file, EXCLUDING
 * sidecars and unpacked archive output (the two legal additions). Any change
 * to pre-existing bytes changes this hash.
 */
export function treeHash(root: string): string {
  const lines: string[] = [];
  const visit = (dir: string, rel: string) => {
    for (const name of readdirSync(dir).sort()) {
      const p = join(dir, name);
      const r = rel ? `${rel}/${name}` : name;
      if (statSync(p).isDirectory()) {
        if (name.endsWith(".unpacked")) continue;
        visit(p, r);
      } else {
        if (isSidecarName(name)) continue;
        lines.push(`${r}:${sha1Hex(new Uint8Array(readFileSync(p)))}`);
      }
    }
  };
  visit(root, "");
  return sha1Hex(lines.join("\n"));
}

/** All sidecar files under root, as [relpath, parsed] pairs sorted by path. */
export function collectSidecars(root: string): [string, Record<string, unknown>][] {
  const out: [string, Record<string, unknown>][] = [];
  const visit = (dir: string, rel: string) => {
    for (const name of readdirSync(dir).sort()) {
      const p = join(dir, name);
      const r = rel ? `${rel}/${name}` : name;
      if (statSync(p).isDirectory()) visit(p, r);
      else if (isSidecarName(name)) out.push([r, JSON.parse(readFileSync(p, "utf8"))]);
    }
  };
  visit(root, "");
  out.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  return out;
}

/** Strip volatile fields (timestamps) so sidecars compare deterministically. */
export function normalizeSidecar(doc: Record<string, unknown>): Record<string, unknown> {
  const copy = structuredClone(doc);
  copy.resolved_at = "<ts>";
  for (const h of (copy.history as Record<string, unknown>[]) ?? []) h.ts = "<ts>";
  return copy;
}
