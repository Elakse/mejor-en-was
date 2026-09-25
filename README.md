# Mejor en Was

A two-player hidden-character party game. Each player sees the **other** player's secret
character but never their own. Both get the same clue, you talk it out loud, and when
you are both ready the characters are revealed. Ten rounds per game.

Built as a real, deployable app: Next.js 16 (App Router, TypeScript, Tailwind v4) on
Vercel, Supabase (Postgres + RLS + Realtime) as the backend, no accounts — anonymous
room-based sessions only.

---

## How the hidden information actually works

This is the part that matters, so it is enforced by the database rather than by the UI.

Every browser gets its own anonymous Supabase user. Characters live in `public.assignments`
as one row per `(game, round, seat)`. Row level security means a client can only ever
`SELECT`:

- the **other** seat's row for the **current** round (that is the character you are allowed
  to see), and
- its **own** row, but only once `revealed` has been flipped on by the server.

So a player's own character is not "hidden in the client" — it is never sent to them.
Verified in `scripts/test-game.mjs` (direct SQL for your own seat returns zero rows) and in
`scripts/e2e.mjs`, which drives two real browsers and asserts that before the reveal the
player's own character is absent from the DOM, from every image request and from every JSON
response body.

Supporting decisions:

- `public.pairings` (clue → the two characters) is readable by **nobody**. Otherwise a player
  could look up their partner's character and read off their own.
- Future rounds are sealed for both seats, so nobody can plan ahead.
- All writes go through `SECURITY DEFINER` functions that read `auth.uid()`. Clients hold no
  `INSERT`/`UPDATE` grants at all, so a player cannot unlock a row, start the game early or
  read the next round.
- Reads go through one `get_state()` RPC declared `SECURITY INVOKER`, so RLS decides what
  comes back. It cannot accidentally leak anything.
- Pre-reveal the partner's character is shown **image only**, so recognising it is part of
  the game.

## Stack and architecture

| Piece | Choice | Why |
| --- | --- | --- |
| Frontend | Next.js 16 + React 19 + TypeScript | One deployable app, no separate server to run |
| Styling | Tailwind CSS v4 | Fast to build a polished, mobile-first UI |
| Backend | Supabase Postgres + RLS + Realtime | No custom server; auth, sync and the security model in one place |
| Sync | Realtime `postgres_changes` + 2.5s polling + heartbeat | Instant normally, self-healing if the socket drops |
| Hosting | Vercel | Push and it is live |

Synchronisation is deliberately belt-and-braces: the client subscribes to Realtime changes on
`games` and `players`, **and** polls `get_state` every 2.5 seconds, refreshes on tab focus, and
sends a heartbeat every 20 seconds. Whichever path is available wins, so a flaky socket never
deadlocks a game.

## Gameplay

1. Player 1 taps **Create game**, gets a 4-letter room code (no `I/O/0/1`), a copy button
   and a QR code.
2. Player 2 scans the QR (which opens `/?r=CODE`) or types the code. Joining is a single tap.
3. Both tap **I'm ready** → the server generates 10 rounds and the game starts.
4. Each round: shared clue, the partner's character large in the middle, and
   *"[partner] can see your character — you cannot."*
5. **Ready to reveal** on both devices → reveal both characters → **Next round**.
6. After round 10: recap, **Play again** (same room, fresh rounds) or leave.

Extras: optional 60-second round timer (auto-reveals when it runs out), skip round, fullscreen
button, connection/partner status pill, per-round splash transition, confetti on the final
screen, and a recap of all ten clues.

## Reliability

- Refresh or crash: `find_my_game()` re-attaches you to your live room, and the room code is
  kept in the URL.
- Disconnects: heartbeats plus `last_seen` drive the "Away" indicator; stale seats can be
  reclaimed from a new device (after 90s) without kicking an active player.
- Duplicate tabs / reconnects resolve to the same seat.
- Double-tapping **Next round** is a no-op; the server serialises round changes.
- Invalid, full or expired room codes produce friendly messages.
- Rooms expire after 12 hours and expired rooms are swept when a new game is created.

## Project layout

```
app/                 layout, page, global styles (Tailwind theme + animations)
components/          UI shell, screens (Home, Lobby, Guess, Reveal, Final), primitives
lib/                 Supabase client, anonymous session, the useGame state machine, types
supabase/schema.sql  tables, RLS policies, RPCs, realtime wiring
supabase/seed.sql    generated character and pairing data
supabase/setup.sql   schema.sql + seed.sql — the one file you paste into Supabase
scripts/             catalog tooling, SQL codegen, integration + browser tests
```

## Setup

### 1. Create the Supabase project

