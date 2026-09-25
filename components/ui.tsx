"use client";

import { useMemo, useState, type ButtonHTMLAttributes, type ReactNode } from "react";
import type { Character } from "@/lib/types";

type Variant = "primary" | "secondary" | "ghost" | "danger" | "success";
type Size = "sm" | "md" | "lg";

const VARIANTS: Record<Variant, string> = {
  primary:
    "bg-gradient-to-b from-amber-300 to-orange-500 text-orange-950 border-orange-700 shadow-lg shadow-orange-900/40",
  success:
    "bg-gradient-to-b from-lime-300 to-emerald-500 text-emerald-950 border-emerald-700 shadow-lg shadow-emerald-900/40",
  secondary:
    "bg-white/12 text-white border-white/20 shadow-lg shadow-black/30 backdrop-blur",
  ghost: "bg-transparent text-white/70 border-transparent shadow-none",
  danger:
    "bg-gradient-to-b from-rose-400 to-rose-600 text-white border-rose-800 shadow-lg shadow-rose-900/40",
};

const SIZES: Record<Size, string> = {
  sm: "h-10 px-4 text-sm rounded-xl border-b-[3px]",
  md: "h-13 px-6 text-base rounded-2xl border-b-4",
  lg: "h-16 px-8 text-lg rounded-2xl border-b-4",
};

export function Button({
  variant = "primary",
  size = "md",
  className = "",
  children,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; size?: Size }) {
  return (
    <button
      {...rest}
      className={`inline-flex select-none items-center justify-center gap-2 font-extrabold tracking-wide transition-all duration-100 active:translate-y-[2px] active:border-b-[2px] disabled:cursor-not-allowed disabled:opacity-45 disabled:active:translate-y-0 disabled:active:border-b-4 ${VARIANTS[variant]} ${SIZES[size]} ${className}`}
    >
      {children}
    </button>
  );
}

export function Card({
  className = "",
  children,
}: {
  className?: string;
  children: ReactNode;
}) {
  return (
    <div
      className={`rounded-3xl border border-white/12 bg-white/7 p-4 shadow-2xl shadow-black/40 backdrop-blur-md ${className}`}
    >
      {children}
    </div>
  );
}

export function Pill({
  className = "",
  children,
}: {
  className?: string;
  children: ReactNode;
}) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border border-white/15 bg-white/10 px-3 py-1 text-xs font-bold tracking-widest text-white/85 uppercase ${className}`}
    >
      {children}
    </span>
  );
}

export function Spinner({ className = "" }: { className?: string }) {
  return (
    <span
      className={`inline-block size-5 animate-spin rounded-full border-2 border-current border-t-transparent ${className}`}
    />
  );
}

export function Dot({ tone }: { tone: "good" | "warn" | "bad" }) {
  const color =
    tone === "good" ? "bg-emerald-400" : tone === "warn" ? "bg-amber-400" : "bg-rose-500";
  return (
    <span className="relative flex size-2.5">
      <span
        className={`absolute inline-flex h-full w-full animate-ping rounded-full opacity-60 ${color}`}
      />
      <span className={`relative inline-flex size-2.5 rounded-full ${color}`} />
    </span>
  );
}

export function CharacterImage({
  character,
  eager = false,
  className = "",
}: {
  character: Character;
  eager?: boolean;
  className?: string;
}) {
  const [loaded, setLoaded] = useState<string | null>(null);
  const [failed, setFailed] = useState<string | null>(null);
  const status =
    failed === character.imageUrl
      ? "error"
      : loaded === character.imageUrl
        ? "loaded"
        : "loading";

  return (
    <div className={`relative h-full w-full ${className}`}>
      {status !== "loaded" && (
        <div className="absolute inset-0 animate-pulse rounded-2xl bg-white/10" />
      )}
      {status === "error" ? (
        <div className="flex h-full w-full flex-col items-center justify-center gap-1 rounded-2xl bg-gradient-to-br from-fuchsia-500/25 to-indigo-500/25 p-3 text-center">
          <span className="text-5xl drop-shadow sm:text-6xl">{character.emoji}</span>
          <span className="text-base font-extrabold text-white drop-shadow">
            {character.name}
          </span>
        </div>
      ) : (
        <img
          src={character.imageUrl}
          alt={character.name}
          draggable={false}
          decoding="async"
          loading={eager ? "eager" : "lazy"}
          fetchPriority={eager ? "high" : "auto"}
          referrerPolicy="no-referrer"
          onLoad={() => setLoaded(character.imageUrl)}
          onError={() => setFailed(character.imageUrl)}
          className={`h-full w-full object-contain transition-opacity duration-300 ${
            status === "loaded" ? "opacity-100" : "opacity-0"
          }`}
        />
      )}
    </div>
  );
}

function seededRandom(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function Confetti({ count = 70, seed = 20260101 }: { count?: number; seed?: number }) {
  const pieces = useMemo(() => {
    const rand = seededRandom(seed);
    return Array.from({ length: count }, (_, i) => ({
      id: i,
      left: rand() * 100,
      delay: rand() * 2.4,
      duration: 2.6 + rand() * 2.2,
      size: 6 + rand() * 8,
      rotate: rand() * 360,
      hue: Math.floor(rand() * 360),
      round: rand() > 0.6,
    }));
  }, [count, seed]);
  return (
    <div className="pointer-events-none fixed inset-0 z-30 overflow-hidden">
      {pieces.map((p) => (
        <span
          key={p.id}
          className="absolute top-[-12%] block animate-[confetti-fall_linear_forwards]"
          style={{
            left: `${p.left}%`,
            width: p.size,
            height: p.size * (p.round ? 1 : 0.45),
            background: `hsl(${p.hue} 90% 62%)`,
            borderRadius: p.round ? "999px" : "2px",
            animationDelay: `${p.delay}s`,
            animationDuration: `${p.duration}s`,
            transform: `rotate(${p.rotate}deg)`,
          }}
        />
      ))}
    </div>
  );
}

export function TimerBar({ remaining, total }: { remaining: number; total: number }) {
  const pct = Math.max(0, Math.min(100, (remaining / total) * 100));
  const seconds = Math.max(0, Math.ceil(remaining / 1000));
  const urgent = seconds <= 10;
  return (
    <div className="w-full">
      <div className="mb-1 flex items-center justify-between text-xs font-bold tracking-widest text-white/60 uppercase">
        <span>Round timer</span>
        <span className={urgent ? "text-rose-300" : ""}>{seconds}s</span>
      </div>
      <div className="h-2 w-full overflow-hidden rounded-full bg-white/12">
        <div
          className={`h-full rounded-full transition-[width] duration-500 ease-linear ${
            urgent
              ? "bg-gradient-to-r from-rose-500 to-red-400"
              : "bg-gradient-to-r from-amber-300 to-orange-500"
          }`}
          style={{ width: `${pct}%` }}
        />
      </div>
    </div>
  );
}
