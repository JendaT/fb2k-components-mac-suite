// Generates the synthetic fixture corpus under fixtures/income/.
// Output is committed; re-running regenerates from scratch (audio content is
// deterministic sine tones, so hashes only change if ffmpeg encoding changes).
// No personal data: all names are public artist/label strings used as test
// literals only.

import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const FIXTURES = join(import.meta.dir, "..", "fixtures");
const INCOME = join(FIXTURES, "income");

/**
 * `--only=<relpath prefix>`: generate just the matching fixtures into the
 * existing corpus instead of wiping and regenerating everything. Used when
 * ADDING a fixture, so the already-committed audio bytes — and the goldens
 * keyed to their hashes — stay byte-identical.
 *
 * A partial run does not advance the tone-frequency counter, so anything
 * generated under `--only` must pass an explicit `freq` to stay reproducible
 * in a later full run. genAudio enforces that.
 */
const ONLY = process.argv.slice(2).find((a) => a.startsWith("--only="))?.slice("--only=".length) ?? null;

function wanted(absPath: string): boolean {
  if (ONLY === null) return true;
  const rel = absPath.startsWith(INCOME + "/") ? absPath.slice(INCOME.length + 1) : absPath;
  return rel.startsWith(ONLY);
}

let freq = 180;
const nextFreq = () => (freq += 37);

async function run(args: string[], cwd?: string): Promise<void> {
  const proc = Bun.spawn(args, { cwd, stdout: "ignore", stderr: "pipe" });
  if ((await proc.exited) !== 0) {
    throw new Error(`${args[0]} failed: ${await new Response(proc.stderr).text()}`);
  }
}

type Codec = "flac" | "flac24" | "mp3-320" | "mp3-128" | "ogg" | "wav" | "aiff";

async function genAudio(
  path: string,
  codec: Codec,
  tags: Record<string, string | number> | null,
  opts?: { freq?: number },
): Promise<void> {
  if (!wanted(path)) return;
  if (ONLY !== null && opts?.freq === undefined)
    throw new Error(`--only requires an explicit freq (counter tones are not reproducible partially): ${path}`);
  mkdirSync(dirname(path), { recursive: true });
  const rate = codec === "flac24" ? 96000 : 44100;
  const args = [
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", `sine=frequency=${opts?.freq ?? nextFreq()}:duration=0.3:sample_rate=${rate}`,
  ];
  if (tags === null) args.push("-map_metadata", "-1", "-fflags", "+bitexact");
  else for (const [k, v] of Object.entries(tags)) args.push("-metadata", `${k}=${v}`);
  switch (codec) {
    case "flac": args.push("-c:a", "flac", "-sample_fmt", "s16"); break;
    case "flac24": args.push("-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"); break;
    case "mp3-320": args.push("-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3"); break;
    case "mp3-128": args.push("-c:a", "libmp3lame", "-b:a", "128k", "-id3v2_version", "3"); break;
    case "ogg": args.push("-c:a", "libopus", "-b:a", "256k"); break;
    case "wav": args.push("-c:a", "pcm_s16le"); break;
    case "aiff": args.push("-c:a", "pcm_s16be", "-write_id3v2", "1"); break;
  }
  args.push(path);
  await run(args);
}

/**
 * Zero the STREAMINFO MD5 signature, simulating an encoder that left it unset.
 * Layout: "fLaC" (4 bytes) + metadata block header (4) + STREAMINFO (34), whose
 * final 16 bytes are the MD5 — i.e. file offsets [26, 42).
 */
function zeroFlacMd5(path: string): void {
  const buf = readFileSync(path);
  if (buf.subarray(0, 4).toString("latin1") !== "fLaC") throw new Error(`not a FLAC file: ${path}`);
  if ((buf[4]! & 0x7f) !== 0) throw new Error(`first metadata block is not STREAMINFO: ${path}`);
  buf.fill(0, 26, 42);
  writeFileSync(path, buf);
}

async function genCover(dir: string): Promise<void> {
  if (!wanted(join(dir, "cover.jpg"))) return;
  mkdirSync(dir, { recursive: true });
  await run([
    "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", "color=c=gray:s=16x16", "-frames:v", "1", join(dir, "cover.jpg"),
  ]);
}

interface AlbumSpec {
  dir: string;
  codec: Codec;
  albumartist: string;
  album: string;
  date: string;
  tracks: string[];
  disc?: number;
  cover?: boolean;
  untagged?: boolean;
}

