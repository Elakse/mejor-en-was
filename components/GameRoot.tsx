"use client";

import { useEffect, useRef, useState } from "react";
import { Header } from "@/components/Header";
import { Final } from "@/components/screens/Final";
import { Guess } from "@/components/screens/Guess";
import { Home } from "@/components/screens/Home";
import { Lobby } from "@/components/screens/Lobby";
import { Reveal } from "@/components/screens/Reveal";
import { Button, Card, Spinner } from "@/components/ui";
import { useGame } from "@/lib/useGame";

function Backdrop() {
  return (
    <div className="pointer-events-none fixed inset-0 -z-10 overflow-hidden bg-[#150a2e]">
      <div className="absolute -top-24 -left-24 size-80 rounded-full bg-fuchsia-600/30 blur-3xl" />
      <div className="absolute top-1/3 -right-24 size-80 rounded-full bg-indigo-500/30 blur-3xl" />
      <div className="absolute -bottom-32 left-1/4 size-96 rounded-full bg-amber-500/20 blur-3xl" />
      <div className="absolute inset-0 bg-[radial-gradient(circle_at_50%_0%,rgba(255,255,255,0.06),transparent_60%)]" />
    </div>
  );
}

function Splash() {
  return (
    <div className="flex flex-1 flex-col items-center justify-center gap-4">
      <span className="text-5xl">🙈</span>
      <span className="text-2xl font-black text-white">Mejor en Was</span>
      <Spinner className="text-white/60" />
    </div>
  );
}

function SetupNeeded({ message }: { message: string | null }) {
  return (
    <div className="mx-auto flex w-full max-w-lg flex-1 flex-col justify-center gap-4 px-5 py-8">
      <Card className="space-y-3">
        <h1 className="text-2xl font-black text-white">One-time setup needed</h1>
        <p className="text-sm font-semibold text-white/70">
          This game runs on Supabase for real-time sync. Create a free project, then:
        </p>
        <ol className="space-y-2 text-sm font-semibold text-white/80">
          <li>
            1. Open <span className="text-amber-300">SQL Editor</span> and run the whole
            contents of{" "}
            <code className="rounded bg-black/40 px-1.5 py-0.5 text-amber-200">
              supabase/setup.sql
            </code>
            .
          </li>
          <li>
            2. Enable{" "}
            <span className="text-amber-300">
              Authentication → Sign In / Providers → Anonymous sign-ins
            </span>
            .
          </li>
          <li>
            3. Put your project URL and anon key in{" "}
            <code className="rounded bg-black/40 px-1.5 py-0.5 text-amber-200">
              .env.local
            </code>{" "}
            as{" "}
            <code className="rounded bg-black/40 px-1.5 py-0.5 text-amber-200">
              NEXT_PUBLIC_SUPABASE_URL
            </code>{" "}
            and{" "}
            <code className="rounded bg-black/40 px-1.5 py-0.5 text-amber-200">
              NEXT_PUBLIC_SUPABASE_ANON_KEY
            </code>
            , then restart.
          </li>
        </ol>
        {message && (
          <p className="rounded-xl border border-rose-400/40 bg-rose-500/15 px-3 py-2 text-xs font-bold text-rose-100">
            {message}
          </p>
        )}
        <Button variant="secondary" onClick={() => window.location.reload()}>
          Reload page
        </Button>
      </Card>
    </div>
  );
}

function RoundSplash({ round }: { round: number }) {
  return (
    <div className="pointer-events-none fixed inset-0 z-40 flex items-center justify-center bg-[#150a2e]/70 backdrop-blur-sm">
      <div className="anim-splash text-center">
        <div className="text-sm font-black tracking-[0.4em] text-amber-200 uppercase">
          Round
        </div>
        <div className="text-8xl leading-none font-black text-white drop-shadow-lg">
          {round}
        </div>
      </div>
    </div>
  );
}

export function GameRoot() {
  const game = useGame();
  const state = game.snapshot?.game.state;
  const roundIndex = game.snapshot?.game.round_index ?? 0;
  const [splash, setSplash] = useState<number | null>(null);
  const firstRound = useRef(true);

  useEffect(() => {
    if (state !== "guessing") {
      firstRound.current = true;
      return;
    }
    if (firstRound.current) {
      firstRound.current = false;
      return;
    }
    setSplash(roundIndex + 1);
    const timer = window.setTimeout(() => setSplash(null), 1150);
    return () => window.clearTimeout(timer);
  }, [roundIndex, state]);

  const partnerOnline = game.partnerOnline && Boolean(game.partner);
  const status: "live" | "syncing" | "away" = !game.connected
    ? "syncing"
    : partnerOnline
      ? "live"
      : "away";

  return (
    <div className="relative flex h-dvh flex-col overflow-hidden">
      <Backdrop />

      {game.phase === "booting" && <Splash />}

      {game.phase === "unconfigured" && <SetupNeeded message={game.setupError} />}

      {game.phase === "home" && <Home game={game} />}

      {game.phase === "game" && (
        <>
          <Header status={status} />

          {!game.snapshot && (
            <div className="flex flex-1 items-center justify-center">
              <Spinner className="text-white/60" />
            </div>
          )}

          {game.snapshot && (state === "lobby" ? (
            <Lobby game={game} />
          ) : game.snapshot.players.length < 2 ? (
            <div className="mx-auto flex w-full max-w-md flex-1 flex-col items-center justify-center gap-4 px-5 text-center">
              <span className="text-5xl">👋</span>
              <h2 className="text-2xl font-black text-white">Your partner left</h2>
              <p className="text-sm font-semibold text-white/65">
                The room is waiting for both of you in the lobby.
              </p>
              <Button variant="secondary" onClick={() => void game.leaveGame()}>
                Back to menu
              </Button>
            </div>
          ) : state === "guessing" ? (
            <Guess game={game} />
          ) : state === "revealed" ? (
            <Reveal game={game} />
          ) : (
            <Final game={game} />
          ))}
        </>
      )}

      {splash != null && <RoundSplash round={splash} />}

      {game.error && game.phase === "game" && (
        <button
          type="button"
          onClick={game.dismissError}
          className="anim-slide-up fixed inset-x-3 bottom-3 z-50 rounded-2xl border border-rose-400/40 bg-rose-950/90 px-4 py-3 text-center text-sm font-bold text-rose-100 shadow-2xl backdrop-blur"
        >
          {game.error}
        </button>
      )}
    </div>
  );
}
