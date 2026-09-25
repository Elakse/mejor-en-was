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
