// Validates every character image without downloading the full files:
//   1. a HEAD request per URL must return an image/* 200
//   2. the resolved image filename should plausibly match the character, which
//      catches the failure mode where Wikipedia's free-license fallback
//      returns an unrelated picture.
// Run with: npm run check:images
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const catalog = JSON.parse(fs.readFileSync(path.join(root, "scripts/catalog.json"), "utf8"));
const images = JSON.parse(fs.readFileSync(path.join(root, "scripts/wiki-images.cache.json"), "utf8"));

const used = new Set();
for (const p of catalog.pairings) {
  used.add(p.a);
  used.add(p.b);
}
const chars = catalog.characters.filter((c) => used.has(c.key));

const norm = (s) =>
  String(s)
    .toLowerCase()
    .replace(/[^a-z0-9 ]/g, " ")
    .replace(/\s+/g, " ")
    .trim();

const STOP = new Set(["the", "and", "of", "a", "an", "mr", "mrs", "dr", "sr", "jr", "ii", "duo"]);
const tokens = (s) => norm(s).split(" ").filter((t) => t.length > 2 && !STOP.has(t));

function looksLikeCharacter(c, image) {
  const haystack = norm((image.file ?? "") + " " + image.src).replace(/[ _]/g, "");
  const wanted = [...tokens(c.name), ...tokens(c.wiki)];
  return wanted.some((t) => haystack.includes(t.replace(/ /g, "")));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function head(url) {
  for (let attempt = 0; attempt < 4; attempt++) {
    try {
      const res = await fetch(url, {
        method: "HEAD",
        headers: { "User-Agent": "MejorEnWas/1.0 (image availability check)" },
      });
      if (res.status === 429 || res.status >= 500) {
        await sleep(900 * (attempt + 1));
        continue;
      }
      return { status: res.status, type: res.headers.get("content-type") ?? "" };
    } catch (e) {
      await sleep(900 * (attempt + 1));
      if (attempt === 3) return { status: -1, type: String(e.message) };
    }
  }
  return { status: -1, type: "exhausted retries" };
}

let i = 0;
const results = [];
async function worker() {
  while (i < chars.length) {
    const c = chars[i++];
    const image = images[c.wiki];
    if (!image?.src) {
      results.push({ c, ok: false, reason: "no url" });
      continue;
    }
    const { status, type } = await head(image.src);
    const ok = status === 200 && type.startsWith("image/");
    const suspicious = ok && !looksLikeCharacter(c, image);
    results.push({ c, ok, suspicious, status, type, image });
    await sleep(200);
  }
}
await Promise.all(Array.from({ length: 3 }, worker));

const broken = results.filter((r) => !r.ok);
const suspect = results.filter((r) => r.suspicious);

console.log(`checked ${results.length} images with HEAD requests`);
console.log(`broken: ${broken.length}`);
for (const r of broken) console.log(`  - ${r.c.key} (${r.status} ${r.type}) ${r.image?.src ?? ""}`);
console.log(`filename looks unrelated (needs a visual check): ${suspect.length}`);
for (const r of suspect) console.log(`  - ${r.c.key} -> ${r.image.file}`);

if (broken.length === 0 && suspect.length === 0) console.log("\nAll images resolve and look correctly named.");
process.exit(broken.length === 0 ? 0 : 1);
