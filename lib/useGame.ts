"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ensureSession,
  friendlyError,
  getSupabase,
  isSupabaseConfigured,
} from "@/lib/supabase";
import { rememberName, storedName } from "@/lib/names";
import {
  ROUND_SECONDS,
  type Assignment,
  type Character,
  type RoomRef,
  type Snapshot,
} from "@/lib/types";

export type Phase = "booting" | "unconfigured" | "home" | "game";

export interface GameApi {
  phase: Phase;
  setupError: string | null;
  error: string | null;
  busy: boolean;
  code: string | null;
  myName: string;
  setMyName: (name: string) => void;
  autoJoinCode: string | null;
  snapshot: Snapshot | null;
  me: Snapshot["players"][number] | null;
  partner: Snapshot["players"][number] | null;
  myCharacter: Character | null;
  partnerCharacter: Character | null;
  partnerOnline: boolean;
  connected: boolean;
  now: number;
  remainingMs: number | null;
  createGame: () => Promise<void>;
  joinGame: (code: string) => Promise<void>;
  leaveGame: () => Promise<void>;
  toggleReady: () => Promise<void>;
  toggleRevealReady: (ready: boolean) => Promise<void>;
  nextRound: () => Promise<void>;
  skipRound: () => Promise<void>;
  playAgain: () => Promise<void>;
  toggleTimer: () => Promise<void>;
  dismissError: () => void;
}

