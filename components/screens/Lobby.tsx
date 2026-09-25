"use client";

import { useState } from "react";
import { QRCodeSVG } from "qrcode.react";
import { Button, Card, Dot, Pill } from "@/components/ui";
import type { GameApi } from "@/lib/useGame";

function joinUrlFor(code: string | null) {
  if (!code || typeof window === "undefined") return "";
  return `${window.location.origin}${window.location.pathname}?r=${code}`;
}

function onlineFor(game: GameApi, seat: number) {
  const player = game.snapshot?.players.find((p) => p.seat === seat);
  if (!player) return false;
  return game.now - player.lastSeen < 45000;
}

export function Lobby({ game }: { game: GameApi }) {
  const joinUrl = joinUrlFor(game.code);
  const [copied, setCopied] = useState<"code" | "link" | null>(null);
  const [showQr, setShowQr] = useState(false);
  const players = game.snapshot?.players ?? [];
  const seated = new Map(players.map((p) => [p.seat, p]));
  const alone = players.length < 2;
  const iAmReady = game.me?.ready ?? false;
  const partnerReady = game.partner?.ready ?? false;

  const copy = async (value: string, kind: "code" | "link") => {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(kind);
      window.setTimeout(() => setCopied(null), 1600);
    } catch {
      setCopied(null);
    }
  };

  return (
    <div className="mx-auto flex min-h-0 w-full max-w-md flex-1 flex-col gap-3 overflow-y-auto px-5 py-4">
      <div className="my-auto space-y-3">
      <Card className="space-y-3 text-center">
        <div className="text-xs font-bold tracking-[0.3em] text-white/60 uppercase">
          Room code
        </div>
        <div className="flex justify-center gap-2">
          {(game.code ?? "----").split("").map((letter, i) => (
            <span
              key={i}
              className="flex size-13 items-center justify-center rounded-2xl border border-white/15 bg-black/30 text-3xl font-black text-amber-300 shadow-inner"
            >
              {letter}
            </span>
          ))}
        </div>
        <div className="flex flex-wrap justify-center gap-2">
          <Button
            size="sm"
            variant="secondary"
            onClick={() => void copy(game.code ?? "", "code")}
          >
            {copied === "code" ? "Copied!" : "Copy code"}
          </Button>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => void copy(joinUrl, "link")}
          >
            {copied === "link" ? "Copied!" : "Copy link"}
          </Button>
          <Button size="sm" variant="secondary" onClick={() => setShowQr((v) => !v)}>
            {showQr ? "Hide QR" : "Show QR"}
          </Button>
        </div>
        {showQr && joinUrl && (
          <div className="flex flex-col items-center gap-2 pt-1">
            <div className="rounded-2xl bg-white p-3 shadow-xl">
              <QRCodeSVG value={joinUrl} size={168} marginSize={0} />
            </div>
            <p className="max-w-[16rem] text-xs font-semibold text-white/60">
              Point the other phone&apos;s camera here to join instantly.
            </p>
          </div>
        )}
      </Card>

      <Card className="space-y-2">
        {[1, 2].map((seat) => {
          const player = seated.get(seat);
          const isMe = player?.isMe ?? false;
          const online = onlineFor(game, seat);
          return (
            <div
              key={seat}
              className={`flex items-center justify-between rounded-2xl border px-3 py-2.5 ${
                isMe
                  ? "border-amber-300/40 bg-amber-300/10"
                  : "border-white/10 bg-black/20"
              }`}
            >
              <div className="flex items-center gap-3">
                <span className="flex size-9 items-center justify-center rounded-xl bg-white/12 text-sm font-black text-white">
                  P{seat}
                </span>
                <div className="leading-tight">
                  <div className="text-sm font-extrabold text-white">
                    {player ? player.name : "Waiting…"}
                    {isMe && <span className="ml-1 text-amber-300">(you)</span>}
                  </div>
                  <div className="text-[11px] font-bold tracking-wider text-white/50 uppercase">
                    Player {seat}
                  </div>
                </div>
              </div>
              {player ? (
                <span className="flex items-center gap-1.5">
                  <Dot tone={online ? "good" : "warn"} />
                  {player.ready && <Pill className="border-lime-300/40 bg-lime-300/15 text-lime-100">Ready</Pill>}
                </span>
              ) : (
                <Pill>Not here yet</Pill>
              )}
            </div>
          );
        })}
      </Card>

      <Card className="flex items-center justify-between gap-3">
        <div>
          <div className="text-sm font-extrabold text-white">Round timer</div>
          <div className="text-xs font-semibold text-white/55">
            60 seconds, then the reveal unlocks by itself.
          </div>
        </div>
        <button
          type="button"
          role="switch"
          aria-checked={game.snapshot?.game.use_timer ?? false}
          onClick={() => void game.toggleTimer()}
          className={`relative h-8 w-14 shrink-0 rounded-full border transition ${
            game.snapshot?.game.use_timer
              ? "border-lime-300/50 bg-lime-400/80"
              : "border-white/15 bg-white/12"
          }`}
        >
          <span
            className={`absolute top-[3px] size-6 rounded-full bg-white shadow transition-all ${
              game.snapshot?.game.use_timer ? "left-[26px]" : "left-[3px]"
            }`}
          />
        </button>
      </Card>

      </div>

      <div className="mt-auto space-y-2">
        {alone ? (
          <div className="rounded-2xl border border-white/10 bg-black/20 px-4 py-3 text-center text-sm font-bold text-white/60">
            Waiting for the second player to join…
          </div>
        ) : (
          <>
            <Button
              size="lg"
              variant={iAmReady ? "secondary" : "success"}
              className="w-full"
              disabled={game.busy}
              onClick={() => void game.toggleReady()}
            >
              {iAmReady
                ? partnerReady
                  ? "Starting…"
                  : `Ready! Waiting for ${game.partner?.name ?? "them"}…`
                : "I'm ready"}
            </Button>
            {iAmReady && (
              <button
                type="button"
                onClick={() => void game.toggleReady()}
                className="w-full text-center text-xs font-bold text-white/45 underline"
              >
                Never mind, not ready
              </button>
            )}
          </>
        )}
        <button
          type="button"
          onClick={() => void game.leaveGame()}
          className="w-full text-center text-xs font-bold text-white/35 underline"
        >
          Leave room
        </button>
      </div>
    </div>
  );
}
