// Validates the curated catalog: unique keys, valid pairings, and that a full
// 10-round game can always be generated with no repeated character.
import fs from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const catalog = JSON.parse(
  fs.readFileSync(path.join(root, "scripts", "catalog.json"), "utf8"),
);
const images = JSON.parse(
  fs.readFileSync(path.join(root, "scripts", "wiki-images.cache.json"), "utf8"),
);

const PROBLEMS = [];
const problems = (msg) => PROBLEMS.push(msg);

const byKey = new Map();
for (const c of catalog.characters) {
  if (byKey.has(c.key)) problems(`duplicate character key: ${c.key}`);
  byKey.set(c.key, c);
  if (!/^[a-z0-9-]+$/.test(c.key)) problems(`bad key format: ${c.key}`);
  if (!c.name || !c.emoji) problems(`missing name/emoji: ${c.key}`);
  const img = images[c.wiki];
  if (!img || !img.src) problems(`no image resolved for ${c.key} (wiki: ${c.wiki})`);
}

const seenPairs = new Set();
const usedChars = new Set();
const usedClues = new Map();

for (const p of catalog.pairings) {
  const a = byKey.get(p.a);
  const b = byKey.get(p.b);
  if (!a) problems(`pairing references unknown character: ${p.a}`);
  if (!b) problems(`pairing references unknown character: ${p.b}`);
  if (p.a === p.b) problems(`pairing with itself: ${p.a}`);
  const pairId = [p.a, p.b].sort().join("|");
  if (seenPairs.has(pairId)) problems(`duplicate pairing: ${p.a} + ${p.b}`);
  seenPairs.add(pairId);
  if (!p.clue || !p.category) problems(`pairing missing clue/category: ${p.a}+${p.b}`);
  if (usedClues.has(p.clue)) problems(`duplicate clue text: "${p.clue}" (also used by ${usedClues.get(p.clue)})`);
  usedClues.set(p.clue, `${p.a}+${p.b}`);
  if (a && b) {
    const shared = new Set([...a.tags, ...b.tags].filter((t) => a.tags.includes(t) && b.tags.includes(t)));
    for (const t of p.traits ?? []) {
      if (!shared.has(t)) {
        problems(`clue "${p.clue}" (${p.a} + ${p.b}) requires "${t}" but it is not shared by both`);
      }
    }
    if (!p.traits || p.traits.length === 0) problems(`pairing has no traits: ${p.a}+${p.b}`);
  }
  usedChars.add(p.a);
  usedChars.add(p.b);
}

for (const c of catalog.characters) {
  if (!usedChars.has(c.key)) problems(`character never used in a pairing: ${c.key}`);
}

// Simulate round generation: greedy pick 10 pairings with no repeated character
// and (preferably) no repeated category.
function tryGenerate(enforceCategory) {
  const pool = [...catalog.pairings].sort(() => Math.random() - 0.5);
  const chars = new Set();
  const cats = new Set();
  const picked = [];
  for (const p of pool) {
    if (picked.length >= 10) break;
    if (chars.has(p.a) || chars.has(p.b)) continue;
    if (enforceCategory && cats.has(p.category)) continue;
    chars.add(p.a);
    chars.add(p.b);
    cats.add(p.category);
    picked.push(p);
  }
  return picked;
}

let strictFailures = 0;
let relaxedFailures = 0;
for (let i = 0; i < 500; i++) {
  if (tryGenerate(true).length < 10) strictFailures++;
  if (tryGenerate(false).length < 10) relaxedFailures++;
}

const categoryCounts = new Map();
for (const p of catalog.pairings) categoryCounts.set(p.category, (categoryCounts.get(p.category) ?? 0) + 1);

const freeImages = catalog.characters.filter((c) => images[c.wiki]?.lic === "free").length;

console.log(`characters: ${catalog.characters.length} (${freeImages} with freely-licensed images)`);
console.log(`pairings:   ${catalog.pairings.length} across ${categoryCounts.size} categories`);
console.log(`10-round generation over 500 runs — strict (unique category): ${500 - strictFailures}/500 ok, relaxed: ${500 - relaxedFailures}/500 ok`);

if (PROBLEMS.length) {
  console.log(`\n${PROBLEMS.length} PROBLEM(S):`);
  for (const p of PROBLEMS) console.log("  - " + p);
  process.exit(1);
}
console.log("\nCatalog OK");
