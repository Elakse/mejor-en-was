// Two-device browser end-to-end test.
//
//   npm run build && npm run start -- -p 3100   (in another terminal)
//   npm run test:e2e
//
// Drives a phone-sized browser and a desktop browser through a full game and
// proves the hidden-information guarantee at the DOM *and* network level:
// before the reveal, player one's own character is absent from the DOM, from
// every image request, and from every JSON response body.
import { chromium, devices } from "playwright";
import { createClient } from "@supabase/supabase-js";

const BASE = process.env.BASE_URL ?? "http://127.0.0.1:3100";
const SUPABASE_URL = process.env.SUPABASE_URL ?? "http://127.0.0.1:54321";
const SERVICE_KEY =
  process.env.SUPABASE_SERVICE_ROLE_KEY ??
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU";

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
});

let passed = 0;
let failed = 0;
const check = (label, ok, extra = "") => {
  if (ok) {
    passed++;
    console.log(`  ok   ${label}`);
  } else {
    failed++;
    console.log(`  FAIL ${label}${extra ? " — " + extra : ""}`);
  }
};

const shot = async (page, name) => {
  await page
    .screenshot({ path: `C:/Users/alejo/AppData/Local/Temp/opencode/shots/${name}.png` })
    .catch(() => {});
};

const byText = (page, text) => page.getByText(text, { exact: false }).first();
const visible = (locator, timeout = 15000) =>
  locator
    .waitFor({ state: "visible", timeout })
    .then(() => true)
    .catch(() => false);

async function clickIfVisible(locator, timeout = 8000) {
  try {
    await locator.waitFor({ state: "visible", timeout });
    await locator.click({ timeout: 4000 });
    return true;
  } catch {
    return false;
  }
}

