// Builds a contact sheet of the images used on a character's Wikipedia article,
// so a poor picture can be replaced with a better one.
//
//   npm run find:images -- plankton gandalf
//
// Sheets are written to IMAGE_SHEET_OUT (defaults to the system temp dir) and the
// file names to copy into the catalog are printed.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import sharp from "sharp";

const root = path.resolve(import.meta.dirname, "..");
const catalog = JSON.parse(fs.readFileSync(path.join(root, "scripts/catalog.json"), "utf8"));
const images = JSON.parse(fs.readFileSync(path.join(root, "scripts/wiki-images.cache.json"), "utf8"));
const outDir = process.env.IMAGE_SHEET_OUT ?? path.join(os.tmpdir(), "mejor-en-was-images");
fs.mkdirSync(outDir, { recursive: true });

const keys = process.argv.slice(2).filter((a) => !a.startsWith("-"));
if (keys.length === 0) {
  console.error("usage: npm run find:images -- <character-key> [...]");
  process.exit(1);
}

const UA = "MejorEnWas/1.0 (image curation)";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const SKIP = /(logo|wordmark|poster|cover|screenshot|signature|\.svg$|wiki|commons|stub|ambox|edit|icon|map|chart)/i;

async function articleImages(title) {
  const url = new URL("https://en.wikipedia.org/w/api.php");
  url.searchParams.set("action", "query");
  url.searchParams.set("format", "json");
  url.searchParams.set("prop", "images");
  url.searchParams.set("imlimit", "60");
  url.searchParams.set("redirects", "1");
  url.searchParams.set("titles", title);
  const res = await fetch(url, { headers: { "User-Agent": UA } });
  if (!res.ok) return [];
  const json = await res.json();
  const page = Object.values(json?.query?.pages ?? {})[0];
  return (page?.images ?? [])
    .map((i) => i.title.replace(/^File:/, ""))
    .filter((n) => /\.(jpe?g|png|webp)$/i.test(n))
    .filter((n) => !SKIP.test(n));
}

async function fetchFile(file, dest) {
  if (fs.existsSync(dest) && fs.statSync(dest).size > 400) return true;
  const url = `https://en.wikipedia.org/wiki/Special:FilePath/${encodeURIComponent(file)}?width=240`;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(url, { headers: { "User-Agent": UA }, redirect: "follow" });
      if (res.status === 429 || res.status >= 500) {
        await sleep(1500 * (attempt + 1));
        continue;
      }
      if (!res.ok) return false;
      fs.writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
      return true;
    } catch {
      await sleep(1000);
    }
  }
  return false;
}

const CELL = 220;
const LABEL = 34;
const COLS = 5;

for (const key of keys) {
  const character = catalog.characters.find((c) => c.key === key);
  if (!character) {
    console.log(`unknown character: ${key}`);
    continue;
  }
  const title = images[character.wiki]?.page ?? character.wiki;
  const files = await articleImages(title);
  const composites = [];
  const picked = [];
  let slot = 0;
  for (const file of files) {
    if (slot >= 15) break;
    const dest = path.join(outDir, `${key}__${slot}.img`);
    if (!(await fetchFile(file, dest))) continue;
    await sleep(200);
    let buf;
    try {
      buf = await sharp(dest)
        .resize(CELL - 10, CELL - 10, { fit: "contain", background: "#fff" })
        .flatten({ background: "#fff" })
        .toBuffer();
    } catch {
      continue;
    }
    const col = slot % COLS;
    const row = Math.floor(slot / COLS);
    composites.push({ input: buf, left: col * CELL + 5, top: row * (CELL + LABEL) + 5 });
    composites.push({
      input: Buffer.from(
        `<svg width="${CELL}" height="${LABEL}"><rect width="100%" height="100%" fill="#111"/><text x="4" y="14" font-family="monospace" font-size="11" fill="#ff0">${slot}</text><text x="4" y="28" font-family="monospace" font-size="9" fill="#9ef">${file.slice(0, 36).replace(/&/g, "&amp;").replace(/</g, "&lt;")}</text></svg>`,
      ),
      left: col * CELL,
      top: row * (CELL + LABEL) + CELL,
    });
    picked.push({ slot, file });
    slot++;
  }
  if (slot === 0) {
    console.log(`${key}: no usable images on "${title}"`);
    continue;
  }
  await sharp({
    create: {
      width: COLS * CELL,
      height: Math.ceil(slot / COLS) * (CELL + LABEL),
      channels: 3,
      background: "#fff",
    },
  })
    .composite(composites)
    .png()
    .toFile(path.join(outDir, `${key}.png`));
  console.log(`${key} (${title}):`);
  for (const p of picked) console.log(`  ${p.slot}: ${p.file}`);
}

console.log(`\nsheets in ${outDir}`);
console.log("Set the chosen file as an override in scripts/wiki-images.cache.json, then run npm run build:sql.");
