"use client";

import { Button, Card, CharacterImage, Pill } from "@/components/ui";
import type { GameApi } from "@/lib/useGame";

export function Reveal({ game }: { game: GameApi }) {
  const round = game.snapshot?.round;
  const isLast = (round?.index ?? 0) >= (round?.total ?? 10) - 1;

  return (
    <div className="mx-auto flex min-h-0 w-full max-w-2xl flex-1 flex-col gap-2 px-4 pb-[max(0.6rem,env(safe-area-inset-bottom))]">
      <div className="flex items-center justify-between gap-3">
        <Pill className="border-lime-300/30 bg-lime-300/10 text-lime-100">Revealed</Pill>
        <Pill>
          Round {(round?.index ?? 0) + 1} / {round?.total ?? 10}
        </Pill>
      </div>

      <Card className="shrink-0 border-lime-200/20 bg-gradient-to-b from-lime-300/12 to-emerald-500/10 px-4 py-2.5 text-center">
        <p className="text-xs font-bold tracking-[0.25em] text-lime-200/80 uppercase">
          The clue was
        </p>
        <p className="mt-1 text-base leading-snug font-black text-white sm:text-lg">
          {round?.clue ?? ""}
        </p>
      </Card>

      <div className="grid min-h-0 flex-1 grid-cols-2 gap-2">
        <Card className="anim-flip flex min-h-0 flex-col gap-1.5 border-amber-300/35 bg-amber-300/10 p-2.5">
          <span className="text-center text-[11px] font-black tracking-widest text-amber-200 uppercase">
            Your character
          </span>
          <div className="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden rounded-2xl bg-black/25 p-2">
            {game.myCharacter && <CharacterImage character={game.myCharacter} eager />}
          </div>
          <span className="text-center text-lg leading-tight font-black text-white">
            {game.myCharacter?.name}
          </span>
        </Card>

        <Card className="anim-flip flex min-h-0 flex-col gap-1.5 p-2.5 [animation-delay:120ms]">
          <span className="text-center text-[11px] font-black tracking-widest text-white/60 uppercase">
            Their character
          </span>
          <div className="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden rounded-2xl bg-black/25 p-2">
            {game.partnerCharacter && (
              <CharacterImage character={game.partnerCharacter} eager />
            )}
          </div>
          <span className="text-center text-lg leading-tight font-black text-white">
            {game.partnerCharacter?.name}
          </span>
        </Card>
      </div>

      <p className="text-center text-xs font-semibold text-white/45">
        {game.partner?.name ?? "Your partner"} now knows who they were. Say it out loud!
      </p>

      <Button
        size="lg"
        className="w-full"
        disabled={game.busy}
        onClick={() => void game.nextRound()}
      >
        {isLast ? "See final results" : "Next round"}
      </Button>
    </div>
  );
}
