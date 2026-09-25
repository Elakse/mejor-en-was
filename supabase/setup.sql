-- ===========================================================================
--  Mejor en Was — one-shot setup.
--  Paste this entire file into the Supabase SQL editor and run it.
--  (Equivalent to supabase/schema.sql followed by supabase/seed.sql.)
-- ===========================================================================

-- ============================================================================
--  Mejor en Was — database schema
--  Paste this whole file (or supabase/setup.sql) into the Supabase SQL editor.
--
--  Hidden-information model
--  -----------------------
--  Every client is an anonymous Supabase user. The only way a browser can learn
--  about a secret character is by SELECTing `public.assignments`, and row level
--  security only ever exposes:
--     * the OTHER seat's row for the CURRENT round (what you are allowed to see)
--     * your own row, but only after `revealed` is flipped by the server
--  All mutations go through SECURITY DEFINER functions that read auth.uid(),
--  so a client cannot flip a flag, unlock a row, or read a future round.
--  `public.pairings` is readable by nobody, which stops a player from working
--  out their own character by looking up their partner's pairings.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- catalog (public, non-secret)
-- ---------------------------------------------------------------------------
create table if not exists public.characters (
  key           text primary key,
  name          text not null,
  image_url     text not null,
  image_credit  text not null default '',
  source_url    text not null default '',
  emoji         text not null default '❓',
  is_free_image boolean not null default false
);

-- Never exposed to clients: knowing all pairings would let a player deduce
-- their own character from their partner's clue.
create table if not exists public.pairings (
  id           serial primary key,
  category     text not null,
  clue         text not null,
  char_a       text not null references public.characters(key),
  char_b       text not null references public.characters(key)
);

-- ---------------------------------------------------------------------------
-- live game state
-- ---------------------------------------------------------------------------
create table if not exists public.games (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  state            text not null default 'lobby'
                   check (state in ('lobby', 'guessing', 'revealed', 'finished')),
  round_index      smallint not null default 0 check (round_index between 0 and 9),
  use_timer        boolean not null default false,
  round_started_at timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  expires_at       timestamptz not null default now() + interval '12 hours'
);

create table if not exists public.players (
  id           uuid primary key default gen_random_uuid(),
  game_id      uuid not null references public.games(id) on delete cascade,
  uid          uuid not null,
  seat         smallint not null check (seat in (1, 2)),
  name         text not null,
  ready        boolean not null default false,
  reveal_ready boolean not null default false,
  created_at   timestamptz not null default now(),
  last_seen    timestamptz not null default now(),
  unique (game_id, seat),
  unique (game_id, uid)
);

create table if not exists public.game_rounds (
  game_id     uuid not null references public.games(id) on delete cascade,
  round_index smallint not null,
  clue        text not null,
  category    text not null,
  primary key (game_id, round_index)
);

create table if not exists public.assignments (
  game_id       uuid not null references public.games(id) on delete cascade,
  round_index   smallint not null,
  seat          smallint not null check (seat in (1, 2)),
  character_key text not null references public.characters(key),
  revealed      boolean not null default false,
  primary key (game_id, round_index, seat)
);

create index if not exists players_game_idx on public.players (game_id);
create index if not exists assignments_game_round_idx on public.assignments (game_id, round_index);

-- ---------------------------------------------------------------------------
-- identity helpers (SECURITY DEFINER so RLS policies can query players)
-- ---------------------------------------------------------------------------
create or replace function public.my_game_ids()
returns setof uuid
language sql security definer stable
set search_path = public, pg_temp
as $$
  select game_id from public.players where uid = auth.uid();
$$;

create or replace function public.my_seat(p_game_id uuid)
returns smallint
language sql security definer stable
set search_path = public, pg_temp
as $$
  select seat from public.players
  where game_id = p_game_id and uid = auth.uid()
  limit 1;
$$;

create or replace function public.current_round_of(p_game_id uuid)
returns smallint
language sql security definer stable
set search_path = public, pg_temp
as $$
  select round_index from public.games where id = p_game_id;
$$;

create or replace function public.is_player(p_game_id uuid)
returns boolean
language sql security definer stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.players where game_id = p_game_id and uid = auth.uid()
  );
$$;

-- ---------------------------------------------------------------------------
-- row level security
-- ---------------------------------------------------------------------------
alter table public.characters   enable row level security;
alter table public.pairings     enable row level security;
alter table public.games        enable row level security;
alter table public.players      enable row level security;
alter table public.game_rounds  enable row level security;
alter table public.assignments  enable row level security;

drop policy if exists "characters are public" on public.characters;
create policy "characters are public"
  on public.characters for select
  to anon, authenticated
  using (true);

drop policy if exists "players read their game" on public.games;
create policy "players read their game"
  on public.games for select
  to authenticated
  using (id in (select public.my_game_ids()));

drop policy if exists "players read players" on public.players;
create policy "players read players"
  on public.players for select
  to authenticated
  using (game_id in (select public.my_game_ids()));

-- Clues are only visible for rounds that have already started.
drop policy if exists "players read started rounds" on public.game_rounds;
create policy "players read started rounds"
  on public.game_rounds for select
  to authenticated
  using (
    game_id in (select public.my_game_ids())
    and round_index <= public.current_round_of(game_id)
  );

-- The whole point: you may read your partner's character for the current round,
-- and your own character only once the server has marked the round revealed.
-- Future rounds stay sealed for both seats.
drop policy if exists "players read allowed assignments" on public.assignments;
create policy "players read allowed assignments"
  on public.assignments for select
  to authenticated
  using (
    game_id in (select public.my_game_ids())
    and (
      revealed
      or (
        round_index = public.current_round_of(game_id)
        and seat <> coalesce(public.my_seat(game_id), -1::smallint)
      )
    )
  );

-- ---------------------------------------------------------------------------
-- grants: default Supabase grants are wide, so reset and hand out exactly what
-- clients need. `pairings` is never granted.
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
grant select on public.characters to anon, authenticated;
grant select on public.games, public.players, public.game_rounds, public.assignments to authenticated;

