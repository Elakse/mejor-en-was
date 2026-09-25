-- Apply to an existing Supabase project before using live video.
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
