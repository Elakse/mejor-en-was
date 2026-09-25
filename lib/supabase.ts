import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
export const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? "";

export const isSupabaseConfigured =
  SUPABASE_URL.startsWith("http") && SUPABASE_ANON_KEY.length > 20;

let cached: SupabaseClient | null = null;

export function getSupabase(): SupabaseClient {
  if (!isSupabaseConfigured) {
    throw new Error("Supabase is not configured");
  }
  if (!cached) {
    cached = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        storageKey: "mejor-en-was-session",
      },
      realtime: { params: { eventsPerSecond: 5 } },
    });
  }
  return cached;
}

export class SetupError extends Error {}

export async function ensureSession(): Promise<void> {
  const supabase = getSupabase();
  const {
    data: { session },
  } = await supabase.auth.getSession();
  if (session) return;

  const { error } = await supabase.auth.signInAnonymously();
  if (!error) return;

  if (/anonymous/i.test(error.message)) {
    throw new SetupError(
      "Anonymous sign-ins are disabled in your Supabase project. Enable Authentication → Sign In / Providers → Anonymous sign-ins, then reload.",
    );
  }
  throw new SetupError(error.message);
}

export function friendlyError(message: string): string {
  const map: Record<string, string> = {
    room_not_found: "We couldn't find a room with that code.",
    room_full: "That room already has two players.",
    room_expired: "That room has expired.",
    not_a_player: "You are not part of this room any more.",
    not_authenticated: "Your session expired. Reload the page to start a new one.",
    could_not_allocate_code: "Could not create a room, please try again.",
    not_enough_pairings: "The round library is incomplete. Re-run supabase/setup.sql.",
    Failed_to_fetch: "Can't reach the server. Check your connection.",
  };
  for (const [key, value] of Object.entries(map)) {
    if (message.includes(key)) return value;
  }
  if (/anonymous/i.test(message)) {
    return "Anonymous sign-ins are disabled in your Supabase project.";
  }
  return message.replace(/^[a-z_]+: /i, "");
}