revoke all on all functions in schema public from anon, authenticated;
grant execute on function public.my_game_ids() to authenticated;
grant execute on function public.my_seat(uuid) to authenticated;
grant execute on function public.current_round_of(uuid) to authenticated;
grant execute on function public.is_player(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- round generation
-- ---------------------------------------------------------------------------
create or replace function public.generate_rounds(p_game_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_pair       record;
  v_used       text[] := array[]::text[];
  v_categories text[] := array[]::text[];
  v_index      smallint := 0;
  v_pass       int;
  v_a          text;
  v_b          text;
begin
  delete from public.assignments where game_id = p_game_id;
  delete from public.game_rounds where game_id = p_game_id;

  -- pass 1 keeps clue categories varied, pass 2 relaxes only that constraint
  for v_pass in 1..2 loop
    for v_pair in
      select p.category, p.clue, p.char_a, p.char_b
      from public.pairings p
      order by random()
    loop
      exit when v_index >= 10;

      if v_pass = 1 and v_pair.category = any (v_categories) then
        continue;
      end if;
      if v_pair.char_a = any (v_used) or v_pair.char_b = any (v_used) then
        continue;
      end if;

      -- randomise which seat gets which character so it is not always seat 1
      if random() < 0.5 then
        v_a := v_pair.char_a;
        v_b := v_pair.char_b;
      else
        v_a := v_pair.char_b;
        v_b := v_pair.char_a;
      end if;

      insert into public.game_rounds (game_id, round_index, clue, category)
      values (p_game_id, v_index, v_pair.clue, v_pair.category);

      insert into public.assignments (game_id, round_index, seat, character_key)
      values (p_game_id, v_index, 1, v_a), (p_game_id, v_index, 2, v_b);

      v_used := v_used || v_a || v_b;
      v_categories := v_categories || v_pair.category;
      v_index := v_index + 1;
    end loop;
    exit when v_index >= 10;
  end loop;

  if v_index < 10 then
    raise exception 'not_enough_pairings';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- mutations (all server authoritative)
-- ---------------------------------------------------------------------------
create or replace function public.create_game(p_name text default 'Player 1')
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid      uuid := auth.uid();
  v_alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code     text;
  v_game_id  uuid;
  v_try      int := 0;
  v_name     text := left(coalesce(nullif(btrim(p_name), ''), 'Player 1'), 18);
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  delete from public.games where expires_at < now();

  loop
    v_try := v_try + 1;
    v_code := '';
    for i in 1..4 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.games g where g.code = v_code);
    if v_try > 40 then
      raise exception 'could_not_allocate_code';
    end if;
  end loop;

  insert into public.games (code) values (v_code) returning id into v_game_id;
  insert into public.players (game_id, uid, seat, name) values (v_game_id, v_uid, 1, v_name);

  return jsonb_build_object('game_id', v_game_id, 'code', v_code, 'seat', 1);
end;
$$;

create or replace function public.join_game(p_code text, p_name text default 'Player 2')
returns jsonb
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_uid      uuid := auth.uid();
  v_game     public.games;
  v_name     text := left(coalesce(nullif(btrim(p_name), ''), 'Player 2'), 18);
  v_existing public.players;
  v_stale    boolean;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_game from public.games where code = upper(btrim(p_code));
  if not found then
    raise exception 'room_not_found';
  end if;
  if v_game.expires_at < now() then
    raise exception 'room_expired';
  end if;

  select * into v_existing from public.players where game_id = v_game.id and uid = v_uid;
  if found then
    update public.players set last_seen = now(), name = v_name where id = v_existing.id;
    return jsonb_build_object('game_id', v_game.id, 'code', v_game.code, 'seat', v_existing.seat);
  end if;

  select * into v_existing from public.players where game_id = v_game.id and seat = 2;
  if found then
    -- Let a partner who lost their session (new anonymous account, cleared
    -- storage, new device) reclaim the seat, but never steal a seat from
    -- someone who is actively connected.
    v_stale := v_existing.last_seen < now() - interval '90 seconds';
    if not v_stale then
      raise exception 'room_full';
    end if;
    delete from public.players where id = v_existing.id;
    if v_game.state <> 'lobby' then
      delete from public.assignments where game_id = v_game.id;
      delete from public.game_rounds where game_id = v_game.id;
      update public.games
        set state = 'lobby', round_index = 0, round_started_at = null, updated_at = now()
        where id = v_game.id;
      update public.players set ready = false, reveal_ready = false where game_id = v_game.id;
    end if;
  end if;

  insert into public.players (game_id, uid, seat, name) values (v_game.id, v_uid, 2, v_name);
  return jsonb_build_object('game_id', v_game.id, 'code', v_game.code, 'seat', 2);
end;
$$;

create or replace function public.heartbeat(p_game_id uuid)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  update public.players set last_seen = now()
  where game_id = p_game_id and uid = auth.uid();
$$;

create or replace function public.set_lobby_ready(p_game_id uuid, p_ready boolean)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_state    text;
  v_players  int;
  v_ready    int;
begin
  if not public.is_player(p_game_id) then
    raise exception 'not_a_player';
  end if;

  select state into v_state from public.games where id = p_game_id for update;
  if v_state is null then
    raise exception 'not_found';
  end if;

  update public.players set ready = p_ready, last_seen = now()
  where game_id = p_game_id and uid = auth.uid();

  if v_state = 'lobby' then
    select count(*), count(*) filter (where ready)
      into v_players, v_ready
      from public.players where game_id = p_game_id;

    if v_players = 2 and v_ready = 2 then
      perform public.generate_rounds(p_game_id);
      update public.games
        set state = 'guessing', round_index = 0, round_started_at = now(), updated_at = now()
        where id = p_game_id;
      update public.players set ready = false, reveal_ready = false where game_id = p_game_id;
    end if;
  end if;
end;
$$;

create or replace function public.set_timer(p_game_id uuid, p_enabled boolean)
returns void
language sql security definer
set search_path = public, pg_temp
as $$
  update public.games set use_timer = p_enabled, updated_at = now()
  where id = p_game_id and state = 'lobby' and public.is_player(p_game_id);
$$;

create or replace function public.set_reveal_ready(p_game_id uuid, p_ready boolean)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_state  text;
  v_round  smallint;
  v_waiting int;
begin
  if not public.is_player(p_game_id) then
    raise exception 'not_a_player';
  end if;

  select state, round_index into v_state, v_round
  from public.games where id = p_game_id for update;

  if v_state <> 'guessing' then
    return;
  end if;

  update public.players set reveal_ready = p_ready, last_seen = now()
  where game_id = p_game_id and uid = auth.uid();

  select count(*) filter (where not reveal_ready) into v_waiting
  from public.players where game_id = p_game_id;

  if v_waiting = 0 then
    update public.games set state = 'revealed', updated_at = now() where id = p_game_id;
    update public.assignments set revealed = true
    where game_id = p_game_id and round_index = v_round;
  end if;
end;
$$;

-- p_allow_guessing = false for "Next Round" (only valid once both players have
-- revealed), true for "Skip Round" (valid while still guessing).
create or replace function public.advance_round(p_game_id uuid, p_allow_guessing boolean)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_state text;
  v_round smallint;
begin
  if not public.is_player(p_game_id) then
    raise exception 'not_a_player';
  end if;

  select state, round_index into v_state, v_round
  from public.games where id = p_game_id for update;

  if v_state = 'guessing' and not p_allow_guessing then
    return;
  end if;
  if v_state not in ('guessing', 'revealed') then
    return;
  end if;

  if v_round >= 9 then
    update public.games set state = 'finished', updated_at = now() where id = p_game_id;
  else
    update public.games
      set round_index = v_round + 1, state = 'guessing',
          round_started_at = now(), updated_at = now()
      where id = p_game_id;
    update public.players set reveal_ready = false where game_id = p_game_id;
  end if;
end;
$$;

create or replace function public.next_round(p_game_id uuid)
returns void language sql security definer set search_path = public, pg_temp
as $$ select public.advance_round(p_game_id, false); $$;

create or replace function public.skip_round(p_game_id uuid)
returns void language sql security definer set search_path = public, pg_temp
as $$ select public.advance_round(p_game_id, true); $$;

create or replace function public.play_again(p_game_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_state text;
begin
  if not public.is_player(p_game_id) then
    raise exception 'not_a_player';
  end if;

  select state into v_state from public.games where id = p_game_id for update;
  if v_state is distinct from 'finished' then
    return;
  end if;

  delete from public.assignments where game_id = p_game_id;
  delete from public.game_rounds where game_id = p_game_id;
  update public.games
    set state = 'lobby', round_index = 0, round_started_at = null,
        updated_at = now(), expires_at = now() + interval '12 hours'
    where id = p_game_id;
  update public.players set ready = false, reveal_ready = false where game_id = p_game_id;
end;
$$;

create or replace function public.leave_game(p_game_id uuid)
returns void
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_state text;
  v_left  int;
begin
  select state into v_state from public.games where id = p_game_id for update;
  if v_state is null then
    return;
  end if;

  delete from public.players where game_id = p_game_id and uid = auth.uid();

  select count(*) into v_left from public.players where game_id = p_game_id;
  if v_left = 0 then
    delete from public.games where id = p_game_id;
  elsif v_state <> 'lobby' then
    delete from public.assignments where game_id = p_game_id;
    delete from public.game_rounds where game_id = p_game_id;
    update public.games
      set state = 'lobby', round_index = 0, round_started_at = null, updated_at = now()
      where id = p_game_id;
    update public.players set ready = false, reveal_ready = false where game_id = p_game_id;
  end if;
end;
$$;

create or replace function public.find_my_game()
returns jsonb
language sql security definer stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object('game_id', g.id, 'code', g.code, 'seat', p.seat)
  from public.players p
  join public.games g on g.id = p.game_id
  where p.uid = auth.uid() and g.expires_at > now()
  order by p.created_at desc
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- sanctioned read API: this is the ONLY thing clients call to read game state.
-- It is SECURITY INVOKER on purpose, so the RLS policies above decide exactly
-- which rows come back. A non-player gets null; nobody gets future rounds or
-- an unrevealed own character.
-- ---------------------------------------------------------------------------
create or replace function public.get_state(p_game_id uuid)
returns jsonb
language sql stable security invoker
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'serverNow', (extract(epoch from now()) * 1000)::bigint,
    'game', to_jsonb(g),
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'seat', p.seat, 'name', p.name, 'ready', p.ready,
        'revealReady', p.reveal_ready, 'isMe', p.uid = auth.uid(),
        'lastSeen', (extract(epoch from p.last_seen) * 1000)::bigint
      ) order by p.seat)
      from public.players p where p.game_id = g.id
    ), '[]'::jsonb),
    'round', (
      select jsonb_build_object(
        'index', r.round_index, 'clue', r.clue, 'category', r.category, 'total', 10)
      from public.game_rounds r
      where r.game_id = g.id and r.round_index = g.round_index
    ),
    'assignments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'seat', a.seat, 'revealed', a.revealed,
        'character', jsonb_build_object(
          'key', c.key, 'name', c.name, 'imageUrl', c.image_url,
          'imageCredit', c.image_credit, 'emoji', c.emoji))
        order by a.seat)
      from public.assignments a
      join public.characters c on c.key = a.character_key
      where a.game_id = g.id and a.round_index = g.round_index
    ), '[]'::jsonb)
  )
  from public.games g
  where g.id = p_game_id;
$$;

grant execute on function public.create_game(text)                 to authenticated;
grant execute on function public.join_game(text, text)            to authenticated;
grant execute on function public.find_my_game()                   to authenticated;
grant execute on function public.get_state(uuid)                  to authenticated;
grant execute on function public.heartbeat(uuid)                  to authenticated;
grant execute on function public.set_lobby_ready(uuid, boolean)   to authenticated;
grant execute on function public.set_timer(uuid, boolean)         to authenticated;
grant execute on function public.set_reveal_ready(uuid, boolean)  to authenticated;
grant execute on function public.next_round(uuid)                 to authenticated;
grant execute on function public.skip_round(uuid)                 to authenticated;
grant execute on function public.play_again(uuid)                 to authenticated;
grant execute on function public.leave_game(uuid)                 to authenticated;

-- ---------------------------------------------------------------------------
-- realtime (clients still poll get_state as a safety net)
-- ---------------------------------------------------------------------------
alter table public.games   replica identity full;
alter table public.players replica identity full;

do $$
begin
  begin
    alter publication supabase_realtime add table public.games;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.players;
  exception when duplicate_object then null;
  end;
end $$;

-- Call signaling carries only WebRTC descriptions and ICE candidates. A private
-- Realtime topic can be joined only by a seated player in that game.
drop policy if exists "players receive call signaling" on realtime.messages;
create policy "players receive call signaling"
  on realtime.messages for select to authenticated
  using (
    extension = 'broadcast' and exists (
      select 1 from public.players p
      join public.players other on other.game_id = p.game_id and other.seat <> p.seat
      where p.uid = (select auth.uid())
        and (select realtime.topic()) = 'call:' || p.game_id::text || ':' ||
          least(p.id::text, other.id::text) || ':' || greatest(p.id::text, other.id::text)
    )
  );

drop policy if exists "players send call signaling" on realtime.messages;
create policy "players send call signaling"
  on realtime.messages for insert to authenticated
  with check (
    extension = 'broadcast' and exists (
      select 1 from public.players p
      join public.players other on other.game_id = p.game_id and other.seat <> p.seat
      where p.uid = (select auth.uid())
        and (select realtime.topic()) = 'call:' || p.game_id::text || ':' ||
          least(p.id::text, other.id::text) || ':' || greatest(p.id::text, other.id::text)
    )
  );

-- ---------------------------------------------------------------------------
-- Seed data: characters and curated pairings. Generated by scripts/build-supabase.mjs
-- ---------------------------------------------------------------------------

truncate table public.assignments, public.game_rounds, public.games, public.players, public.pairings, public.characters restart identity cascade;

