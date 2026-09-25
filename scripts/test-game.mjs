// End-to-end integration test against a running Supabase instance.
//
//   npm run test:game
//
// Uses the local stack by default; override with SUPABASE_URL / SUPABASE_ANON_KEY
// (or NEXT_PUBLIC_*). Verifies the hidden-information guarantees, not just the
// happy path:
//   * a player can read their partner's character for the current round
//   * a player can NEVER read their own character before the reveal
//   * a player can never read future rounds
//   * the pairings table is unreachable from a client
//   * non-players get nothing at all
import { createClient } from "@supabase/supabase-js";

const url =
  process.env.SUPABASE_URL ??
  process.env.NEXT_PUBLIC_SUPABASE_URL ??
  "http://127.0.0.1:54321";
const anon =
  process.env.SUPABASE_ANON_KEY ??
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ??
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0";

const TOTAL_ROUNDS = 10;

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

async function newClient() {
  const client = createClient(url, anon, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error } = await client.auth.signInAnonymously();
  if (error) throw new Error("anonymous sign-in failed: " + error.message);
  return client;
}

async function call(client, fn, args, label) {
  const { data, error } = await client.rpc(fn, args);
  if (error) throw new Error(`${label ?? fn} failed: ${error.message}`);
  return data;
}

const state = async (client, gameId) => call(client, "get_state", { p_game_id: gameId });

async function canJoinCall(client, topic) {
  const { data } = await client.auth.getSession();
  await client.realtime.setAuth(data.session.access_token);
  const channel = client.channel(topic, { config: { private: true } });
  const status = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve("TIMED_OUT"), 10000);
    channel.subscribe((next) => {
      if (next === "SUBSCRIBED" || next === "CHANNEL_ERROR" || next === "TIMED_OUT") {
        clearTimeout(timer);
        resolve(next);
      }
    });
  });
  await client.removeChannel(channel);
  return status === "SUBSCRIBED";
}

