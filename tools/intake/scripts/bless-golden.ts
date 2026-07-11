// Regenerates test/expected/sidecars.json from the current resolver output.
// Run only after hand-verifying the new output is correct; the golden file is
// the reviewed source of truth for the golden test.

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cmdScan } from "../src/commands.ts";
import { collectSidecars, normalizeSidecar, setupCorpus } from "../test/helpers.ts";

const corpus = setupCorpus();
const result = await cmdScan([], { json: true, dryRun: false, force: false, all: true, filters: {} });
if (result.exitCode !== 0) {
  console.error("scan failed", result.errors);
  process.exit(1);
}
const golden: Record<string, unknown> = {};
for (const [rel, doc] of collectSidecars(corpus.income)) golden[rel] = normalizeSidecar(doc);

const out = join(import.meta.dir, "..", "test", "expected", "sidecars.json");
mkdirSync(join(import.meta.dir, "..", "test", "expected"), { recursive: true });
writeFileSync(out, JSON.stringify(golden, null, 2) + "\n");
console.log(`blessed ${Object.keys(golden).length} sidecars -> ${out}`);
rmSync(corpus.dir, { recursive: true, force: true });