insert into public.characters (key, name, image_url, image_credit, source_url, emoji, is_free_image) values
  ('ned-flanders', 'Ned Flanders', 'https://upload.wikimedia.org/wikipedia/en/8/84/Ned_Flanders.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Ned Flanders', 'https://en.wikipedia.org/wiki/Ned_Flanders', '🙏', false),
  ('groundskeeper-willie', 'Groundskeeper Willie', 'https://upload.wikimedia.org/wikipedia/en/d/dc/GroundskeeperWillie.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Groundskeeper Willie', 'https://en.wikipedia.org/wiki/Groundskeeper_Willie', '🧑‍🌾', false),
  ('krusty-the-clown', 'Krusty the Clown', 'https://upload.wikimedia.org/wikipedia/en/5/5a/Krustytheclown.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Krusty the Clown', 'https://en.wikipedia.org/wiki/Krusty_the_Clown', '🤡', false),
  ('barney-gumble', 'Barney Gumble', 'https://upload.wikimedia.org/wikipedia/en/d/de/Barney_Gumble.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Barney Gumble', 'https://en.wikipedia.org/wiki/Barney_Gumble', '🍺', false),
  ('milhouse', 'Milhouse Van Houten', 'https://upload.wikimedia.org/wikipedia/en/1/11/Milhouse_Van_Houten.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Milhouse Van Houten', 'https://en.wikipedia.org/wiki/Milhouse_Van_Houten', '👓', false),
  ('moe-szyslak', 'Moe Szyslak', 'https://upload.wikimedia.org/wikipedia/en/8/80/Moe_Szyslak.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Moe Szyslak', 'https://en.wikipedia.org/wiki/Moe_Szyslak', '🍸', false),
  ('chief-wiggum', 'Chief Wiggum', 'https://upload.wikimedia.org/wikipedia/en/7/7a/Chief_Wiggum.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Chief Wiggum', 'https://en.wikipedia.org/wiki/Chief_Wiggum', '🚓', false),
  ('smithers', 'Waylon Smithers', 'https://upload.wikimedia.org/wikipedia/en/8/86/Waylon_Smithers_1.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Waylon Smithers', 'https://en.wikipedia.org/wiki/Waylon_Smithers', '📋', false),
  ('sideshow-bob', 'Sideshow Bob', 'https://upload.wikimedia.org/wikipedia/en/c/c8/C-bob.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Sideshow Bob', 'https://en.wikipedia.org/wiki/Sideshow_Bob', '🔪', false),
  ('cartman', 'Eric Cartman', 'https://upload.wikimedia.org/wikipedia/en/7/77/EricCartman.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Eric Cartman', 'https://en.wikipedia.org/wiki/Eric_Cartman', '🧢', false),
  ('kenny', 'Kenny McCormick', 'https://upload.wikimedia.org/wikipedia/en/6/6f/KennyMcCormick.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Kenny McCormick', 'https://en.wikipedia.org/wiki/Kenny_McCormick', '🧥', false),
  ('butters', 'Butters Stotch', 'https://upload.wikimedia.org/wikipedia/en/0/06/ButtersStotch.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Butters Stotch', 'https://en.wikipedia.org/wiki/Butters_Stotch', '😇', false),
  ('wendy-testaburger', 'Wendy Testaburger', 'https://upload.wikimedia.org/wikipedia/en/a/ab/Wendy_South_Park.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Wendy Testaburger', 'https://en.wikipedia.org/wiki/Wendy_Testaburger', '🎀', false),
  ('rick-sanchez', 'Rick Sanchez', 'https://upload.wikimedia.org/wikipedia/en/a/a6/Rick_Sanchez.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Rick Sanchez', 'https://en.wikipedia.org/wiki/Rick_Sanchez', '🧪', false),
  ('mr-meeseeks', 'Mr. Meeseeks', 'https://upload.wikimedia.org/wikipedia/en/1/1d/Mr._Meeseeks.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Mr. Meeseeks', 'https://en.wikipedia.org/wiki/Mr._Meeseeks', '🟦', false),
  ('turanga-leela', 'Turanga Leela', 'https://upload.wikimedia.org/wikipedia/en/d/d4/Turanga_Leela.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Leela (Futurama)', 'https://en.wikipedia.org/wiki/Leela_(Futurama)', '👁️', false),
  ('peter-griffin', 'Peter Griffin', 'https://upload.wikimedia.org/wikipedia/en/c/c2/Peter_Griffin.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Peter Griffin', 'https://en.wikipedia.org/wiki/Peter_Griffin', '👨', false),
  ('stewie-griffin', 'Stewie Griffin', 'https://upload.wikimedia.org/wikipedia/en/0/02/Stewie_Griffin.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Stewie Griffin', 'https://en.wikipedia.org/wiki/Stewie_Griffin', '🍼', false),
  ('quagmire', 'Glenn Quagmire', 'https://upload.wikimedia.org/wikipedia/en/f/fe/Glenn_Quagmire.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Glenn Quagmire', 'https://en.wikipedia.org/wiki/Glenn_Quagmire', '🕺', false),
  ('brian-griffin', 'Brian Griffin', 'https://upload.wikimedia.org/wikipedia/en/1/12/Brian_Griffin.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Brian Griffin', 'https://en.wikipedia.org/wiki/Brian_Griffin', '🐶', false),
  ('bender', 'Bender', 'https://upload.wikimedia.org/wikipedia/en/a/a6/Bender_Rodriguez.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Bender (Futurama)', 'https://en.wikipedia.org/wiki/Bender_(Futurama)', '🤖', false),
  ('zoidberg', 'Doctor Zoidberg', 'https://upload.wikimedia.org/wikipedia/en/4/4a/Dr_John_Zoidberg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Zoidberg', 'https://en.wikipedia.org/wiki/Zoidberg', '🦞', false),
  ('the-riddler', 'The Riddler', 'https://upload.wikimedia.org/wikipedia/en/6/68/Riddler.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Riddler', 'https://en.wikipedia.org/wiki/Riddler', '❓', false),
  ('catwoman', 'Catwoman', 'https://en.wikipedia.org/wiki/Special:FilePath/Adam%20Hughe''s%20Catwoman.jpg?width=900', 'Wikipedia — Catwoman', 'https://en.wikipedia.org/wiki/Catwoman', '🐈', true),
  ('poison-ivy', 'Poison Ivy', 'https://upload.wikimedia.org/wikipedia/en/5/5c/Poison_Ivy_Batman_Vol_3_26.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Poison Ivy (character)', 'https://en.wikipedia.org/wiki/Poison_Ivy_(character)', '🌿', false),
  ('bane', 'Bane', 'https://upload.wikimedia.org/wikipedia/en/5/59/Bane_%28DC_Comics_character%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Bane (DC Comics)', 'https://en.wikipedia.org/wiki/Bane_(DC_Comics)', '💪', false),
  ('scarecrow', 'Scarecrow', 'https://en.wikipedia.org/wiki/Special:FilePath/Asthecrowflies.jpg?width=900', 'Wikipedia — Scarecrow (DC Comics)', 'https://en.wikipedia.org/wiki/Scarecrow_(DC_Comics)', '🎃', true),
  ('two-face', 'Two-Face', 'https://upload.wikimedia.org/wikipedia/en/0/02/TwoFaceYearOne.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Two-Face', 'https://en.wikipedia.org/wiki/Two-Face', '🪙', false),
  ('alfred', 'Alfred Pennyworth', 'https://en.wikipedia.org/wiki/Special:FilePath/Alfred%20Pennyworth%20(Earth%20One).jpg?width=900', 'Wikipedia — Alfred Pennyworth', 'https://en.wikipedia.org/wiki/Alfred_Pennyworth', '🎩', true),
  ('wolverine', 'Wolverine', 'https://upload.wikimedia.org/wikipedia/en/d/d3/Wolverine_%28circa_2024%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Wolverine (character)', 'https://en.wikipedia.org/wiki/Wolverine_(character)', '🗡️', false),
  ('deadpool', 'Deadpool', 'https://upload.wikimedia.org/wikipedia/en/c/ca/Deadpool.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Deadpool', 'https://en.wikipedia.org/wiki/Deadpool', '🗡️', false),
  ('magneto', 'Magneto', 'https://upload.wikimedia.org/wikipedia/en/e/e9/Magneto_%28Marvel_Comics_character%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Magneto (Marvel Comics)', 'https://en.wikipedia.org/wiki/Magneto_(Marvel_Comics)', '🧲', false),
  ('mystique', 'Mystique', 'https://upload.wikimedia.org/wikipedia/en/6/68/Mystique_%28circa_2020%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Mystique (character)', 'https://en.wikipedia.org/wiki/Mystique_(character)', '🔵', false),
  ('thanos', 'Thanos', 'https://upload.wikimedia.org/wikipedia/en/b/b7/Thanos_%28Infobox_image%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Thanos', 'https://en.wikipedia.org/wiki/Thanos', '💜', false),
  ('groot', 'Groot', 'https://upload.wikimedia.org/wikipedia/en/3/3b/Groot.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Groot', 'https://en.wikipedia.org/wiki/Groot', '🌳', false),
  ('rocket-raccoon', 'Rocket Raccoon', 'https://upload.wikimedia.org/wikipedia/en/1/1b/Rocketraccoon.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Rocket Raccoon', 'https://en.wikipedia.org/wiki/Rocket_Raccoon', '🦝', false),
  ('doctor-strange', 'Doctor Strange', 'https://upload.wikimedia.org/wikipedia/en/4/4f/Doctor_Strange_Vol_4_2_Ross_Variant_Textless.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Doctor Strange', 'https://en.wikipedia.org/wiki/Doctor_Strange', '🔮', false),
  ('hulk', 'Hulk', 'https://upload.wikimedia.org/wikipedia/en/a/aa/Hulk_%28circa_2019%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Hulk', 'https://en.wikipedia.org/wiki/Hulk', '💚', false),
  ('gandalf', 'Gandalf', 'https://en.wikipedia.org/wiki/Special:FilePath/BakshiGandalf.JPG?width=900', 'Wikipedia — Gandalf', 'https://en.wikipedia.org/wiki/Gandalf', '🧙', true),
  ('hagrid', 'Rubeus Hagrid', 'https://upload.wikimedia.org/wikipedia/en/1/10/RubeusHagrid.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Hagrid', 'https://en.wikipedia.org/wiki/Hagrid', '🧔', false),
  ('snape', 'Severus Snape', 'https://upload.wikimedia.org/wikipedia/en/b/b9/Ootp076.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Severus Snape', 'https://en.wikipedia.org/wiki/Severus_Snape', '🖤', false),
  ('dumbledore', 'Albus Dumbledore', 'https://upload.wikimedia.org/wikipedia/en/e/e8/Dumbledore_-_Prisoner_of_Azkaban.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Albus Dumbledore', 'https://en.wikipedia.org/wiki/Albus_Dumbledore', '🧙', false),
  ('mcgonagall', 'Minerva McGonagall', 'https://upload.wikimedia.org/wikipedia/en/e/ea/McGonagall_%28screenshot%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Minerva McGonagall', 'https://en.wikipedia.org/wiki/Minerva_McGonagall', '🐈‍⬛', false),
  ('chewbacca', 'Chewbacca', 'https://upload.wikimedia.org/wikipedia/en/f/f1/Chewbacca.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Chewbacca', 'https://en.wikipedia.org/wiki/Chewbacca', '🦍', false),
  ('yoda', 'Yoda', 'https://upload.wikimedia.org/wikipedia/en/9/9b/Yoda_Empire_Strikes_Back.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Yoda', 'https://en.wikipedia.org/wiki/Yoda', '👽', false),
  ('darth-maul', 'Darth Maul', 'https://upload.wikimedia.org/wikipedia/en/b/bb/MaulStarWars.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Darth Maul', 'https://en.wikipedia.org/wiki/Darth_Maul', '🔴', false),
  ('jabba', 'Jabba the Hutt', 'https://upload.wikimedia.org/wikipedia/en/5/53/Jabba_the_Hutt_in_Return_of_the_Jedi_%281983%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Jabba the Hutt', 'https://en.wikipedia.org/wiki/Jabba_the_Hutt', '🐌', false),
  ('grogu', 'Grogu', 'https://upload.wikimedia.org/wikipedia/en/a/a0/Grogu_%28Star_Wars%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Grogu', 'https://en.wikipedia.org/wiki/Grogu', '👶', false),
  ('darth-vader', 'Darth Vader', 'https://upload.wikimedia.org/wikipedia/en/0/0b/Darth_Vader_in_The_Empire_Strikes_Back.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Darth Vader', 'https://en.wikipedia.org/wiki/Darth_Vader', '😈', false),
  ('obi-wan', 'Obi-Wan Kenobi', 'https://upload.wikimedia.org/wikipedia/en/3/32/Ben_Kenobi.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Obi-Wan Kenobi', 'https://en.wikipedia.org/wiki/Obi-Wan_Kenobi', '🧔', false),
  ('cookie-monster', 'Cookie Monster', 'https://upload.wikimedia.org/wikipedia/en/5/5e/Cisforcookie.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Cookie Monster', 'https://en.wikipedia.org/wiki/Cookie_Monster', '🍪', false),
  ('count-von-count', 'Count von Count', 'https://upload.wikimedia.org/wikipedia/en/2/29/Count_von_Count_kneeling.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Count von Count', 'https://en.wikipedia.org/wiki/Count_von_Count', '🧛', false),
  ('grover', 'Grover', 'https://upload.wikimedia.org/wikipedia/en/b/be/Grover.JPG?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Grover', 'https://en.wikipedia.org/wiki/Grover', '🔵', false),
  ('animal-muppet', 'Animal', 'https://upload.wikimedia.org/wikipedia/en/e/e7/Animal_%28Muppet%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Animal (Muppet)', 'https://en.wikipedia.org/wiki/Animal_(Muppet)', '🥁', false),
  ('bert-ernie', 'Bert and Ernie', 'https://upload.wikimedia.org/wikipedia/en/f/f1/Bert_and_Ernie.JPG?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Bert and Ernie', 'https://en.wikipedia.org/wiki/Bert_and_Ernie', '🛁', false),
  ('thomas-tank', 'Thomas the Tank Engine', 'https://upload.wikimedia.org/wikipedia/en/e/eb/Thomas_the_Tank_Engine_1946.webp?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Thomas the Tank Engine', 'https://en.wikipedia.org/wiki/Thomas_the_Tank_Engine', '🚂', false),
  ('peppa-pig', 'Peppa Pig', 'https://en.wikipedia.org/wiki/Special:FilePath/PeppaPigAldridge2009.jpg?width=900', 'Wikipedia — Peppa Pig', 'https://en.wikipedia.org/wiki/Peppa_Pig', '🐷', true),
  ('grinch', 'The Grinch', 'https://upload.wikimedia.org/wikipedia/en/7/73/The_Grinch.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Grinch', 'https://en.wikipedia.org/wiki/Grinch', '🎄', false),
  ('olaf', 'Olaf', 'https://upload.wikimedia.org/wikipedia/en/6/6d/Olaf_from_Disney%27s_Frozen.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Olaf (Frozen)', 'https://en.wikipedia.org/wiki/Olaf_(Frozen)', '⛄', false),
  ('stay-puft', 'Stay Puft Marshmallow Man', 'https://upload.wikimedia.org/wikipedia/en/0/01/Mr._Stay-Puft_Marshmallow_Man.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Stay Puft Marshmallow Man', 'https://en.wikipedia.org/wiki/Stay_Puft_Marshmallow_Man', '🍡', false),
  ('slimer', 'Slimer', 'https://upload.wikimedia.org/wikipedia/en/7/7c/Slimer_%28Ghostbusters_1984_film_character%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Slimer', 'https://en.wikipedia.org/wiki/Slimer', '🟢', false),
  ('pennywise', 'Pennywise', 'https://upload.wikimedia.org/wikipedia/en/5/52/Pennywise_Skarsgard_and_Curry.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Pennywise', 'https://en.wikipedia.org/wiki/Pennywise', '🎈', false),
  ('freddy-krueger', 'Freddy Krueger', 'https://upload.wikimedia.org/wikipedia/en/e/eb/Freddy_Krueger_%28Robert_Englund%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Freddy Krueger', 'https://en.wikipedia.org/wiki/Freddy_Krueger', '🔪', false),
  ('jason-voorhees', 'Jason Voorhees', 'https://upload.wikimedia.org/wikipedia/en/f/f7/Jason_Voorhees_%28Ken_Kirzinger%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Jason Voorhees', 'https://en.wikipedia.org/wiki/Jason_Voorhees', '🔪', false),
  ('michael-myers', 'Michael Myers', 'https://upload.wikimedia.org/wikipedia/en/e/e9/MichaelMyers2018.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Michael Myers (Halloween)', 'https://en.wikipedia.org/wiki/Michael_Myers_(Halloween)', '🎃', false),
  ('chucky', 'Chucky', 'https://upload.wikimedia.org/wikipedia/en/3/38/Chucky_Appearance_%28TV_Series%29.jpeg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Chucky (Child''s Play)', 'https://en.wikipedia.org/wiki/Chucky_(Child''s_Play)', '🪆', false),
  ('edward-scissorhands', 'Edward Scissorhands', 'https://en.wikipedia.org/wiki/Special:FilePath/Edwardscissorhands-img01.jpg?width=900', 'Wikipedia — Edward Scissorhands', 'https://en.wikipedia.org/wiki/Edward_Scissorhands', '✂️', true),
  ('gru', 'Gru', 'https://upload.wikimedia.org/wikipedia/en/0/09/Gru_from_DM4.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Gru', 'https://en.wikipedia.org/wiki/Gru', '🌙', false),
  ('shrek', 'Shrek', 'https://upload.wikimedia.org/wikipedia/en/4/4d/Shrek_%28character%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Shrek (character)', 'https://en.wikipedia.org/wiki/Shrek_(character)', '🧅', false),
  ('donkey', 'Donkey', 'https://upload.wikimedia.org/wikipedia/en/6/6c/Donkey_%28Shrek%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Donkey (Shrek)', 'https://en.wikipedia.org/wiki/Donkey_(Shrek)', '🫏', false),
  ('puss-in-boots', 'Puss in Boots', 'https://upload.wikimedia.org/wikipedia/en/8/8a/Puss_in_Boots_from_Shrek.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Puss in Boots (Shrek)', 'https://en.wikipedia.org/wiki/Puss_in_Boots_(Shrek)', '🐱', false),
  ('wall-e', 'WALL-E', 'https://upload.wikimedia.org/wikipedia/en/4/4c/WALL-E_poster.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — WALL-E', 'https://en.wikipedia.org/wiki/WALL-E', '🤖', false),
  ('bumblebee', 'Bumblebee', 'https://upload.wikimedia.org/wikipedia/en/0/08/Bumblebee_IDW.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Bumblebee (Transformers)', 'https://en.wikipedia.org/wiki/Bumblebee_(Transformers)', '🚗', false),
  ('optimus-prime', 'Optimus Prime', 'https://upload.wikimedia.org/wikipedia/en/b/b2/Optimusprime-originaltoy.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Optimus Prime', 'https://en.wikipedia.org/wiki/Optimus_Prime', '🚛', false),
  ('stitch', 'Stitch', 'https://thumb.wikimedia.org/wikipedia/en/thumb/d/d2/Stitch_%28Lilo_%26_Stitch%29.svg/960px-Stitch_%28Lilo_%26_Stitch%29.svg.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Stitch (Lilo & Stitch)', 'https://en.wikipedia.org/wiki/Stitch_(Lilo_%26_Stitch)', '👽', false),
  ('mr-peanut', 'Mr. Peanut', 'https://upload.wikimedia.org/wikipedia/en/6/6e/Mr_peanut.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Mr. Peanut', 'https://en.wikipedia.org/wiki/Mr._Peanut', '🥜', false),
  ('julius-pringles', 'Julius Pringles', 'https://en.wikipedia.org/wiki/Special:FilePath/Cosplay%20of%20Julius%20Pringles%20at%20Made%20in%20Asia%202022%20(52097485594).jpg?width=900', 'Wikipedia — Pringles', 'https://en.wikipedia.org/wiki/Pringles', '🥔', true),
  ('kool-aid-man', 'Kool-Aid Man', 'https://upload.wikimedia.org/wikipedia/en/c/c7/Kool-Aid_Man.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Kool-Aid Man', 'https://en.wikipedia.org/wiki/Kool-Aid_Man', '🥤', false),
  ('tony-the-tiger', 'Tony the Tiger', 'https://en.wikipedia.org/wiki/Special:FilePath/Tony%20the%20Tiger%20(Kellogg''s%20Frosted%20Flakes''%20mascot).jpg?width=900', 'Wikipedia — Tony the Tiger', 'https://en.wikipedia.org/wiki/Tony_the_Tiger', '🐯', true),
  ('waluigi', 'Waluigi', 'https://upload.wikimedia.org/wikipedia/en/c/c1/Waluigi_by_Shigehisa_Nakaue.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Waluigi', 'https://en.wikipedia.org/wiki/Waluigi', '🟣', false),
  ('toad', 'Toad', 'https://upload.wikimedia.org/wikipedia/en/b/b9/Toad_by_Shigehisa_Nakaue.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Toad (Mario)', 'https://en.wikipedia.org/wiki/Toad_(Mario)', '🍄', false),
  ('bowser', 'Bowser', 'https://upload.wikimedia.org/wikipedia/en/d/d1/Bowser_by_Shigehisa_Nakaue.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Bowser', 'https://en.wikipedia.org/wiki/Bowser', '🐢', false),
  ('yoshi', 'Yoshi', 'https://upload.wikimedia.org/wikipedia/en/d/db/Yoshi_%28Nintendo_character%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Yoshi', 'https://en.wikipedia.org/wiki/Yoshi', '🥚', false),
  ('kirby', 'Kirby', 'https://upload.wikimedia.org/wikipedia/en/4/4e/Kirby_Nintendo.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Kirby (character)', 'https://en.wikipedia.org/wiki/Kirby_(character)', '🌸', false),
  ('wario', 'Wario', 'https://upload.wikimedia.org/wikipedia/en/8/81/Wario.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Wario', 'https://en.wikipedia.org/wiki/Wario', '💰', false),
  ('donkey-kong', 'Donkey Kong', 'https://upload.wikimedia.org/wikipedia/en/d/d4/Donkey_Kong_character.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Donkey Kong (character)', 'https://en.wikipedia.org/wiki/Donkey_Kong_(character)', '🦍', false),
  ('princess-peach', 'Princess Peach', 'https://upload.wikimedia.org/wikipedia/en/1/16/Princess_Peach_Stock_Art.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Princess Peach', 'https://en.wikipedia.org/wiki/Princess_Peach', '👑', false),
  ('koopa-troopa', 'Koopa Troopa', 'https://upload.wikimedia.org/wikipedia/en/5/5f/Koopa_Troopa_by_Shigehisa_Nakaue.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Koopa Troopa', 'https://en.wikipedia.org/wiki/Koopa_Troopa', '🐢', false),
  ('tails', 'Tails', 'https://upload.wikimedia.org/wikipedia/en/1/1a/Miles_%22Tails%22_Prower_Sonic_and_All-Stars_Racing_Transformed.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Tails (Sonic the Hedgehog)', 'https://en.wikipedia.org/wiki/Tails_(Sonic_the_Hedgehog)', '🦊', false),
  ('knuckles', 'Knuckles the Echidna', 'https://upload.wikimedia.org/wikipedia/en/0/06/Knuckles_the_Echidna.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Knuckles the Echidna', 'https://en.wikipedia.org/wiki/Knuckles_the_Echidna', '🥊', false),
  ('dr-eggman', 'Doctor Eggman', 'https://upload.wikimedia.org/wikipedia/en/7/72/Doctor_EggmanSDT.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Doctor Eggman', 'https://en.wikipedia.org/wiki/Doctor_Eggman', '🥚', false),
  ('shadow-hedgehog', 'Shadow the Hedgehog', 'https://upload.wikimedia.org/wikipedia/en/4/41/ShadowTheHedgehogSA2.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Shadow the Hedgehog', 'https://en.wikipedia.org/wiki/Shadow_the_Hedgehog', '🖤', false),
  ('psyduck', 'Psyduck', 'https://upload.wikimedia.org/wikipedia/en/2/2d/Pok%C3%A9mon_Psyduck_art.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Psyduck', 'https://en.wikipedia.org/wiki/Psyduck', '🐤', false),
  ('snorlax', 'Snorlax', 'https://upload.wikimedia.org/wikipedia/en/3/3f/Pok%C3%A9mon_Snorlax_art.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Snorlax', 'https://en.wikipedia.org/wiki/Snorlax', '😴', false),
  ('magikarp', 'Magikarp', 'https://en.wikipedia.org/wiki/Special:FilePath/Magikarp%20Realistic.jpg?width=900', 'Wikipedia — Magikarp and Gyarados', 'https://en.wikipedia.org/wiki/Magikarp_and_Gyarados', '🐟', true),
  ('jigglypuff', 'Jigglypuff', 'https://upload.wikimedia.org/wikipedia/en/2/22/Pok%C3%A9mon_Jigglypuff_art.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Jigglypuff', 'https://en.wikipedia.org/wiki/Jigglypuff', '🎤', false),
  ('meowth', 'Meowth', 'https://upload.wikimedia.org/wikipedia/en/9/99/Meowth.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Meowth', 'https://en.wikipedia.org/wiki/Meowth', '🐱', false),
  ('bulbasaur', 'Bulbasaur', 'https://upload.wikimedia.org/wikipedia/en/2/28/Pok%C3%A9mon_Bulbasaur_art.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Bulbasaur', 'https://en.wikipedia.org/wiki/Bulbasaur', '🌱', false),
  ('charmander', 'Charmander', 'https://upload.wikimedia.org/wikipedia/en/5/56/Charmander.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Charmander', 'https://en.wikipedia.org/wiki/Charmander', '🔥', false),
  ('gengar', 'Gengar', 'https://upload.wikimedia.org/wikipedia/en/b/bf/Pok%C3%A9mon_Gengar_art.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Gengar', 'https://en.wikipedia.org/wiki/Gengar', '👻', false),
  ('eevee', 'Eevee', 'https://upload.wikimedia.org/wikipedia/en/a/a9/Pok%C3%A9mon_Eevee_art.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Eevee', 'https://en.wikipedia.org/wiki/Eevee', '🦊', false),
  ('slowpoke', 'Slowpoke', 'https://upload.wikimedia.org/wikipedia/en/4/43/Slowpoke_and_Galarian_Slowpoke.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Slowpoke', 'https://en.wikipedia.org/wiki/Slowpoke', '🩷', false),
  ('steve-minecraft', 'Steve', 'https://upload.wikimedia.org/wikipedia/en/e/e7/Steve_%28Minecraft%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Steve (Minecraft)', 'https://en.wikipedia.org/wiki/Steve_(Minecraft)', '⛏️', false),
  ('among-us', 'Among Us Crewmate', 'https://upload.wikimedia.org/wikipedia/en/9/9a/Among_Us_cover_art.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Among Us', 'https://en.wikipedia.org/wiki/Among_Us', '🔴', false),
  ('pac-man', 'Pac-Man', 'https://upload.wikimedia.org/wikipedia/en/1/16/Pac_flyer.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Pac-Man', 'https://en.wikipedia.org/wiki/Pac-Man', '🟡', false),
  ('lara-croft', 'Lara Croft', 'https://upload.wikimedia.org/wikipedia/en/a/a8/LaraCroftInfobox.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Lara Croft', 'https://en.wikipedia.org/wiki/Lara_Croft', '🏺', false),
  ('kratos', 'Kratos', 'https://upload.wikimedia.org/wikipedia/en/2/2f/Kratos_PS4.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Kratos (God of War)', 'https://en.wikipedia.org/wiki/Kratos_(God_of_War)', '🪓', false),
  ('master-chief', 'Master Chief', 'https://upload.wikimedia.org/wikipedia/en/4/42/Master_chief_halo_infinite.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Master Chief (Halo)', 'https://en.wikipedia.org/wiki/Master_Chief_(Halo)', '🪖', false),
  ('red-angry-bird', 'Red', 'https://upload.wikimedia.org/wikipedia/en/8/8b/Angry_Birds_Toons_logo.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Angry Birds Toons', 'https://en.wikipedia.org/wiki/Angry_Birds_Toons', '🐦', false),
  ('sackboy', 'Sackboy', 'https://upload.wikimedia.org/wikipedia/en/1/19/SackboySony.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Sackboy', 'https://en.wikipedia.org/wiki/Sackboy', '🧵', false),
  ('mr-bean', 'Mr. Bean', 'https://en.wikipedia.org/wiki/Special:FilePath/Atkinson%20Rowan%20crop.jpg?width=900', 'Wikipedia — Mr. Bean', 'https://en.wikipedia.org/wiki/Mr._Bean', '🪑', true),
  ('danny-devito', 'Danny DeVito', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/8/88/Danny_DeVito_cropped_and_edited_for_brightness.jpg/960px-Danny_DeVito_cropped_and_edited_for_brightness.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Danny DeVito', 'https://en.wikipedia.org/wiki/Danny_DeVito', '🎬', true),
  ('nicolas-cage', 'Nicolas Cage', 'https://upload.wikimedia.org/wikipedia/commons/c/c0/Nicolas_Cage_Deauville_2013.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Nicolas Cage', 'https://en.wikipedia.org/wiki/Nicolas_Cage', '🎬', true),
  ('jeff-goldblum', 'Jeff Goldblum', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/3/3d/Jeff_Goldblum_by_Gage_Skidmore_3.jpg/960px-Jeff_Goldblum_by_Gage_Skidmore_3.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Jeff Goldblum', 'https://en.wikipedia.org/wiki/Jeff_Goldblum', '🦖', true),
  ('steve-buscemi', 'Steve Buscemi', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/8/81/SteveBuscemi-byPhilipRomano.jpg/960px-SteveBuscemi-byPhilipRomano.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Steve Buscemi', 'https://en.wikipedia.org/wiki/Steve_Buscemi', '🎬', true),
  ('bill-murray', 'Bill Murray', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b6/Bill_Murray_at_the_2025_Sundance_Film_Festival_2_%28cropped%29.jpg/960px-Bill_Murray_at_the_2025_Sundance_Film_Festival_2_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Bill Murray', 'https://en.wikipedia.org/wiki/Bill_Murray', '🎬', true),
  ('samuel-l-jackson', 'Samuel L. Jackson', 'https://upload.wikimedia.org/wikipedia/commons/f/f7/Samuel_L._Jackson_attending_the_World_premier_of_%22Argylle%22_in_London_%2C_January_2024_%28cropped2%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Samuel L. Jackson', 'https://en.wikipedia.org/wiki/Samuel_L._Jackson', '🎬', true),
  ('arnold', 'Arnold Schwarzenegger', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/e/e3/Arnold_Schwarzenegger_-_Austrian_World_Summit_2026_BHO-2906.jpg/960px-Arnold_Schwarzenegger_-_Austrian_World_Summit_2026_BHO-2906.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Arnold Schwarzenegger', 'https://en.wikipedia.org/wiki/Arnold_Schwarzenegger', '💪', true),
  ('jack-black', 'Jack Black', 'https://upload.wikimedia.org/wikipedia/commons/9/92/TenaciousDO2160623_%2838_of_62%29_Jack_Black.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Jack Black', 'https://en.wikipedia.org/wiki/Jack_Black', '🎸', true),
  ('seth-rogen', 'Seth Rogen', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/6/6f/Seth_Rogen_at_Toronto_International_Film_Festival_2026_-_8.jpg/960px-Seth_Rogen_at_Toronto_International_Film_Festival_2026_-_8.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Seth Rogen', 'https://en.wikipedia.org/wiki/Seth_Rogen', '😂', true),
  ('snoop-dogg', 'Snoop Dogg', 'https://upload.wikimedia.org/wikipedia/commons/f/f0/Snoop_Dogg%2C_WrestleMania_XL_%28cropped%29_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Snoop Dogg', 'https://en.wikipedia.org/wiki/Snoop_Dogg', '🌿', true),
  ('ozzy-osbourne', 'Ozzy Osbourne', 'https://en.wikipedia.org/wiki/Special:FilePath/Ozzy%20Osbourne%20in%201980%20from%20Blizzard%20of%20Ozz%20(cropped%20close-up).jpg?width=900', 'Wikipedia — Ozzy Osbourne', 'https://en.wikipedia.org/wiki/Ozzy_Osbourne', '🦇', true),
  ('elton-john', 'Elton John', 'https://upload.wikimedia.org/wikipedia/commons/6/61/EltonDocBFILFF101024_%284_of_17%29_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Elton John', 'https://en.wikipedia.org/wiki/Elton_John', '🎹', true),
  ('freddie-mercury', 'Freddie Mercury', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/e/ef/Freddie_Mercury_performing_in_New_Haven%2C_CT%2C_November_1977.jpg/960px-Freddie_Mercury_performing_in_New_Haven%2C_CT%2C_November_1977.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Freddie Mercury', 'https://en.wikipedia.org/wiki/Freddie_Mercury', '🎤', true),
  ('bob-marley', 'Bob Marley', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d6/Bob_Marley_circa_1976_%28cropped%29.jpg/960px-Bob_Marley_circa_1976_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Bob Marley', 'https://en.wikipedia.org/wiki/Bob_Marley', '🎵', true),
  ('david-bowie', 'David Bowie', 'https://upload.wikimedia.org/wikipedia/commons/e/e8/David-Bowie_Chicago_2002-08-08_photoby_Adam-Bielawski-cropped.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — David Bowie', 'https://en.wikipedia.org/wiki/David_Bowie', '⚡', true),
  ('einstein', 'Albert Einstein', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/2/28/Albert_Einstein_Head_cleaned.jpg/960px-Albert_Einstein_Head_cleaned.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Albert Einstein', 'https://en.wikipedia.org/wiki/Albert_Einstein', '🧠', true),
  ('tesla', 'Nikola Tesla', 'https://upload.wikimedia.org/wikipedia/commons/7/79/Tesla_circa_1890.jpeg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Nikola Tesla', 'https://en.wikipedia.org/wiki/Nikola_Tesla', '⚡', true),
  ('marie-curie', 'Marie Curie', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c8/Marie_Curie_c._1920s.jpg/960px-Marie_Curie_c._1920s.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Marie Curie', 'https://en.wikipedia.org/wiki/Marie_Curie', '⚗️', true),
  ('frida-kahlo', 'Frida Kahlo', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/0/06/Frida_Kahlo%2C_by_Guillermo_Kahlo.jpg/960px-Frida_Kahlo%2C_by_Guillermo_Kahlo.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Frida Kahlo', 'https://en.wikipedia.org/wiki/Frida_Kahlo', '🌺', true),
  ('van-gogh', 'Vincent van Gogh', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4c/Vincent_van_Gogh_-_Self-Portrait_-_Google_Art_Project_%28454045%29.jpg/960px-Vincent_van_Gogh_-_Self-Portrait_-_Google_Art_Project_%28454045%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Vincent van Gogh', 'https://en.wikipedia.org/wiki/Vincent_van_Gogh', '🌻', true),
  ('salvador-dali', 'Salvador Dalí', 'https://en.wikipedia.org/wiki/Special:FilePath/Salvador%20Dali%20NYWTS.jpg?width=900', 'Wikipedia — Salvador Dalí', 'https://en.wikipedia.org/wiki/Salvador_Dal%C3%AD', '🕰️', true),
  ('chaplin', 'Charlie Chaplin', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/8/82/Charlie_Chaplin_portrait_Getty_1739411952.jpg/960px-Charlie_Chaplin_portrait_Getty_1739411952.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Charlie Chaplin', 'https://en.wikipedia.org/wiki/Charlie_Chaplin', '🎩', true),
  ('napoleon', 'Napoleon', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/5/50/Jacques-Louis_David_-_The_Emperor_Napoleon_in_His_Study_at_the_Tuileries_-_Google_Art_Project.jpg/960px-Jacques-Louis_David_-_The_Emperor_Napoleon_in_His_Study_at_the_Tuileries_-_Google_Art_Project.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Napoleon', 'https://en.wikipedia.org/wiki/Napoleon', '🎩', true),
  ('cleopatra', 'Cleopatra', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/3/3e/Kleopatra-VII.-Altes-Museum-Berlin1.jpg/960px-Kleopatra-VII.-Altes-Museum-Berlin1.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Cleopatra', 'https://en.wikipedia.org/wiki/Cleopatra', '👑', true),
  ('queen-elizabeth', 'Queen Elizabeth II', 'https://upload.wikimedia.org/wikipedia/commons/1/11/Queen_Elizabeth_II_official_portrait_for_1959_tour_%28retouched%29_%28cropped%29_%283-to-4_aspect_ratio%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Elizabeth II', 'https://en.wikipedia.org/wiki/Elizabeth_II', '👑', true),
  ('obama', 'Barack Obama', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/8/8d/President_Barack_Obama.jpg/960px-President_Barack_Obama.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Barack Obama', 'https://en.wikipedia.org/wiki/Barack_Obama', '🇺🇸', true),
  ('trump', 'Donald Trump', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/1/16/Official_Presidential_Portrait_of_President_Donald_J._Trump_%282025%29.jpg/960px-Official_Presidential_Portrait_of_President_Donald_J._Trump_%282025%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Donald Trump', 'https://en.wikipedia.org/wiki/Donald_Trump', '🇺🇸', true),
  ('elon-musk', 'Elon Musk', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/5/5e/Elon_Musk_-_54820081119_%28cropped%29.jpg/960px-Elon_Musk_-_54820081119_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Elon Musk', 'https://en.wikipedia.org/wiki/Elon_Musk', '🚀', true),
  ('steve-jobs', 'Steve Jobs', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/5/51/Steve_Jobs_Headshot_2010_%28cropped_4%29.jpg/960px-Steve_Jobs_Headshot_2010_%28cropped_4%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Steve Jobs', 'https://en.wikipedia.org/wiki/Steve_Jobs', '🍎', true),
  ('bill-gates', 'Bill Gates', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/d/d9/Bill_Gates_at_the_European_Commission_-_P067383-987995_%28cropped%29_5.jpg/960px-Bill_Gates_at_the_European_Commission_-_P067383-987995_%28cropped%29_5.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Bill Gates', 'https://en.wikipedia.org/wiki/Bill_Gates', '🪟', true),
  ('cristiano-ronaldo', 'Cristiano Ronaldo', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/2/26/Cristiano_Ronaldo_Croatia_v_Portugal_2_July_2026-075_%28cropped%29.jpg/960px-Cristiano_Ronaldo_Croatia_v_Portugal_2_July_2026-075_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Cristiano Ronaldo', 'https://en.wikipedia.org/wiki/Cristiano_Ronaldo', '⚽', true),
  ('messi', 'Lionel Messi', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c8/Leo_Messi_Argentina_v_Egypt_7_July_2026-1.jpg/960px-Leo_Messi_Argentina_v_Egypt_7_July_2026-1.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Lionel Messi', 'https://en.wikipedia.org/wiki/Lionel_Messi', '⚽', true),
  ('maradona', 'Diego Maradona', 'https://upload.wikimedia.org/wikipedia/commons/4/48/Argentina_celebrando_copa_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Diego Maradona', 'https://en.wikipedia.org/wiki/Diego_Maradona', '⚽', true),
  ('mike-tyson', 'Mike Tyson', 'https://upload.wikimedia.org/wikipedia/commons/e/ee/Mike_Tyson_Photo_Op_GalaxyCon_Austin_2023.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Mike Tyson', 'https://en.wikipedia.org/wiki/Mike_Tyson', '🥊', true),
  ('bruce-lee', 'Bruce Lee', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/1/1e/Bruce_Lee_as_Chen_Zhen_%284x5_cropped%29.jpg/960px-Bruce_Lee_as_Chen_Zhen_%284x5_cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Bruce Lee', 'https://en.wikipedia.org/wiki/Bruce_Lee', '🥋', true),
  ('jackie-chan', 'Jackie Chan', 'https://en.wikipedia.org/wiki/Special:FilePath/Jackie%20Chan%20Berlinale%202010.jpg?width=900', 'Wikipedia — Jackie Chan', 'https://en.wikipedia.org/wiki/Jackie_Chan', '🤸', true),
  ('mrbeast', 'MrBeast', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/4/47/MrBeast_in_2026_%28cropped_4%29.png/960px-MrBeast_in_2026_%28cropped_4%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — MrBeast', 'https://en.wikipedia.org/wiki/MrBeast', '💵', true),
  ('taylor-swift', 'Taylor Swift', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b1/Taylor_Swift_at_the_2023_MTV_Video_Music_Awards_%283%29.png/960px-Taylor_Swift_at_the_2023_MTV_Video_Music_Awards_%283%29.png?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Taylor Swift', 'https://en.wikipedia.org/wiki/Taylor_Swift', '🎶', true),
  ('beyonce', 'Beyoncé', 'https://upload.wikimedia.org/wikipedia/commons/b/b7/Beyonc%C3%A9_-_Tottenham_Hotspur_Stadium_-_1st_June_2023_%2810_of_118%29_%2852946364598%29_%28best_crop%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Beyoncé', 'https://en.wikipedia.org/wiki/Beyonc%C3%A9', '👑', true),
  ('lady-gaga', 'Lady Gaga', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/0/0e/Lady_Gaga_at_Joe_Biden%27s_inauguration_%28cropped_5%29.jpg/960px-Lady_Gaga_at_Joe_Biden%27s_inauguration_%28cropped_5%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Lady Gaga', 'https://en.wikipedia.org/wiki/Lady_Gaga', '🎤', true),
  ('billie-eilish', 'Billie Eilish', 'https://upload.wikimedia.org/wikipedia/commons/c/c7/BillieEilishO2140725-39_-_54665577407_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Billie Eilish', 'https://en.wikipedia.org/wiki/Billie_Eilish', '💚', true),
  ('bad-bunny', 'Bad Bunny', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b1/Bad_Bunny_2019_by_Glenn_Francis_%28cropped%29.jpg/960px-Bad_Bunny_2019_by_Glenn_Francis_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Bad Bunny', 'https://en.wikipedia.org/wiki/Bad_Bunny', '🐰', true),
  ('shakira', 'Shakira', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b8/2023-11-16_Gala_de_los_Latin_Grammy%2C_03_%28cropped%2902.jpg/960px-2023-11-16_Gala_de_los_Latin_Grammy%2C_03_%28cropped%2902.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Shakira', 'https://en.wikipedia.org/wiki/Shakira', '🕺', true),
  ('bob-ross', 'Bob Ross', 'https://upload.wikimedia.org/wikipedia/commons/8/87/Bob_Ross_publicity_photo_%28c._1982%29_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Bob Ross', 'https://en.wikipedia.org/wiki/Bob_Ross', '🎨', true),
  ('gordon-ramsay', 'Gordon Ramsay', 'https://upload.wikimedia.org/wikipedia/commons/9/96/Gordon_Ramsay_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Gordon Ramsay', 'https://en.wikipedia.org/wiki/Gordon_Ramsay', '👨‍🍳', true),
  ('jamie-oliver', 'Jamie Oliver', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/3/38/Jamie_Oliver_%28cropped%29.jpg/960px-Jamie_Oliver_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Jamie Oliver', 'https://en.wikipedia.org/wiki/Jamie_Oliver', '🥗', true),
  ('keanu-reeves', 'Keanu Reeves', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b4/Keanu_Reeves_at_TIFF_2025_02_%28Cropped%29.jpg/960px-Keanu_Reeves_at_TIFF_2025_02_%28Cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Keanu Reeves', 'https://en.wikipedia.org/wiki/Keanu_Reeves', '🕶️', true),
  ('the-rock', 'Dwayne Johnson', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/7/7e/Dwayne_Johnson-1764_%284x5_cropped_with_moderate_headroom%29.jpg/960px-Dwayne_Johnson-1764_%284x5_cropped_with_moderate_headroom%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Dwayne Johnson', 'https://en.wikipedia.org/wiki/Dwayne_Johnson', '🪨', true),
  ('pedro-pascal', 'Pedro Pascal', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/6/6d/Pedro_Pascal_at_the_2025_Cannes_Film_Festival_04.jpg/960px-Pedro_Pascal_at_the_2025_Cannes_Film_Festival_04.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Pedro Pascal', 'https://en.wikipedia.org/wiki/Pedro_Pascal', '🍄', true),
  ('ryan-reynolds', 'Ryan Reynolds', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/1/14/Deadpool_2_Japan_Premiere_Red_Carpet_Ryan_Reynolds_%28cropped%29.jpg/960px-Deadpool_2_Japan_Premiere_Red_Carpet_Ryan_Reynolds_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Ryan Reynolds', 'https://en.wikipedia.org/wiki/Ryan_Reynolds', '🎭', true),
  ('morgan-freeman', 'Morgan Freeman', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/4/42/Morgan_Freeman_at_The_Pentagon_on_2_August_2023_-_230802-D-PM193-3363_%28cropped%29.jpg/960px-Morgan_Freeman_at_The_Pentagon_on_2_August_2023_-_230802-D-PM193-3363_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Morgan Freeman', 'https://en.wikipedia.org/wiki/Morgan_Freeman', '🎙️', true),
  ('di-caprio', 'Leonardo DiCaprio', 'https://upload.wikimedia.org/wikipedia/commons/2/2d/LeoPTABFI191125-28_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Leonardo DiCaprio', 'https://en.wikipedia.org/wiki/Leonardo_DiCaprio', '🚢', true),
  ('brad-pitt', 'Brad Pitt', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/9/90/Brad_Pitt-69858.jpg/960px-Brad_Pitt-69858.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Brad Pitt', 'https://en.wikipedia.org/wiki/Brad_Pitt', '🎬', true),
  ('michael-jackson', 'Michael Jackson', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/b/b9/Michael_Jackson_1983_%283x4_cropped%29_%28contrast%29.jpg/960px-Michael_Jackson_1983_%283x4_cropped%29_%28contrast%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Michael Jackson', 'https://en.wikipedia.org/wiki/Michael_Jackson', '🕴️', true),
  ('elvis', 'Elvis Presley', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/9/99/Elvis_Presley_promoting_Jailhouse_Rock.jpg/960px-Elvis_Presley_promoting_Jailhouse_Rock.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Elvis Presley', 'https://en.wikipedia.org/wiki/Elvis_Presley', '🎸', true),
  ('marilyn-monroe', 'Marilyn Monroe', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/4/4e/Monroecirca1953.jpg/960px-Monroecirca1953.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Marilyn Monroe', 'https://en.wikipedia.org/wiki/Marilyn_Monroe', '💋', true),
  ('audrey-hepburn', 'Audrey Hepburn', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/7/74/AudreyKHepburn.jpg/960px-AudreyKHepburn.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Audrey Hepburn', 'https://en.wikipedia.org/wiki/Audrey_Hepburn', '🎀', true),
  ('mr-t', 'Mr. T', 'https://upload.wikimedia.org/wikipedia/commons/4/43/Mr_T_WWE_Hall_of_Fame_2014_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Mr. T', 'https://en.wikipedia.org/wiki/Mr._T', '⛓️', true),
  ('stallone', 'Sylvester Stallone', 'https://upload.wikimedia.org/wikipedia/commons/1/12/P20251206DT-0472_%283x4_cropped_on_Stallone_with_moderate_headroom%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Sylvester Stallone', 'https://en.wikipedia.org/wiki/Sylvester_Stallone', '🥊', true),
  ('danny-trejo', 'Danny Trejo', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/1/12/Danny_Trejo_Photo_Op_GalaxyCon_Oklahoma_City_2025.jpg/960px-Danny_Trejo_Photo_Op_GalaxyCon_Oklahoma_City_2025.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Danny Trejo', 'https://en.wikipedia.org/wiki/Danny_Trejo', '🔪', true),
  ('stephen-hawking', 'Stephen Hawking', 'https://upload.wikimedia.org/wikipedia/commons/e/eb/Stephen_Hawking.StarChild.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail_unscaled', 'Wikipedia — Stephen Hawking', 'https://en.wikipedia.org/wiki/Stephen_Hawking', '🌌', true),
  ('che-guevara', 'Che Guevara', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/8/80/Che_Guevara_-_Guerrillero_Heroico_by_Alberto_Korda.jpg/960px-Che_Guevara_-_Guerrillero_Heroico_by_Alberto_Korda.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Che Guevara', 'https://en.wikipedia.org/wiki/Che_Guevara', '🎖️', true),
  ('mozart', 'Wolfgang Amadeus Mozart', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ad/The_Mozart_Family_-_Wolfgang_Amadeus_Mozart_headshot.jpg/960px-The_Mozart_Family_-_Wolfgang_Amadeus_Mozart_headshot.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Wolfgang Amadeus Mozart', 'https://en.wikipedia.org/wiki/Wolfgang_Amadeus_Mozart', '🎼', true),
  ('david-attenborough', 'David Attenborough', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/6/69/David_Attenborough_in_2025.jpg/960px-David_Attenborough_in_2025.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — David Attenborough', 'https://en.wikipedia.org/wiki/David_Attenborough', '🦜', true),
  ('stephen-king', 'Stephen King', 'https://thumb.wikimedia.org/wikipedia/commons/thumb/2/24/Stephen_King_at_the_2024_Toronto_International_Film_Festival_2_%28cropped%29.jpg/960px-Stephen_King_at_the_2024_Toronto_International_Film_Festival_2_%28cropped%29.jpg?utm_source=en.wikipedia.org&utm_campaign=api&utm_content=thumbnail', 'Wikipedia — Stephen King', 'https://en.wikipedia.org/wiki/Stephen_King', '📚', true);

insert into public.pairings (category, clue, char_a, char_b) values
  ('Bald', 'Both of your characters are completely bald.', 'kratos', 'dr-eggman'),
  ('Bald', 'Both of your characters are bald and very strong.', 'thanos', 'the-rock'),
  ('Bald', 'Both of your characters are short and bald.', 'danny-devito', 'gru'),
  ('Facial hair', 'Both of your characters have an enormous moustache.', 'salvador-dali', 'waluigi'),
  ('Facial hair', 'Both of your characters have a famous moustache.', 'dr-eggman', 'freddie-mercury'),
  ('Facial hair', 'Both of your characters have a big beard.', 'gandalf', 'hagrid'),
  ('Green', 'Both of your characters are green and grumpy.', 'grinch', 'bowser'),
  ('Green', 'Both of your characters are big and green.', 'shrek', 'hulk'),
  ('Green', 'Both of your characters are tiny and green.', 'yoda', 'grogu'),
  ('Green', 'Both of your characters are green and have a big grin.', 'slimer', 'grinch'),
  ('Aliens', 'Both of your characters are giant alien warlords.', 'thanos', 'jabba'),
  ('Tiny', 'Both of your characters are extremely small and carry a weapon.', 'puss-in-boots', 'yoda'),
  ('Tiny', 'Both of your characters are extremely small and blue.', 'mr-meeseeks', 'stitch'),
  ('Tiny', 'Both of your characters are extremely small and evil.', 'stewie-griffin', 'chucky'),
  ('Round', 'Both of your characters are small, round and always hungry.', 'pac-man', 'kirby'),
  ('Round', 'Both of your characters are round and pink.', 'jigglypuff', 'kirby'),
  ('Lazy', 'Both of your characters are extremely lazy.', 'snorlax', 'slowpoke'),
  ('Round', 'Both of your characters are round, floating and always grinning.', 'slimer', 'gengar'),
  ('Robots', 'Both of your characters are robots.', 'bender', 'wall-e'),
  ('Robots', 'Both of your characters are famous movie robots.', 'wall-e', 'optimus-prime'),
  ('Space', 'Both of your characters travel through space.', 'master-chief', 'among-us'),
  ('Masks', 'Both of your characters wear a mask and never show their face.', 'master-chief', 'darth-vader'),
  ('Masks', 'Both of your characters wear a mask and carry a weapon.', 'jason-voorhees', 'bane'),
  ('Masks', 'Both of your characters are masked Marvel heroes.', 'deadpool', 'wolverine'),
  ('Clowns', 'Both of your characters are famous clowns.', 'krusty-the-clown', 'pennywise'),
  ('Hair', 'Both of your characters have wild, colourful hair.', 'krusty-the-clown', 'animal-muppet'),
  ('Horror', 'Both of your characters are terrifying movie killers.', 'michael-myers', 'freddy-krueger'),
  ('Horror', 'Both of your characters have a habit of dying and coming back.', 'deadpool', 'kenny'),
  ('Red hair', 'Both of your characters have bright red hair.', 'sideshow-bob', 'chucky'),
  ('Red hair', 'Both of your characters have very famous red hair.', 'van-gogh', 'mystique'),
  ('Capes', 'Both of your characters wear a purple cape.', 'count-von-count', 'magneto'),
  ('Wizards', 'Both of your characters are wizards with a long beard.', 'gandalf', 'dumbledore'),
  ('Hats', 'Both of your characters wear a tall pointy hat.', 'gandalf', 'mcgonagall'),
  ('Hats', 'Both of your characters wear a very recognizable hat.', 'napoleon', 'che-guevara'),
  ('Glasses', 'Both of your characters wear glasses.', 'milhouse', 'jeff-goldblum'),
  ('Glasses', 'Both of your characters are famous for wearing glasses.', 'dumbledore', 'elton-john'),
  ('Business', 'Both of your characters are famous tech billionaires.', 'steve-jobs', 'bill-gates'),
  ('Science', 'Both of your characters are genius scientists with wild hair.', 'einstein', 'rick-sanchez'),
  ('Science', 'Both of your characters are famous scientists.', 'marie-curie', 'tesla'),
  ('Science', 'Both of your characters are doctors, but not very good ones.', 'zoidberg', 'dr-eggman'),
  ('Art', 'Both of your characters are famous painters.', 'van-gogh', 'bob-ross'),
  ('Art', 'Both of your characters are painters with a very distinctive face.', 'frida-kahlo', 'salvador-dali'),
  ('Hair', 'Both of your characters have enormous, iconic hair.', 'bob-ross', 'mr-t'),
  ('Music', 'Both of your characters are very chill musicians.', 'bob-marley', 'snoop-dogg'),
  ('Face', 'Both of your characters are famous for their eyebrows.', 'frida-kahlo', 'the-rock'),
  ('Voice', 'Both of your characters have an iconic deep voice.', 'morgan-freeman', 'darth-vader'),
  ('Silent', 'Both of your characters never speak.', 'mr-bean', 'chaplin'),
  ('British', 'Both of your characters are British icons.', 'mr-bean', 'queen-elizabeth'),
  ('Mascots', 'Both of your characters are famous food mascots.', 'mr-peanut', 'julius-pringles'),
  ('Red', 'Both of your characters are red, round and very loud.', 'kool-aid-man', 'red-angry-bird'),
  ('Cats', 'Both of your characters are famous cats.', 'puss-in-boots', 'meowth'),
  ('Cats', 'Both of your characters are cat-themed and wear boots.', 'catwoman', 'puss-in-boots'),
  ('Animals', 'Both of your characters are talking animals who are sidekicks.', 'donkey', 'brian-griffin'),
  ('Animals', 'Both of your characters are yellow talking animals.', 'psyduck', 'meowth'),
  ('Furry', 'Both of your characters are blue and furry.', 'cookie-monster', 'stitch'),
  ('Furry', 'Both of your characters are friendly monsters from the same TV show.', 'grover', 'cookie-monster'),
  ('Games', 'Both of your characters are small animals from video games.', 'psyduck', 'bulbasaur'),
  ('Games', 'Both of your characters are cute video game reptiles.', 'yoshi', 'charmander'),
  ('Games', 'Both of your characters are video game turtles.', 'bowser', 'koopa-troopa'),
  ('Games', 'Both of your characters are villains from Nintendo games.', 'wario', 'bowser'),
  ('Purple', 'Both of your characters wear purple.', 'waluigi', 'gengar'),
  ('Plants', 'Both of your characters are covered in plants.', 'poison-ivy', 'groot'),
  ('Mutants', 'Both of your characters are mutants.', 'wolverine', 'mystique'),
  ('Red', 'Both of your characters are red and extremely strong.', 'kool-aid-man', 'knuckles'),
  ('Heroes', 'Both of your characters wear a cape.', 'doctor-strange', 'darth-vader'),
  ('Business', 'Both of your characters are rich businessmen.', 'elon-musk', 'bill-gates'),
  ('Politics', 'Both of your characters are US presidents.', 'obama', 'trump'),
  ('Royalty', 'Both of your characters were queens.', 'cleopatra', 'queen-elizabeth'),
  ('Royalty', 'Both of your characters wear a crown.', 'princess-peach', 'cleopatra'),
  ('Chefs', 'Both of your characters are famous chefs.', 'gordon-ramsay', 'jamie-oliver'),
  ('Sports', 'Both of your characters are football legends.', 'messi', 'cristiano-ronaldo'),
  ('Sports', 'Both of your characters are Argentine legends.', 'messi', 'maradona'),
  ('Action', 'Both of your characters are extremely muscular action stars.', 'arnold', 'the-rock'),
  ('Action', 'Both of your characters are famous for fighting.', 'mike-tyson', 'mr-t'),
  ('Action', 'Both of your characters are legendary martial artists.', 'bruce-lee', 'jackie-chan'),
  ('Music', 'Both of your characters are rock legends.', 'ozzy-osbourne', 'freddie-mercury'),
  ('Music', 'Both of your characters are pop stars who reinvented their look.', 'lady-gaga', 'david-bowie'),
  ('Music', 'Both of your characters are singers with incredible hair.', 'shakira', 'beyonce'),
  ('Music', 'Both of your characters are rappers who love sunglasses.', 'snoop-dogg', 'bad-bunny'),
  ('Music', 'Both of your characters are music legends with a signature look.', 'michael-jackson', 'elvis'),
  ('Comedy', 'Both of your characters have beards and are very funny.', 'jack-black', 'seth-rogen'),
  ('Chill', 'Both of your characters are known for being incredibly calm.', 'bob-ross', 'keanu-reeves'),
  ('Grumpy', 'Both of your characters are grumpy and old.', 'moe-szyslak', 'groundskeeper-willie'),
  ('Beer', 'Both of your characters love beer.', 'barney-gumble', 'bender'),
  ('Babies', 'Both of your characters are famous babies.', 'stewie-griffin', 'grogu'),
  ('Kids', 'Both of your characters are little kids who always wear the same thing.', 'cartman', 'kenny'),
  ('Wise', 'Both of your characters are old, wise and very powerful.', 'gandalf', 'yoda'),
  ('Magic', 'Both of your characters have a beard and use magic powers.', 'obi-wan', 'doctor-strange'),
  ('Big', 'Both of your characters are gigantic.', 'donkey-kong', 'stay-puft'),
  ('Big', 'Both of your characters are very tall and hairy.', 'chewbacca', 'hagrid'),
  ('Blue', 'Both of your characters are blue and always wear red.', 'thomas-tank', 'grover'),
  ('Hats', 'Both of your characters always wear a hat.', 'toad', 'cartman'),
  ('Yellow', 'Both of your characters are yellow.', 'pac-man', 'psyduck'),
  ('Nice', 'Both of your characters are extremely nice and a bit naive.', 'ned-flanders', 'butters'),
  ('Servants', 'Both of your characters work for a very rich man.', 'alfred', 'smithers'),
  ('Red', 'Both of your characters are red and black.', 'darth-maul', 'shadow-hedgehog'),
  ('Comic', 'Both of your characters are Batman villains.', 'the-riddler', 'two-face'),
  ('Scary', 'Both of your characters wear a mask and love to scare people.', 'scarecrow', 'jason-voorhees'),
  ('Puppets', 'Both of your characters are Muppets.', 'bert-ernie', 'cookie-monster'),
  ('British', 'Both of your characters are iconic British children''s TV characters.', 'peppa-pig', 'thomas-tank'),
  ('Scary', 'Both of your characters have blades where their hands should be.', 'edward-scissorhands', 'freddy-krueger'),
  ('Robots', 'Both of your characters are Transformers.', 'optimus-prime', 'bumblebee'),
  ('Games', 'Both of your characters are Sonic''s animal friends.', 'tails', 'knuckles'),
  ('Games', 'Both of your characters are water Pokémon.', 'magikarp', 'psyduck'),
  ('Games', 'Both of your characters are cute quadruped Pokémon.', 'eevee', 'slowpoke'),
  ('Games', 'Both of your characters are small, round and cute video game heroes.', 'sackboy', 'kirby'),
  ('Games', 'Both of your characters are video game characters who explore and collect things.', 'steve-minecraft', 'lara-croft'),
  ('Comedy', 'Both of your characters are famous for screaming in movies.', 'nicolas-cage', 'samuel-l-jackson'),
  ('Comedy', 'Both of your characters are famous for their very deadpan faces.', 'steve-buscemi', 'bill-murray'),
  ('Business', 'Both of your characters are extremely rich.', 'mrbeast', 'elon-musk'),
  ('Music', 'Both of your characters are among the biggest pop stars alive.', 'taylor-swift', 'beyonce'),
  ('Beer', 'Both of your characters are fat guys who love beer.', 'peter-griffin', 'barney-gumble'),
  ('Cartoon', 'Both of your characters are from the same cartoon town.', 'quagmire', 'brian-griffin'),
  ('Space', 'Both of your characters are members of the same space crew.', 'rocket-raccoon', 'groot'),
  ('Furry', 'Both of your characters are furry monsters who are always hungry.', 'animal-muppet', 'cookie-monster'),
  ('Facial hair', 'Both of your characters are tough guys with a moustache.', 'chief-wiggum', 'danny-trejo'),
  ('Kids', 'Both of your characters are children.', 'wendy-testaburger', 'butters'),
  ('Music', 'Both of your characters are young pop stars.', 'billie-eilish', 'bad-bunny'),
  ('Action', 'Both of your characters are action stars with a beard.', 'pedro-pascal', 'keanu-reeves'),
  ('Meta', 'Both of your characters are actually the same person.', 'ryan-reynolds', 'deadpool'),
  ('Looks', 'Both of your characters are famous for being handsome.', 'di-caprio', 'brad-pitt'),
  ('Cinema', 'Both of your characters are iconic Hollywood actresses.', 'marilyn-monroe', 'audrey-hepburn'),
  ('Action', 'Both of your characters are 1980s action movie legends.', 'stallone', 'arnold'),
  ('Science', 'Both of your characters are the most famous scientists in history.', 'stephen-hawking', 'einstein'),
  ('Music', 'Both of your characters are musical geniuses.', 'mozart', 'michael-jackson'),
  ('Voice', 'Both of your characters are famous for their voices.', 'david-attenborough', 'morgan-freeman'),
  ('Horror', 'Both of your characters are horror icons.', 'stephen-king', 'pennywise'),
  ('Space', 'Both of your characters work on the same spaceship.', 'turanga-leela', 'zoidberg'),
  ('Clothing', 'Both of your characters wear long robes.', 'snape', 'obi-wan'),
  ('Soft', 'Both of your characters are white and soft.', 'olaf', 'stay-puft'),
  ('Mascots', 'Both of your characters are cheerful mascots who love food.', 'tony-the-tiger', 'mr-peanut');
