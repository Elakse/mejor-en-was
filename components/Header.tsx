"use client";

import { useEffect, useState } from "react";
import { Dot, Pill } from "@/components/ui";

export function Header({
  status,
  right,
}: {
  status: "live" | "syncing" | "away";
  right?: React.ReactNode;
}) {
  const [fullscreen, setFullscreen] = useState(false);

  useEffect(() => {
    const onChange = () => setFullscreen(Boolean(document.fullscreenElement));
    document.addEventListener("fullscreenchange", onChange);
    return () => document.removeEventListener("fullscreenchange", onChange);
  }, []);

  const toggleFullscreen = () => {
    if (document.fullscreenElement) {
      void document.exitFullscreen();
    } else {
      void document.documentElement.requestFullscreen().catch(() => {});
    }
  };

  const label = status === "live" ? "Live" : status === "away" ? "Away" : "Syncing";
  const tone = status === "live" ? "good" : "warn";

  return (
    <header className="flex shrink-0 items-center justify-between gap-2 px-4 pt-[max(0.75rem,env(safe-area-inset-top))] pb-1">
      <div className="flex items-baseline gap-2">
        <span className="text-lg font-black tracking-tight text-white drop-shadow">
          Mejor<span className="text-amber-300"> en </span>Was
        </span>
        {right}
      </div>
      <div className="flex items-center gap-2">
        <Pill>
          <Dot tone={tone} />
          {label}
        </Pill>
        <button
          type="button"
          onClick={toggleFullscreen}
          aria-label="Toggle fullscreen"
          className="flex size-9 items-center justify-center rounded-xl border border-white/15 bg-white/10 text-white/80 transition hover:bg-white/20"
        >
          <svg viewBox="0 0 24 24" fill="none" className="size-4" aria-hidden>
            {fullscreen ? (
              <path
                d="M9 3H5a2 2 0 0 0-2 2v4m0 6v4a2 2 0 0 0 2 2h4m6-18h4a2 2 0 0 1 2 2v4m0 6v4a2 2 0 0 1-2 2h-4"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
              />
            ) : (
              <path
                d="M4 9V5a1 1 0 0 1 1-1h4m6 0h4a1 1 0 0 1 1 1v4m0 6v4a1 1 0 0 1-1 1h-4m-6 0H5a1 1 0 0 1-1-1v-4"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
              />
            )}
          </svg>
        </button>
      </div>
    </header>
  );
}
