// Folder-name grammars per docs/intake/intake-02-assignment-spec.md (fast path).
// The resolver only needs the parse to score the name_parse signal and to
// label untagged clusters; full identification is doc 02 / P2 scope.

export interface NameParse {
  grammar: string; // which grammar matched
  score: number; // name_parse signal contribution: 1.0 full, 0.75 dated, 0.5 loose
  artist: string | null;
  album: string | null;
  year: string | null;
  label: string | null;
  catno: string | null;
}

// Label-block vocabulary: fields of a `(…; …)` / `[…, …]` block that are never
// a label. Discogs-style blocks put format, descriptors and country before the
// label (`[2CD, Comp, RM, US, Label #CAT290]`); year-first blocks put the
// original year there (`(1984; Label; CAT01)`).
const BLOCK_YEAR_RE = /^\d{4}$/;
/** Media/format tokens, optionally with a count: WEB, CD, 2CD, 2xLP, Cass, 12" … */
const BLOCK_FORMAT_RE =
  /^(?:\d+\s*x?\s*)?(?:web|cd|cdr|hdcd|sacd|dvd|dvda|blu-?ray|lp|vinyl|cass|cassette|file|files|flac|mp3|aac|alac|wav)$|^\d+"$/i;
/** Discogs release descriptors (compared casefolded, trailing "." ignored). */
const BLOCK_DESCRIPTORS = new Set([
  "album", "comp", "compilation", "deluxe", "ep", "enh", "ltd", "limited", "limited edition",
  "mini", "maxi", "mixed", "mono", "num", "numbered", "promo", "re", "reissue", "rm", "remastered",
  "rp", "repress", "sampler", "single", "smplr", "stereo", "unofficial",
]);
/** Country fields as Discogs writes them (codes and the common names). */
const BLOCK_COUNTRIES = new Set([
  "us", "usa", "uk", "eu", "europe", "worldwide", "unknown",
  "de", "germany", "fr", "france", "nl", "netherlands", "jp", "japan", "ca", "canada",
  "au", "australia", "it", "italy", "es", "spain", "se", "sweden", "ru", "russia", "be", "belgium",
]);

function isBlockToken(field: string): boolean {
  const f = field.trim().replace(/\.$/, "");
  const low = f.toLowerCase();
  return BLOCK_YEAR_RE.test(f) || BLOCK_FORMAT_RE.test(f) || BLOCK_DESCRIPTORS.has(low) || BLOCK_COUNTRIES.has(low);
}

/**
 * Label and catno from a label block's content. Year, format, descriptor and
 * country fields are skipped; the first remaining field is the label, a
 * `#CAT` suffix on it is the catno, otherwise the following fields are. Never
 * returns one of the skipped tokens as a label.
 */
function labelFromBlock(block: string, sep: string): { label: string | null; catno: string | null } {
  const kept = block
    .split(sep)
    .map((f) => f.trim())
    .filter((f) => f !== "" && !isBlockToken(f));
  if (kept.length === 0) return { label: null, catno: null };
  const first = kept[0]!;
  const hash = first.match(/^(.*?)\s*#\s*(\S.*)$/);
  const label = hash ? hash[1]!.trim() : first;
  const catno = hash ? hash[2]!.trim() : kept.length > 1 ? kept.slice(1).join(`${sep} `) : null;
  return { label: label !== "" && !isBlockToken(label) ? label : null, catno };
}

const GRAMMARS: { grammar: string; score: number; re: RegExp; map: (m: RegExpMatchArray) => Partial<NameParse> }[] = [
  {
    // Artist [YYYY] Title (Label; Cat#)  — also (YYYY; Label; Cat#)
    grammar: "bracket_year_paren_label",
    score: 1.0,
    re: /^(.+?)\s+\[(\d{4})\]\s+(.+?)\s+\(([^()]*;[^()]*)\)$/,
    map: (m) => ({ artist: m[1], year: m[2], album: m[3], ...labelFromBlock(m[4]!, ";") }),
  },
  {
    // Artist [YYYY] Title [Label, Cat#]  — also Discogs-style
    // [2CD, Comp, RM, US, Label #CAT290] and [YYYY, Label]
    grammar: "bracket_year_bracket_label",
    score: 1.0,
    re: /^(.+?)\s+\[(\d{4})\]\s+(.+?)\s+\[([^\[\]]*,[^\[\]]*)\]$/,
    map: (m) => ({ artist: m[1], year: m[2], album: m[3], ...labelFromBlock(m[4]!, ",") }),
  },
  {
    // Artist [YYYY] Title  (a single-field block like [LABEL CD 97] stays in
    // the title: it cannot be split into label and catno safely)
    grammar: "bracket_year",
    score: 0.75,
    re: /^(.+?)\s+\[(\d{4})\]\s+(.+)$/,
    map: (m) => ({ artist: m[1], year: m[2], album: m[3] }),
  },
  {
    // Scene: Artist-Title-(CAT)-WEB-YYYY-GRP (hyphen or underscore variants)
    grammar: "scene",
    score: 1.0,
    re: /^([A-Za-z0-9_.]+)[-_]([A-Za-z0-9_.]+)[-_]\(?([A-Z0-9]+)\)?[-_](?:WEB|CD|VINYL|TAPE|FLAC|MP3)[-_.\w]*[-_](\d{4})[-_]([A-Za-z0-9]+)$/i,
    map: (m) => ({
      artist: m[1]!.replace(/_/g, " "),
      album: m[2]!.replace(/_/g, " "),
      catno: m[3],
      year: m[4],
    }),
  },
  {
    // Artist - Title (YYYY)  /  Artist - Title [YYYY]
    grammar: "dash_year",
    score: 0.75,
    re: /^(.+?)\s+-\s+(.+?)\s*[(\[](\d{4})[)\]](?:\s*\[[^\]]*\])?$/,
    map: (m) => ({ artist: m[1], album: m[2], year: m[3] }),
  },
  {
    // Artist - Title
    grammar: "dash",
    score: 0.5,
    re: /^(.+?)\s+-\s+(.+)$/,
    map: (m) => ({ artist: m[1], album: m[2] }),
  },
];

export function parseDirName(name: string): NameParse | null {
  const clean = name.trim();
  for (const g of GRAMMARS) {
    const m = clean.match(g.re);
    if (!m) continue;
    return {
      grammar: g.grammar,
      score: g.score,
      artist: null,
      album: null,
      year: null,
      label: null,
      catno: null,
      ...g.map(m),
    };
  }
  return null;
}
