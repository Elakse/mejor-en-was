import { createHmac } from "node:crypto";
import { createClient } from "@supabase/supabase-js";

const stun: RTCIceServer = { urls: "stun:stun.l.google.com:19302" };

export async function POST(request: Request) {
  const urls = process.env.TURN_URLS?.split(",").map((url) => url.trim()).filter(Boolean);
  const secret = process.env.TURN_SHARED_SECRET;
  if (!urls?.length || !secret) {
    return Response.json({ iceServers: [stun] }, { headers: { "Cache-Control": "no-store" } });
  }

  const token = request.headers.get("authorization")?.replace(/^Bearer /i, "");
  const body = await request.json().catch(() => null);
  const gameId = body && typeof body === "object" ? body.gameId : null;
  if (!token || typeof gameId !== "string" || !/^[0-9a-f-]{36}$/i.test(gameId)) {
    return new Response(null, { status: 401 });
  }

  const supabase = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false } },
  );
  const { data: userData, error: authError } = await supabase.auth.getUser(token);
  if (authError || !userData.user) return new Response(null, { status: 401 });

  const { data: player, error: playerError } = await supabase
    .from("players")
    .select("id")
    .eq("game_id", gameId)
    .eq("uid", userData.user.id)
    .maybeSingle();
  if (playerError || !player) return new Response(null, { status: 403 });

  // coturn REST API credentials expire after one hour. The shared secret stays
  // on the server; browsers receive only their own short-lived credentials.
  const username = `${Math.floor(Date.now() / 1000) + 3600}:${userData.user.id}`;
  const credential = createHmac("sha1", secret).update(username).digest("base64");
  return Response.json(
    { iceServers: [stun, { urls, username, credential }] },
    { headers: { "Cache-Control": "no-store" } },
  );
}
