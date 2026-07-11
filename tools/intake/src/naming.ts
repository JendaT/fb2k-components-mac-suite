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

const GRAMMARS: { grammar: string; score: number; re: RegExp; map: (m: RegExpMatchArray) => Partial<NameParse> }[] = [
  {
    // Artist [YYYY] Title (Label; Cat#)
    grammar: "bracket_year_paren_label",
    score: 1.0,
    re: /^(.+?)\s+\[(\d{4})\]\s+(.+?)\s+\(([^;()]+);\s*([^()]+)\)$/,
    map: (m) => ({ artist: m[1], year: m[2], album: m[3], label: m[4], catno: m[5] }),
  },
  {
    // Artist [YYYY] Title [Label, Cat#]
    grammar: "bracket_year_bracket_label",
    score: 1.0,
    re: /^(.+?)\s+\[(\d{4})\]\s+(.+?)\s+\[([^,\[\]]+),\s*([^\[\]]+)\]$/,
    map: (m) => ({ artist: m[1], year: m[2], album: m[3], label: m[4], catno: m[5] }),
  },
  {
    // Artist [YYYY] Title
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