export function useGame(): GameApi {
  const [phase, setPhase] = useState<Phase>(() =>
    isSupabaseConfigured ? "booting" : "unconfigured",
  );
  const [setupError, setSetupError] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [myName, setMyNameState] = useState("");
  const [autoJoinCode, setAutoJoinCode] = useState<string | null>(null);
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [connected, setConnected] = useState(false);
  const [seat, setSeat] = useState<number | null>(null);
  const [code, setCode] = useState<string | null>(null);
  const [offset, setOffset] = useState(0);
  const [now, setNow] = useState(0);

  const gameIdRef = useRef<string | null>(null);
  const refreshGuard = useRef<Promise<void> | null>(null);
  const debounceRef = useRef<number | null>(null);
  const seatRef = useRef<number | null>(null);

  useEffect(() => {
    seatRef.current = seat;
  }, [seat]);

  const persistRoom = useCallback((room: RoomRef | null) => {
    if (typeof window === "undefined") return;
    const url = new URL(window.location.href);
    if (room) url.searchParams.set("r", room.code);
    else url.searchParams.delete("r");
    window.history.replaceState(null, "", url.toString());
  }, []);

  const resetToHome = useCallback(() => {
    gameIdRef.current = null;
    setSnapshot(null);
    setSeat(null);
    setCode(null);
    setPhase("home");
    persistRoom(null);
  }, [persistRoom]);

  const refresh = useCallback(async () => {
    const id = gameIdRef.current;
    if (!id) return;
    if (refreshGuard.current) return refreshGuard.current;
    const task = (async () => {
      const supabase = getSupabase();
      const { data, error: rpcError } = await supabase.rpc("get_state", {
        p_game_id: id,
      });
      if (rpcError) {
        setError(friendlyError(rpcError.message));
        return;
      }
      const next = data as Snapshot | null;
      if (!next || !next.game) {
        resetToHome();
        return;
      }
      setSnapshot(next);
      setOffset(next.serverNow - Date.now());
    })();
    refreshGuard.current = task;
    try {
      await task;
    } finally {
      refreshGuard.current = null;
    }
  }, [resetToHome]);

  const scheduleRefresh = useCallback(() => {
    if (typeof window === "undefined") {
      void refresh();
      return;
    }
    if (debounceRef.current) window.clearTimeout(debounceRef.current);
    debounceRef.current = window.setTimeout(() => void refresh(), 120);
  }, [refresh]);

  const enterRoom = useCallback(
    (room: RoomRef) => {
      gameIdRef.current = room.game_id;
      setSeat(room.seat);
      setCode(room.code);
      setPhase("game");
      persistRoom(room);
      void refresh();
    },
    [persistRoom, refresh],
  );

  const bootstrap = useCallback(async () => {
    if (!isSupabaseConfigured) {
      return;
    }
    try {
      await ensureSession();
    } catch (e) {
      setSetupError(e instanceof Error ? e.message : String(e));
      setPhase("unconfigured");
      return;
    }

    setMyNameState(storedName());

    const params = new URLSearchParams(window.location.search);
    const invite = (params.get("r") ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    setAutoJoinCode(invite.length === 4 ? invite : null);

    const supabase = getSupabase();
    const { data } = await supabase.rpc("find_my_game");
    const room = data as RoomRef | null;
    if (room?.game_id) {
      enterRoom(room);
      return;
    }
    setPhase("home");
  }, [enterRoom]);

  useEffect(() => {
    const kick = window.setTimeout(() => void bootstrap(), 0);
    return () => window.clearTimeout(kick);
  }, [bootstrap]);

  const active = phase === "game" && Boolean(snapshot);

  useEffect(() => {
    if (!active) return;
    const supabase = getSupabase();
    const id = gameIdRef.current;
    if (!id) return;

    const channel = supabase
      .channel(`room:${id}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "games", filter: `id=eq.${id}` },
        scheduleRefresh,
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "players", filter: `game_id=eq.${id}` },
        scheduleRefresh,
      )
      .subscribe((status) => setConnected(status === "SUBSCRIBED"));

    const poll = window.setInterval(() => void refresh(), 2500);
    const beat = window.setInterval(() => {
      void getSupabase().rpc("heartbeat", { p_game_id: id });
    }, 20000);
    void getSupabase().rpc("heartbeat", { p_game_id: id });

    const onVisible = () => {
      if (document.visibilityState === "visible") void refresh();
    };
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);

    return () => {
      window.clearInterval(poll);
      window.clearInterval(beat);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
      void supabase.removeChannel(channel);
      setConnected(false);
    };
  }, [active, refresh, scheduleRefresh]);

  useEffect(() => {
    if (!active) return;
    const tick = () => setNow(Date.now());
    const interval = window.setInterval(tick, 500);
    const kick = window.setTimeout(tick, 0);
    return () => {
      window.clearInterval(interval);
      window.clearTimeout(kick);
    };
  }, [active]);

  const run = useCallback(
    async (fn: () => Promise<void>) => {
      setBusy(true);
      setError(null);
      try {
        await fn();
        await refresh();
      } catch (e) {
        setError(friendlyError(e instanceof Error ? e.message : String(e)));
      } finally {
        setBusy(false);
      }
    },
    [refresh],
  );

  const createGame = useCallback(
    () =>
      run(async () => {
        rememberName(myName);
        const { data, error: rpcError } = await getSupabase().rpc("create_game", {
          p_name: myName,
        });
        if (rpcError) throw new Error(rpcError.message);
        const room = data as RoomRef;
        gameIdRef.current = room.game_id;
        setSeat(room.seat);
        setCode(room.code);
        setPhase("game");
        persistRoom(room);
      }),
    [myName, persistRoom, run],
  );

  const joinGame = useCallback(
    (rawCode: string) =>
      run(async () => {
        rememberName(myName);
        const { data, error: rpcError } = await getSupabase().rpc("join_game", {
          p_code: rawCode.trim().toUpperCase(),
          p_name: myName,
        });
        if (rpcError) throw new Error(rpcError.message);
        const room = data as RoomRef;
        gameIdRef.current = room.game_id;
        setSeat(room.seat);
        setCode(room.code);
        setPhase("game");
        persistRoom(room);
      }),
    [myName, persistRoom, run],
  );

  const callRoom = useCallback(
    (fn: string, args: Record<string, unknown> = {}, alsoLeave = false) =>
      run(async () => {
        const id = gameIdRef.current;
        if (!id) return;
        const { error: rpcError } = await getSupabase().rpc(fn, {
          p_game_id: id,
          ...args,
        });
        if (rpcError) throw new Error(rpcError.message);
        if (alsoLeave) resetToHome();
      }),
    [resetToHome, run],
  );

  const me = useMemo(
    () => snapshot?.players.find((p) => p.isMe) ?? null,
    [snapshot],
  );
  const partner = useMemo(
    () => snapshot?.players.find((p) => !p.isMe) ?? null,
    [snapshot],
  );

  const myCharacter = useMemo(() => {
    if (!snapshot || seat == null) return null;
    const revealed =
      snapshot.game.state === "revealed" || snapshot.game.state === "finished";
    if (!revealed) return null;
    const row = snapshot.assignments.find(
      (a: Assignment) => a.seat === seat && a.revealed,
    );
    return row?.character ?? null;
  }, [seat, snapshot]);

  const partnerCharacter = useMemo(() => {
    if (!snapshot || seat == null) return null;
    const row = snapshot.assignments.find((a: Assignment) => a.seat !== seat);
    return row?.character ?? null;
  }, [seat, snapshot]);

  const partnerOnline = partner ? now - partner.lastSeen < 45000 : false;

  const remainingMs = useMemo(() => {
    if (!snapshot?.game.use_timer) return null;
    if (snapshot.game.state !== "guessing") return null;
    if (!snapshot.game.round_started_at) return null;
    const started = new Date(snapshot.game.round_started_at).getTime();
    return started + ROUND_SECONDS * 1000 - (now + offset);
  }, [now, offset, snapshot]);

  const partnerReady = partner?.revealReady ?? false;

  useEffect(() => {
    if (remainingMs == null || remainingMs > 0) return;
    if (me?.revealReady || !partnerReady) return;
    void getSupabase().rpc("set_reveal_ready", {
      p_game_id: gameIdRef.current,
      p_ready: true,
    });
  }, [me?.revealReady, partnerReady, remainingMs]);

  return {
    phase,
    setupError,
    error,
    busy,
    code,
    myName,
    setMyName: setMyNameState,
    autoJoinCode,
    snapshot,
    me,
    partner,
    myCharacter,
    partnerCharacter,
    partnerOnline: partnerOnline && Boolean(partner),
    connected,
    now,
    remainingMs,
    createGame,
    joinGame,
    leaveGame: () => callRoom("leave_game", {}, true),
    toggleReady: () => callRoom("set_lobby_ready", { p_ready: !me?.ready }),
    toggleRevealReady: (ready: boolean) =>
      callRoom("set_reveal_ready", { p_ready: ready }),
    nextRound: () => callRoom("next_round"),
    skipRound: () => callRoom("skip_round"),
    playAgain: () => callRoom("play_again"),
    toggleTimer: () => callRoom("set_timer", { p_enabled: !snapshot?.game.use_timer }),
    dismissError: () => setError(null),
  };
}