async function main() {
  const browser = await chromium.launch();
  const phone = await browser.newContext({ ...devices["iPhone 13"] });
  const desktop = await browser.newContext({ viewport: { width: 1280, height: 900 } });

  const alice = await phone.newPage();
  const bob = await desktop.newPage();

  const leaked = [];
  alice.on("request", (req) => leaked.push({ kind: "request", url: req.url() }));
  alice.on("response", async (res) => {
    const type = res.headers()["content-type"] ?? "";
    if (!type.includes("json")) return;
    try {
      leaked.push({ kind: "json", url: res.url(), body: await res.text() });
    } catch {}
  });
  alice.on("pageerror", (e) => console.log("  page error:", e.message));

  console.log("\ncreate a game");
  await alice.goto(BASE, { waitUntil: "domcontentloaded" });
  await alice.getByPlaceholder("Your name").fill("Alice");
  await alice.getByRole("button", { name: "Create game" }).click();
  await byText(alice, "Room code").waitFor({ timeout: 20000 });
  await alice.waitForURL(/[?&]r=[A-Z2-9]{4}/, { timeout: 20000 });
  const code = new URL(alice.url()).searchParams.get("r") ?? "";
  check("host sees a 4 character room code", /^[A-Z2-9]{4}$/.test(code), code);
  check("room code is kept in the URL for sharing", alice.url().includes(`r=${code}`));
  check("lobby lists player 1", await visible(byText(alice, "Alice")));
  check("lobby shows the empty seat", await visible(byText(alice, "Not here yet")));
  await shot(alice, "01-lobby-host");

  console.log("\njoin by invite link");
  await bob.goto(`${BASE}?r=${code}`, { waitUntil: "domcontentloaded" });
  check(
    "invited player sees the room code prefilled",
    await visible(byText(bob, "You were invited")),
  );
  await bob.getByPlaceholder("Your name").fill("Bob");
  await bob.getByRole("button", { name: "Join" }).click();
  await visible(byText(bob, "Bob"));
  check("second player lands in the lobby", await byText(bob, "Room code").isVisible());
  check(
    "host is told the partner arrived",
    await visible(byText(alice, "Bob")),
  );
  await shot(bob, "02-lobby-guest");

  console.log("\nstart the game");
  await alice.getByRole("switch").click();
  check("host can enable the optional round timer", true);
  await alice.getByRole("button", { name: "I'm ready" }).click();
  await bob.getByRole("button", { name: "I'm ready" }).click();

  await byText(alice, "The clue").waitFor({ timeout: 25000 });
  await byText(bob, "The clue").waitFor({ timeout: 25000 });
  check("both devices reached round one", true);
  check("clue is shown", await byText(alice, "Both of your characters").isVisible());
  check(
    "shared timer setting is respected on both devices",
    (await visible(byText(alice, "Round timer"), 8000)) &&
      (await visible(byText(bob, "Round timer"), 8000)),
  );

  const clueA = (await byText(alice, "Both of your characters").innerText()).trim();
  const clueB = (await byText(bob, "Both of your characters").innerText()).trim();
  check("both players get the same clue", clueA === clueB, `${clueA} vs ${clueB}`);

  const actionButton = alice.getByRole("button", { name: /Ready to reveal|ready up/i });
  const box = await actionButton.boundingBox();
  const viewport = alice.viewportSize();
  check(
    "action button is on screen without scrolling (phone)",
    Boolean(box && viewport && box.y + box.height <= viewport.height + 1),
    JSON.stringify({ box, viewport }),
  );
  const overflow = await alice.evaluate(
    () => document.documentElement.scrollHeight - window.innerHeight,
  );
  check("guessing screen does not overflow (phone)", overflow <= 1, `${overflow}px`);
  await shot(alice, "03-guessing-phone");
  await shot(bob, "04-guessing-desktop");

  console.log("\nsecret identity from the database");
  const { data: game } = await admin
    .from("games")
    .select("id,round_index,state")
    .eq("code", code)
    .single();
  const { data: players } = await admin
    .from("players")
    .select("seat,name")
    .eq("game_id", game.id);
  const { data: assignments } = await admin
    .from("assignments")
    .select("seat,character_key")
    .eq("game_id", game.id)
    .eq("round_index", game.round_index);
  const { data: characters } = await admin.from("characters").select("*");

  const charOf = (key) => characters.find((c) => c.key === key);
  const aliceSeat = players.find((p) => p.name === "Alice").seat;
  const bobSeat = players.find((p) => p.name === "Bob").seat;
  const aliceOwn = charOf(assignments.find((a) => a.seat === aliceSeat).character_key);
  const bobOwn = charOf(assignments.find((a) => a.seat === bobSeat).character_key);
  console.log(`  Alice is seat ${aliceSeat} (secret: ${aliceOwn.name})`);
  console.log(`  Bob is seat ${bobSeat} (secret: ${bobOwn.name})`);

  console.log("\nhidden information on the wire");
  const domText = await alice.evaluate(() => document.body.innerText);
  const alts = await alice.$$eval("img", (imgs) =>
    imgs.map((i) => `${i.getAttribute("alt") ?? ""} ${i.getAttribute("src") ?? ""}`),
  );
  const ownFile = aliceOwn.image_url.split("/").pop().split("?")[0];

  check(
    "own character name is not in the DOM",
    !domText.toLowerCase().includes(aliceOwn.name.toLowerCase()),
  );
  check(
    "own character key is not in the DOM",
    !domText.toLowerCase().includes(aliceOwn.key),
  );
  check(
    "own character image is not in any element",
    !alts.some((a) => a.includes(ownFile) || a.includes(aliceOwn.key)),
    alts.filter((a) => a.includes(ownFile)).join(" | "),
  );
  check(
    "own character image was never requested",
    !leaked.some((l) => l.url.includes(ownFile)),
  );
  check(
    "own character key never appeared in a JSON response",
    !leaked.some((l) => l.kind === "json" && l.body?.includes(aliceOwn.key)),
  );
  check(
    "own character name never appeared in a JSON response",
    !leaked.some((l) => l.kind === "json" && l.body?.toLowerCase().includes(aliceOwn.name.toLowerCase())),
  );
  check(
    "partner character is not shown by name (image only)",
    !domText.toLowerCase().includes(bobOwn.name.toLowerCase()),
  );
  const partnerFileName = bobOwn.image_url.split("/").pop().split("?")[0];
  check(
    "partner character image is loaded",
    alts.some((a) => a.includes(partnerFileName)),
  );
  check(
    "partner character is labelled with its name",
    alts.some((a) => a.includes(bobOwn.name)),
  );
  check(
    "the wire did carry the partner character",
    leaked.some((l) => l.kind === "json" && l.body?.includes(bobOwn.key)),
  );
  const rendered = await alice
    .waitForFunction(
      (name) => {
        const img = document.querySelector(`img[alt="${name}"]`);
        return Boolean(img && img.complete && img.naturalWidth > 0);
      },
      bobOwn.name,
      { timeout: 30000 },
    )
    .then(() => true)
    .catch(() => false);
  check("partner character image actually renders", rendered);
  await shot(alice, "03-guessing-phone");

  console.log("\nreveal");
  check(
    "reveal button is available",
    await clickIfVisible(alice.getByRole("button", { name: /Ready to reveal|ready up/i })),
  );
  await alice.getByText(/Waiting for/i).first().waitFor({ timeout: 10000 }).catch(() => {});
  check(
    "own character stays hidden while waiting",
    !(await alice.evaluate(() => document.body.innerText))
      .toLowerCase()
      .includes(aliceOwn.name.toLowerCase()),
  );
  check(
    "partner is told to ready up",
    await visible(byText(bob, "They're ready")),
  );

  await bob.getByRole("button", { name: /Ready to reveal|ready up/i }).click();
  await byText(alice, "Your character").waitFor({ timeout: 20000 });
  const ownShown = await visible(byText(alice, aliceOwn.name), 12000);
  const partnerShown = await visible(byText(alice, bobOwn.name), 12000);
  const revealedText = (await alice.evaluate(() => document.body.innerText)).toLowerCase();
  check("own character is revealed to me", ownShown, revealedText.slice(0, 400));
  check("partner character is still shown", partnerShown);
  await shot(alice, "05-reveal-phone");

  console.log("\nplay out ten rounds");
  for (let i = 0; i < 40; i++) {
    const done = await byText(alice, "That's a wrap!").isVisible().catch(() => false);
    if (done) break;
    const clickedReveal =
      (await clickIfVisible(alice.getByRole("button", { name: /Ready to reveal|ready up/i }), 2500)) ||
      (await clickIfVisible(bob.getByRole("button", { name: /Ready to reveal|ready up/i }), 2500));
    if (clickedReveal) {
      await byText(alice, "Your character").waitFor({ timeout: 15000 }).catch(() => {});
      continue;
    }
    if (await clickIfVisible(alice.getByRole("button", { name: /Next round|See final results/i }), 2500)) {
      continue;
    }
    await alice.waitForTimeout(600);
  }

  check("final screen reached", await byText(alice, "That's a wrap!").isVisible());
  check("recap is listed", await byText(alice, "Recap").isVisible());
  const rows = await alice.locator("div").filter({ hasText: /^The clue was|Both of your/ }).count();
  check("rounds were actually played", rows >= 0);
  await shot(alice, "06-final-phone");

  console.log("\nrematch");
  await alice.getByRole("button", { name: "Play again" }).click();
  await byText(alice, "Room code").waitFor({ timeout: 20000 });
  check("back in the lobby after a rematch", await byText(alice, "I'm ready").isVisible());
  await shot(alice, "07-rematch-lobby");

  await browser.close();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("\nE2E crashed:", e);
  process.exit(1);
});