async function genAlbum(spec: AlbumSpec): Promise<void> {
  const dir = join(INCOME, spec.dir);
  const ext = spec.codec.startsWith("flac") ? "flac" : spec.codec.startsWith("mp3") ? "mp3" : spec.codec;
  for (let i = 0; i < spec.tracks.length; i++) {
    const title = spec.tracks[i]!;
    const file = join(dir, `${String(i + 1).padStart(2, "0")} - ${title}.${ext}`);
    const tags = spec.untagged
      ? null
      : {
          album_artist: spec.albumartist,
          artist: spec.albumartist,
          album: spec.album,
          title,
          track: i + 1,
          date: spec.date,
          ...(spec.disc ? { disc: spec.disc } : {}),
        };
    await genAudio(file, spec.codec, tags);
  }
  if (spec.cover) await genCover(dir);
}

async function main(): Promise<void> {
  if (ONLY === null) rmSync(INCOME, { recursive: true, force: true });

  // ---- downloads (web) ----------------------------------------------------
  await genAlbum({
    dir: "downloads/Aes Dana [2012] Pollen (Ultimae Records; inre042)",
    codec: "flac", albumartist: "Aes Dana", album: "Pollen", date: "2012",
    tracks: ["Iliona", "Signs", "Adonai", "Borderline"], cover: true,
  });
  await genAlbum({
    dir: "downloads/Sync24 [2024] Omnimotion Remixed",
    codec: "flac24", albumartist: "Sync24", album: "Omnimotion Remixed", date: "2024",
    tracks: ["Omnimotion", "Dance of the Droids", "Cargo"], cover: true,
  });

  // Bandcamp-style zip: album dir inside an archive, unpacked by scan.
  const zipStage = join(INCOME, "downloads", ".stage");
  const cblDir = "Carbon Based Lifeforms - Derelicts (2017)";
  await genAlbum({
    dir: `downloads/.stage/${cblDir}`,
    codec: "flac", albumartist: "Carbon Based Lifeforms", album: "Derelicts", date: "2017",
    tracks: ["Accede", "Clouds", "Path of Least Resistance"],
  });
  const zipPath = join(INCOME, "downloads", `${cblDir}.zip`);
  if (wanted(zipPath)) {
    await run(["zip", "-q", "-r", zipPath, cblDir], zipStage);
    rmSync(zipStage, { recursive: true, force: true });
  }

  // ISO stub: flagged needs_review, never unpacked.
  const isoPath = join(INCOME, "downloads", "Ambient Collection (1997).iso");
  if (wanted(isoPath)) {
    const isoBytes = new Uint8Array(4096);
    for (let i = 0; i < isoBytes.length; i++) isoBytes[i] = (i * 7) & 0xff;
    writeFileSync(isoPath, isoBytes);
  }

  // ---- slsk (soulseek) ----------------------------------------------------
  // Flat dump: two interleaved albums plus one stray single in one dir.
  const mix = "slsk/random_mix";
  for (const [i, title] of ["Argonautica", "Silent Hero", "Athena"].entries()) {
    await genAudio(join(INCOME, mix, `koan_${i + 1}_${title.toLowerCase().replace(/ /g, "_")}.mp3`), "mp3-320", {
      album_artist: "Koan", artist: "Koan", album: "Argonautica", title, track: i + 1, date: "2013",
    });
  }
  for (const [i, title] of ["Arcana", "Nocturne"].entries()) {
    await genAudio(join(INCOME, mix, `emantra_${i + 1}_${title.toLowerCase()}.flac`), "flac", {
      album_artist: "E-Mantra", artist: "E-Mantra", album: "Arcana", title, track: i + 1, date: "2010",
    });
  }
  await genAudio(join(INCOME, mix, "zero_cult_breathe.mp3"), "mp3-320", {
    artist: "Zero Cult", album: "Breathe EP", title: "Breathe", track: 4, date: "2008",
  });

  // Nested artist dump: each release dir its own root.
  await genAlbum({
    dir: "slsk/Solar Fields/Solar Fields [2001] Reflective Frequencies",
    codec: "flac", albumartist: "Solar Fields", album: "Reflective Frequencies", date: "2001",
    tracks: ["Wavescapes", "Cobalt", "Skylab"], cover: true,
  });
  await genAlbum({
    dir: "slsk/Solar Fields/Solar Fields [2005] Leaving Home",
    codec: "flac", albumartist: "Solar Fields", album: "Leaving Home", date: "2005",
    tracks: ["Home", "Sol", "Refractions"], cover: true,
  });
  await genAlbum({
    dir: "slsk/Solar Fields/Solar Fields - Movements (2009)",
    codec: "mp3-320", albumartist: "Solar Fields", album: "Movements", date: "2009",
    tracks: ["Sombrero", "Perception", "Discovering"],
  });

  // Loose singles: unrelated tagged files, one per cluster.
  await genAudio(join(INCOME, "slsk/loose/asura_lost_eden_edit.mp3"), "mp3-320", {
    artist: "Asura", album: "Singles", title: "Lost Eden (Edit)", track: 1, date: "2004",
  });
  await genAudio(join(INCOME, "slsk/loose/cell_calling_earth.ogg"), "ogg", {
    artist: "Cell", album: "Live Sessions", title: "Calling Earth", track: 2, date: "2005",
  });
  await genAudio(join(INCOME, "slsk/loose/hol_baumann_endless_park.wav"), "wav", {
    artist: "Hol Baumann", album: "Human", title: "Endless Park", track: 3, date: "2008",
  });
  await genAudio(join(INCOME, "slsk/loose/miktek_awakenings.aiff"), "aiff", {
    artist: "Miktek", album: "Elsewhere", title: "Awakenings", track: 1, date: "2014",
  });

  // ---- todo (manual) ------------------------------------------------------
  // Multi-disc set: CD1/CD2 merge upward into the parent.
  const asura = "todo/Asura [2003] Lost Eden (Ultimae Records; inre010)";
  await genAlbum({
    dir: `${asura}/CD1`, codec: "flac", albumartist: "Asura", album: "Lost Eden", date: "2003",
    tracks: ["Lost Eden", "Regenesis", "Atmosphere"], disc: 1,
  });
  await genAlbum({
    dir: `${asura}/CD2`, codec: "flac", albumartist: "Asura", album: "Lost Eden", date: "2003",
    tracks: ["Celestial", "Golden Ocean", "The Prophecy"], disc: 2,
  });
  await genCover(join(INCOME, asura));

  // Mixed-quality duplicates: flac primary, mp3 quality shadows.
  const ott = "todo/Ott - Blumenkraft (2003)";
  for (const [i, title] of ["Jack's Cheese and Bread Snack", "Splitting an Atom", "Smoked Glass and Chrome"].entries()) {
    const tags = {
      album_artist: "Ott", artist: "Ott", album: "Blumenkraft", title, track: i + 1, date: "2003",
    };
    await genAudio(join(INCOME, ott, `${String(i + 1).padStart(2, "0")} - ${title}.flac`), "flac", tags);
    await genAudio(join(INCOME, ott, `${String(i + 1).padStart(2, "0")} - ${title}.mp3`), "mp3-320", tags);
  }

  // Below lossy tolerance: tier reject.
  await genAlbum({
    dir: "todo/Oldskool - Demo Tape (1998)",
    codec: "mp3-128", albumartist: "Oldskool", album: "Demo Tape", date: "1998",
    tracks: ["Intro", "Rough Cut"],
  });

  // Untagged with parseable filenames and dir name (fallback chain).
  await genAlbum({
    dir: "todo/Hilyard [2019] Division Cycle",
    codec: "flac", albumartist: "Hilyard", album: "Division Cycle", date: "2019",
    tracks: ["Cascadia", "Marrow", "Redwood"], untagged: true, cover: true,
  });

  // Scene rip naming.
  await genAlbum({
    dir: "todo/Koan-Condemned-(MKL033)-WEB-2016-KOAN",
    codec: "mp3-320", albumartist: "Koan", album: "Condemned", date: "2016",
    tracks: ["Condemned", "Sentenced", "Released"],
  });

  // FLAC with unset STREAMINFO MD5 — rippers/encoders that skip the signature.
  // audio_hash must fall back to `fsha1:` and the root must carry a
  // `flac_md5_unset` quality issue. Two of the three files are unset so one
  // root exercises both the fallback and the normal `flacmd5:` path.
  const bluetech = "todo/Bluetech [2011] Cosmic Dubwise";
  for (const [i, title] of ["Rainmaker", "Prima Materia", "Dawn Chorus"].entries()) {
    const file = join(INCOME, bluetech, `${String(i + 1).padStart(2, "0")} - ${title}.flac`);
    await genAudio(
      file, "flac",
      { album_artist: "Bluetech", artist: "Bluetech", album: "Cosmic Dubwise", title, track: i + 1, date: "2011" },
      { freq: 1000 + i * 37 },
    );
    if (i < 2 && wanted(file)) zeroFlacMd5(file);
  }

  // NAS thumbnail dir junk (committable; .DS_Store/._*/Thumbs.db junk is
  // injected by the test helper instead, since the repo .gitignore excludes
  // those names).
  const eaDir = join(INCOME, "slsk", "Solar Fields", "@eaDir");
  const thumb = join(eaDir, "SYNO_THUMB.jpg");
  if (wanted(thumb)) {
    mkdirSync(eaDir, { recursive: true });
    writeFileSync(thumb, new Uint8Array([0xff, 0xd8, 0xff, 0xd9]));
  }

  console.log("fixture corpus generated at", INCOME);
}

await main();
