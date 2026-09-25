"use client";

import { useState } from "react";
import { Button, Card } from "@/components/ui";
import type { GameApi } from "@/lib/useGame";

export function Home({ game }: { game: GameApi }) {
  const [code, setCode] = useState(game.autoJoinCode ?? "");
  const [joinOpen, setJoinOpen] = useState(false);
  const invited = Boolean(game.autoJoinCode);
  const showJoin = joinOpen || invited;

  return (
    <div className="mx-auto flex min-h-0 w-full max-w-md flex-1 flex-col justify-center gap-5 overflow-y-auto px-5 py-6">
      <div className="text-center">
        <div className="mb-1 text-5xl">🙈</div>
        <h1 className="text-4xl leading-none font-black tracking-tight text-white drop-shadow-lg sm:text-5xl">
          Mejor<span className="text-amber-300"> en </span>Was
        </h1>
        <p className="mx-auto mt-2 max-w-xs text-sm font-semibold text-white/70">
          Two players, one phone each. You can see their character. They can see yours.
          You cannot see your own.
        </p>
      </div>

      <Card className="space-y-3">
        <label className="block">
          <span className="mb-1 block text-xs font-bold tracking-widest text-white/60 uppercase">
            Your name
          </span>
          <input
            value={game.myName}
            onChange={(e) => game.setMyName(e.target.value.slice(0, 18))}
            placeholder="Your name"
            className="h-12 w-full rounded-xl border border-white/15 bg-black/25 px-4 text-base font-bold text-white outline-none placeholder:text-white/35 focus:border-amber-300/70"
          />
        </label>

        {invited && (
          <p className="rounded-xl border border-amber-300/30 bg-amber-300/10 px-3 py-2 text-sm font-bold text-amber-100">
            You were invited to room{" "}
            <span className="tracking-[0.25em]">{game.autoJoinCode}</span>
          </p>
        )}

        <Button
          size="lg"
          className="w-full"
          disabled={game.busy}
          onClick={() => void game.createGame()}
        >
          Create game
        </Button>

        {showJoin ? (
          <div className="space-y-2">
            <span className="block text-xs font-bold tracking-widest text-white/60 uppercase">
              Room code
            </span>
            <div className="flex gap-2">
              <input
                value={code}
                onChange={(e) =>
                  setCode(e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 4))
                }
                inputMode="text"
                autoCapitalize="characters"
                autoComplete="off"
                placeholder="ABCD"
                className="h-13 w-full rounded-xl border border-white/15 bg-black/25 px-4 text-center text-2xl font-black tracking-[0.4em] text-white uppercase outline-none placeholder:tracking-[0.3em] placeholder:text-white/25 focus:border-amber-300/70"
              />
              <Button
                size="md"
                variant="success"
                disabled={game.busy || code.length !== 4}
                onClick={() => void game.joinGame(code)}
              >
                Join
              </Button>
            </div>
          </div>
        ) : (
          <Button
            size="md"
            variant="secondary"
            className="w-full"
            onClick={() => setJoinOpen(true)}
          >
            I have a room code
          </Button>
        )}
      </Card>

      {game.error && (
        <button
          type="button"
          onClick={game.dismissError}
          className="rounded-xl border border-rose-400/40 bg-rose-500/15 px-4 py-3 text-sm font-bold text-rose-100"
        >
          {game.error} <span className="text-rose-200/70">(tap to dismiss)</span>
        </button>
      )}

      <ol className="mx-auto space-y-1 text-center text-xs font-semibold text-white/45">
        <li>1. Create a game and share the code or QR.</li>
        <li>2. Each of you sees the other&apos;s secret character.</li>
        <li>3. Talk it out, ready up, reveal, repeat 10 rounds.</li>
      </ol>
    </div>
  );
}