1. Create a project at [supabase.com](https://supabase.com).
2. Open **SQL Editor**, paste the entire contents of [`supabase/setup.sql`](supabase/setup.sql)
   and run it. This creates the tables, policies, functions and seeds 176 characters and 131
   curated pairings.
3. Open **Authentication → Sign In / Providers** and enable **Anonymous sign-ins**.
   This is required — the whole hidden-information model is built on it.

### 2. Configure the app

```bash
cp .env.example .env.local
```

Fill in **Project Settings → API** values:

```
NEXT_PUBLIC_SUPABASE_URL=https://your-project-ref.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-public-key
```

The anon key is safe to expose — that is what RLS is for. Never put the service-role key in
the client.

### 3. Run it

```bash
npm install
npm run dev          # http://localhost:3000
```

Open it on two devices (the second can be your phone on the same network via
`http://<your-lan-ip>:3000`).

## Commands

| Command | What it does |
| --- | --- |
| `npm run dev` | Dev server |
| `npm run build` / `npm start` | Production build / serve |
| `npm run lint` | ESLint (includes React Compiler purity rules) |
| `npm run typecheck` | `tsc --noEmit` |
| `npm run test:game` | Backend integration test against Supabase (RLS, RPCs, full game) |
| `npm run test:e2e` | Two-browser Playwright test, including anti-spoiler assertions |
| `npm run validate:catalog` | Checks pairings really satisfy their clue and 10 rounds always fit |
| `npm run check:images` | HEAD-checks every character image URL |
| `npm run build:sql` | Regenerates `seed.sql` / `setup.sql` from `scripts/catalog.json` |
| `npm run find:images` | Builds candidate contact sheets for replacing an image |

### Local Supabase (optional, for the tests)

```bash
npx supabase start     # requires Docker
npx supabase db reset  # applies supabase/migrations + seed.sql
npm run test:game
```

`supabase/config.toml` already has anonymous sign-ins enabled for the local stack. Add
`.env.local` values for the local URL/key that `supabase start` prints (or use the defaults in
`scripts/test-game.mjs`).

For `npm run test:e2e`, build and serve on port 3100 first:

```bash
npm run build && npm start -- -p 3100
npm run test:e2e
```

## Deploy

1. Push the repository to GitHub.
2. Import it on [Vercel](https://vercel.com/new). The default Next.js settings are correct.
3. Add the two `NEXT_PUBLIC_SUPABASE_*` environment variables for Production and Preview.
4. Deploy, then open the URL on two phones.

Or from the CLI:

```bash
npm i -g vercel
vercel --prod
```

No environment variables are needed at build time beyond the two public Supabase values.

## Content

- **176 characters / 131 pairings** across 63 categories, hand-curated and validated by
  `scripts/validate-catalog.mjs`, which fails the build if a pairing does not genuinely share
  the trait its clue claims.
- Each game picks 10 pairings at random with **no repeated character and no repeated
  category** (server-side, in `generate_rounds()`), which seat gets which character is
  randomised too.
- Characters are deliberately recognisable-but-not-the-poster-child: Waluigi rather than
  Mario, Krusty rather than Homer, Dr. Eggman rather than Sonic, Milhouse rather than Bart.
- Round data is static in Postgres. Nothing is generated per game and no AI calls are made
  at runtime.

### Images

Images link directly to Wikipedia/Wikimedia (`upload.wikimedia.org` and
`en.wikipedia.org/wiki/Special:FilePath`), resolved once at authoring time and stored in the
`characters` table with a credit and source URL. All 183 candidates were downloaded and
reviewed by hand; thirteen were replaced with better shots and seven characters whose only
available image was a logo, a group shot or the wrong subject were dropped entirely rather
than shipped broken.

If an image fails to load at runtime the card degrades to a large emoji plus the character
name, so the game never shows a broken image.

> **Licensing note.** Some character images are low-resolution non-free promotional images
> hosted by Wikipedia, used here for a private party game. If you plan to run this publicly or
> commercially, swap in your own assets: update `characters.image_url` (either in
> `supabase/setup.sql` before running it, or directly in the table) and regenerate with
> `npm run build:sql`. `npm run find:images <key>` builds a contact sheet of free-licensed
> candidates to help.

## Known trade-offs

- Polling runs every 2.5s as a safety net. It costs a trivial amount of database work for a
  two-player game and removes a whole class of "socket died" bugs.
- The 4-letter code space is ~923k combinations with a 12-hour expiry, which is plenty for
  friends sitting together. It is not a secret; the RLS layer is what protects the game state.
- Rooms live in Postgres, not memory, so any serverless function can serve any request.
