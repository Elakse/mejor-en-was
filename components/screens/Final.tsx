"use client";

import { useEffect, useState } from "react";
import { Button, Card, Confetti, Pill, Spinner } from "@/components/ui";
import { VideoCallControls } from "@/components/VideoCall";
import { getSupabase } from "@/lib/supabase";
import type { Character } from "@/lib/types";
import type { GameApi } from "@/lib/useGame";
import type { VideoCallApi } from "@/lib/useVideoCall";

interface RecapRound {
  index: number;
  clue: string;
  mine: Character | null;
  theirs: Character | null;
}

export function Final({ game, call }: { game: GameApi; call: VideoCallApi }) {
  const [recap, setRecap] = useState<RecapRound[] | null>(null);
  const gameId = game.snapshot?.game.id;
  const mySeat = game.me?.seat;

  useEffect(() => {
    if (!gameId || mySeat == null) return;
    let cancelled = false;

    const load = async () => {
      const supabase = getSupabase();
      const [roundsRes, assignmentsRes] = await Promise.all([
        supabase
          .from("game_rounds")
          .select("round_index,clue")
          .eq("game_id", gameId)
          .order("round_index"),
        supabase
          .from("assignments")
          .select("round_index,seat,character_key")
          .eq("game_id", gameId),
      ]);
      if (cancelled) return;

      const rounds = roundsRes.data ?? [];
      const assignments = assignmentsRes.data ?? [];
      const keys = [...new Set(assignments.map((a) => a.character_key as string))];
      const characters = keys.length
        ? ((await supabase.from("characters").select("*").in("key", keys)).data ?? [])
        : [];
      if (cancelled) return;

      const byKey = new Map(
        characters.map((c) => [
          c.key as string,
          {
            key: c.key as string,
            name: c.name as string,
            imageUrl: c.image_url as string,
            imageCredit: c.image_credit as string,
            emoji: c.emoji as string,
          } satisfies Character,
        ]),
      );

      setRecap(
        rounds.map((r) => {
          const rows = assignments.filter((a) => a.round_index === r.round_index);
          const mine = rows.find((a) => a.seat === mySeat);
          const theirs = rows.find((a) => a.seat !== mySeat);
          return {
            index: r.round_index as number,
            clue: r.clue as string,
            mine: mine ? byKey.get(mine.character_key as string) ?? null : null,
            theirs: theirs ? byKey.get(theirs.character_key as string) ?? null : null,
          };
        }),
      );
    };

    void load();
    return () => {
      cancelled = true;
    };
  }, [gameId, mySeat]);

  return (
    <div className="mx-auto flex min-h-0 w-full max-w-2xl flex-1 flex-col gap-3 overflow-y-auto px-4 pb-[max(1rem,env(safe-area-inset-bottom))]">
      <Confetti />
      <div className="anim-pop text-center">
        <div className="text-6xl">🎉</div>
        <h2 className="mt-1 text-3xl leading-none font-black text-white drop-shadow-lg">
          That&apos;s a wrap!
        </h2>
        <p className="mt-1 text-sm font-bold text-white/65">
          10 rounds with {game.partner?.name ?? "your partner"}. Rematch?
        </p>
      </div>

      <Card className="flex-1 space-y-2 overflow-hidden">
        <div className="flex items-center justify-between">
          <span className="text-xs font-bold tracking-widest text-white/55 uppercase">
            Recap
          </span>
          {!recap && <Spinner className="size-4 text-white/40" />}
        </div>
        <div className="max-h-[42vh] space-y-1.5 overflow-y-auto pr-1">
          {(recap ?? []).map((r) => (
            <div
              key={r.index}
              className="flex items-center gap-2 rounded-xl border border-white/8 bg-black/20 px-2.5 py-2"
            >
              <span className="w-6 shrink-0 text-center text-xs font-black text-white/45">
                {r.index + 1}
              </span>
              <span className="min-w-0 flex-1 truncate text-xs font-bold text-white/70">
                {r.clue}
              </span>
              <span className="flex shrink-0 items-center gap-1 text-lg">
                <span title={r.theirs?.name ?? "Skipped"}>{r.theirs?.emoji ?? "⏭️"}</span>
                <span className="text-white/30">/</span>
                <span title={r.mine?.name ?? "Skipped"}>{r.mine?.emoji ?? "⏭️"}</span>
              </span>
            </div>
          ))}
          {recap?.length === 0 && (
            <p className="py-6 text-center text-sm font-bold text-white/45">
              No rounds were played.
            </p>
          )}
        </div>
      </Card>

      <div className="space-y-2">
        <VideoCallControls call={call} />
        <Button
          size="lg"
          className="w-full"
          disabled={game.busy}
          onClick={() => void game.playAgain()}
        >
          Play again
        </Button>
        <div className="flex items-center justify-center gap-2">
          <Pill>
            Wait for both players to be back in the lobby
          </Pill>
        </div>
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