async function main() {
  console.log(`Supabase: ${url}\n`);

  const alice = await newClient();
  const bob = await newClient();
  const stranger = await newClient();

  console.log("lobby");
  const created = await call(alice, "create_game", { p_name: "Alice" });
  check("create_game returns a 4 char code", /^[A-Z2-9]{4}$/.test(created.code), created.code);

  let joinErr = null;
  try {
    await call(stranger, "join_game", { p_code: "ZZZZ", p_name: "Nobody" });
  } catch (e) {
    joinErr = e.message;
  }
  check("invalid room code is rejected", Boolean(joinErr), String(joinErr));

  const joined = await call(bob, "join_game", { p_code: created.code, p_name: "Bob" });
  check("second player gets seat 2", joined.seat === 2 && joined.game_id === created.game_id);

  const reconnect = await call(bob, "join_game", { p_code: created.code, p_name: "Bob" });
  check("rejoin returns the same seat (duplicate connections)", reconnect.seat === 2);

  let stateA = await state(alice, created.game_id);
  check("lobby state", stateA?.game?.state === "lobby", JSON.stringify(stateA?.game?.state));
  check("both players listed", stateA?.players?.length === 2);
  check("isMe flags exactly one player", stateA.players.filter((p) => p.isMe).length === 1);

  const strangerState = await state(stranger, created.game_id);
  check("non-player cannot read game state", strangerState === null || strangerState?.game == null);
  const callTopic = `call:${created.game_id}:${stateA.players.map((player) => player.id).sort().join(":")}`;
  check("seated player can join private call signaling", await canJoinCall(alice, callTopic));
  check("non-player cannot join private call signaling", !(await canJoinCall(stranger, callTopic)));
  check("obsolete player pair cannot join current call signaling", !(await canJoinCall(alice,
    `call:${created.game_id}:${stateA.players[0].id}:00000000-0000-0000-0000-000000000000`)));

  console.log("\nstart");
  await call(alice, "set_lobby_ready", { p_game_id: created.game_id, p_ready: true });
  stateA = await state(alice, created.game_id);
  check("one ready player does not start the game", stateA.game.state === "lobby");

  await call(bob, "set_lobby_ready", { p_game_id: created.game_id, p_ready: true });
  stateA = await state(alice, created.game_id);
  const stateB = await state(bob, created.game_id);
  check("both ready starts the game", stateA.game.state === "guessing");
  check("round 0 with a clue", stateA.round?.index === 0 && stateA.round?.clue?.length > 5);
  check("clue is shared", stateA.round.clue === stateB.round.clue);
  check("10 rounds total", stateA.round.total === TOTAL_ROUNDS);

  console.log("\nhidden information");
  const ownSeatA = stateA.players.find((p) => p.isMe).seat;
  const partnerSeatA = stateA.players.find((p) => !p.isMe).seat;

  check("player sees exactly one assignment", stateA.assignments.length === 1, JSON.stringify(stateA.assignments));
  check("the visible assignment is the partner's", stateA.assignments[0].seat === partnerSeatA);
  check("partner character has an image", Boolean(stateA.assignments[0].character.imageUrl));
  check(
    "the two players see different characters",
    stateA.assignments[0].character.key !== stateB.assignments[0].character.key,
  );

  const ownDirect = await alice
    .from("assignments")
    .select("character_key")
    .eq("game_id", created.game_id)
    .eq("seat", ownSeatA);
  check(
    "direct SQL for own assignment is denied",
    !ownDirect.error && (ownDirect.data ?? []).length === 0,
    JSON.stringify(ownDirect.data ?? ownDirect.error?.message),
  );

  const future = await alice
    .from("assignments")
    .select("round_index, character_key")
    .eq("game_id", created.game_id)
    .eq("round_index", 7);
  check("future rounds are sealed for the partner too", (future.data ?? []).length === 0);

  const pairs = await alice.from("pairings").select("clue");
  check(
    "pairings table is not readable",
    Boolean(pairs.error) || (pairs.data ?? []).length === 0,
    JSON.stringify(pairs.error?.message ?? pairs.data),
  );

  const allAssignments = await alice
    .from("assignments")
    .select("round_index")
    .eq("game_id", created.game_id);
  check(
    "only the current round's partner row is reachable",
    (allAssignments.data ?? []).length === 1,
    JSON.stringify(allAssignments.data),
  );

  console.log("\nreveal");
  await call(alice, "next_round", { p_game_id: created.game_id });
  stateA = await state(alice, created.game_id);
  check("cannot advance before revealing", stateA.game.state === "guessing");

  await call(alice, "set_reveal_ready", { p_game_id: created.game_id, p_ready: true });
  stateA = await state(alice, created.game_id);
  check("one ready does not reveal", stateA.game.state === "guessing");
  check("own character is still hidden while waiting", stateA.assignments.length === 1);

  await call(bob, "set_reveal_ready", { p_game_id: created.game_id, p_ready: true });
  stateA = await state(alice, created.game_id);
  const revealedAssignments = stateA.assignments;
  check("both ready reveals", stateA.game.state === "revealed");
  check("reveal exposes both characters", revealedAssignments.length === 2, JSON.stringify(revealedAssignments.map((a) => a.seat)));
  check("own character is now visible", revealedAssignments.some((a) => a.seat === ownSeatA));

  console.log("\nrounds");
  await call(alice, "next_round", { p_game_id: created.game_id });
  stateA = await state(alice, created.game_id);
  check("next round resets to guessing", stateA.game.state === "guessing" && stateA.game.round_index === 1);
  check("next round hides the new own character", stateA.assignments.length === 1);
  check("reveal readiness resets", stateA.players.every((p) => !p.revealReady));

  await call(alice, "next_round", { p_game_id: created.game_id });
  stateA = await state(alice, created.game_id);
  check("double press of next round is harmless", stateA.game.round_index === 1);

  await call(bob, "skip_round", { p_game_id: created.game_id });
  stateA = await state(alice, created.game_id);
  check("skip round advances the round", stateA.game.round_index === 2 && stateA.game.state === "guessing");

  const seen = new Set();
  let clues = [];
  for (let i = stateA.game.round_index; i < TOTAL_ROUNDS; i++) {
    const s = await state(alice, created.game_id);
    if (s.game.state === "guessing") {
      clues.push(s.round.clue);
      check(`round ${s.game.round_index} has a partner character`, s.assignments.length === 1);
      if (s.assignments[0]) seen.add(s.assignments[0].character.key);
      await call(alice, "set_reveal_ready", { p_game_id: created.game_id, p_ready: true });
      await call(bob, "set_reveal_ready", { p_game_id: created.game_id, p_ready: true });
    }
    await call(alice, "next_round", { p_game_id: created.game_id });
  }

  stateA = await state(alice, created.game_id);
  check("game finishes after 10 rounds", stateA.game.state === "finished", stateA.game.state);
  check("all 10 clues are unique", new Set(clues).size === clues.length, `${new Set(clues).size}/${clues.length}`);
  check("no character was repeated", seen.size === clues.length, `distinct partner characters: ${seen.size} of ${clues.length}`);

  console.log("\nrematch and leaving");
  await call(bob, "play_again", { p_game_id: created.game_id });
  stateA = await state(alice, created.game_id);
  check("play again returns to the lobby", stateA.game.state === "lobby");
  check("play again clears rounds", (stateA.assignments ?? []).length === 0);

  const found = await call(alice, "find_my_game", {});
  check("find_my_game finds the active room", found?.game_id === created.game_id);

  await call(bob, "leave_game", { p_game_id: created.game_id });
  stateA = await state(alice, created.game_id);
  check("partner leaving is visible", stateA.players.length === 1);
  await call(alice, "leave_game", { p_game_id: created.game_id });
  const gone = await state(alice, created.game_id);
  check("last player leaving deletes the room", gone == null || gone.game == null);

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error("\nTest run crashed:", e.message);
  process.exit(1);
});
