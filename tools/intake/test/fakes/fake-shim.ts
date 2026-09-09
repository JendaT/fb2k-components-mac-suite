// Fake beets shim for tests. Mode via FAKE_SHIM_MODE:
//   unavailable (default) — behaves like a machine without beets
//   match                 — one close candidate (distance 0.07)
//   far                   — only distant candidates (0.38, 0.41)

const mode = process.env.FAKE_SHIM_MODE ?? "unavailable";

if (mode === "unavailable") {
  console.log(JSON.stringify({ error: "beets_unavailable" }));
  process.exit(3);
}

const near = {
  source: "discogs",
  release_id: "9911223",
  artist: "Carbon Based Lifeforms",
  album: "Derelicts",
  year: "2017",
  label: "Blood Music",
  catno: "BLOOD-171",
  distance: 0.07,
  track_mapping: { "01 - Accede.flac": "Accede" },
};
const far1 = { ...near, release_id: "111", album: "Derelicts (Remastered)", distance: 0.38 };
const far2 = { ...near, release_id: "222", album: "Twentythree", distance: 0.41 };

console.log(JSON.stringify({ candidates: mode === "match" ? [near, far1] : [far1, far2] }));
