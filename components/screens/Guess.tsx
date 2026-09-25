"use client";

import { useState } from "react";
import { Button, Card, Pill, Spinner, TimerBar } from "@/components/ui";
import { VideoStage } from "@/components/VideoCall";
import { ROUND_SECONDS } from "@/lib/types";
import type { GameApi } from "@/lib/useGame";
import type { VideoCallApi } from "@/lib/useVideoCall";

export function Guess({ game, call }: { game: GameApi; call: VideoCallApi }) {
  const [confirmSkip, setConfirmSkip] = useState(false);
  const round = game.snapshot?.round;
  const partnerCharacter = game.partnerCharacter;
  const iAmReady = game.me?.revealReady ?? false;
  const partnerReady = game.partner?.revealReady ?? false;
  const timerOn = Boolean(game.snapshot?.game.use_timer);
  const remaining =
    timerOn && game.remainingMs != null ? Math.max(0, game.remainingMs) : null;

  return (
    <div className="mx-auto flex min-h-0 w-full max-w-2xl flex-1 flex-col gap-2 px-4 pb-[max(0.6rem,env(safe-area-inset-bottom))]">
      <div className="anim-slide-up flex shrink-0 items-center justify-between gap-3">
        <Pill className="border-amber-300/30 bg-amber-300/10 text-amber-100">
          Round {(round?.index ?? 0) + 1} / {round?.total ?? 10}
        </Pill>
        {round?.category && <Pill>{round.category}</Pill>}
      </div>

      {timerOn && remaining != null && (
        <div className="shrink-0">
          <TimerBar remaining={remaining} total={ROUND_SECONDS * 1000} />
        </div>
      )}

      <Card className="anim-slide-up shrink-0 border-amber-200/25 bg-gradient-to-b from-amber-300/15 to-orange-500/10 px-4 py-2.5 text-center">
        <p className="text-[10px] font-bold tracking-[0.25em] text-amber-200/80 uppercase">
          The clue
        </p>
        <p className="mt-0.5 text-lg leading-tight font-black text-white drop-shadow sm:text-xl">
          {round?.clue ?? "…"}
        </p>
      </Card>

      <Card className="anim-pop flex min-h-0 flex-1 flex-col gap-1.5 p-2">
        <VideoStage
          call={call}
          character={partnerCharacter}
          partnerName={game.partner?.name ? `${game.partner.name}'s character` : "Their character"}
        />
        <p className="shrink-0 text-center text-[13px] leading-tight font-bold text-white/65">
          {game.partner?.name ?? "Your partner"} can see your character — you cannot.
        </p>
      </Card>

      <div className="shrink-0 space-y-1.5">
        {iAmReady ? (
          <div className="flex h-15 w-full items-center justify-center gap-2 rounded-2xl border border-white/12 bg-white/8 text-base font-extrabold text-white/70">
            <Spinner className="size-4" />
            {partnerReady ? "Revealing…" : `Waiting for ${game.partner?.name ?? "them"}…`}
          </div>
        ) : (
          <Button
            size="lg"
            className="anim-pop w-full"
            disabled={game.busy}
            onClick={() => void game.toggleRevealReady(true)}
          >
            {partnerReady ? "They're ready — ready up!" : "Ready to reveal"}
          </Button>
        )}

        {confirmSkip ? (
          <div className="flex gap-2">
            <Button
              size="md"
              variant="danger"
              className="flex-1"
              onClick={() => {
                setConfirmSkip(false);
                void game.skipRound();
              }}
            >
              Yes, skip it
            </Button>
            <Button
              size="md"
              variant="secondary"
              className="flex-1"
              onClick={() => setConfirmSkip(false)}
            >
              Keep playing
            </Button>
          </div>
        ) : (
          <button
            type="button"
            onClick={() => setConfirmSkip(true)}
            className="w-full text-center text-xs font-bold text-white/40 underline"
          >
            Skip this round
          </button>
        )}

        {partnerReady && !iAmReady && (
          <p className="anim-pop text-center text-xs font-bold text-lime-300">
            {game.partner?.name ?? "Your partner"} is ready to reveal!
          </p>
        )}
      </div>
    </div>
  );
}
