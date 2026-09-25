"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { RealtimeChannel } from "@supabase/supabase-js";
import { getSupabase } from "@/lib/supabase";

type Signal = {
  from: number;
  to: number;
  kind: "hello" | "offer" | "answer" | "candidate" | "bye";
  active?: boolean;
  session?: string;
  description?: RTCSessionDescriptionInit;
  candidate?: RTCIceCandidateInit;
};

export interface VideoCallApi {
  localStream: MediaStream | null;
  remoteStream: MediaStream | null;
  starting: boolean;
  partnerReady: boolean;
  connection: "off" | "waiting" | "connecting" | "connected";
  error: string | null;
  muted: boolean;
  start: () => Promise<void>;
  stop: () => void;
  toggleMute: () => void;
}

const fallbackIce: RTCIceServer[] = [{ urls: "stun:stun.l.google.com:19302" }];

async function iceServersFor(gameId: string): Promise<RTCIceServer[]> {
  try {
    const { data } = await getSupabase().auth.getSession();
    const response = await fetch("/api/ice", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${data.session?.access_token ?? ""}`,
      },
      body: JSON.stringify({ gameId }),
    });
    if (!response.ok) return fallbackIce;
    const json = (await response.json()) as { iceServers?: RTCIceServer[] };
    return Array.isArray(json.iceServers) ? json.iceServers : fallbackIce;
  } catch {
    return fallbackIce;
  }
}

export function useVideoCall(
  gameId: string | null,
  callTopic: string | null,
  mySeat: number | null,
  partnerSeat: number | null,
): VideoCallApi {
  const [localStream, setLocalStream] = useState<MediaStream | null>(null);
  const [remoteStream, setRemoteStream] = useState<MediaStream | null>(null);
  const [starting, setStarting] = useState(false);
  const [partnerReady, setPartnerReady] = useState(false);
  const [connection, setConnection] = useState<VideoCallApi["connection"]>("off");
  const [error, setError] = useState<string | null>(null);
  const [muted, setMuted] = useState(false);
  const localRef = useRef<MediaStream | null>(null);
  const peerRef = useRef<RTCPeerConnection | null>(null);
  const channelRef = useRef<RealtimeChannel | null>(null);
  const subscribedRef = useRef(false);
  const partnerReadyRef = useRef(false);
  const sessionRef = useRef<string | null>(null);
  const iceRef = useRef<RTCIceServer[]>(fallbackIce);
  const candidatesRef = useRef<RTCIceCandidateInit[]>([]);
  const openingRef = useRef(false);
  const generationRef = useRef(0);

  const send = useCallback((signal: Omit<Signal, "from" | "to">) => {
    if (!subscribedRef.current || mySeat == null || partnerSeat == null) return;
    void channelRef.current?.send({
      type: "broadcast",
      event: "signal",
      payload: { ...signal, from: mySeat, to: partnerSeat },
    });
  }, [mySeat, partnerSeat]);

  const closePeer = useCallback(() => {
    const peer = peerRef.current;
    peerRef.current = null;
    if (peer) {
      peer.ontrack = null;
      peer.onicecandidate = null;
      peer.onconnectionstatechange = null;
      peer.close();
    }
    sessionRef.current = null;
    candidatesRef.current = [];
    setRemoteStream(null);
    setConnection(localRef.current ? "waiting" : "off");
  }, []);

  const makePeer = useCallback(() => {
    const peer = new RTCPeerConnection({ iceServers: iceRef.current });
    let disconnectTimer: number | undefined;
    peerRef.current = peer;
    localRef.current?.getTracks().forEach((track) => peer.addTrack(track, localRef.current!));
    peer.onicecandidate = ({ candidate }) => {
      if (candidate && sessionRef.current) {
        send({ kind: "candidate", session: sessionRef.current, candidate: candidate.toJSON() });
      }
    };
    peer.ontrack = ({ streams, track }) => {
      const stream = streams[0] ?? new MediaStream([track]);
      setRemoteStream(stream);
    };
    peer.onconnectionstatechange = () => {
      if (peerRef.current !== peer) return;
      if (peer.connectionState === "connected") {
        window.clearTimeout(disconnectTimer);
        setConnection("connected");
        setError(null);
      } else if (peer.connectionState === "disconnected") {
        setConnection("connecting");
        window.clearTimeout(disconnectTimer);
        disconnectTimer = window.setTimeout(() => {
          if (peerRef.current === peer && peer.connectionState === "disconnected") closePeer();
        }, 8000);
      } else if (peer.connectionState === "failed" || peer.connectionState === "closed") {
        window.clearTimeout(disconnectTimer);
        closePeer();
        setError("Video could not connect. Try again, or keep playing with the card.");
      }
    };
    setConnection("connecting");
    return peer;
  }, [closePeer, send]);

  const offer = useCallback(async () => {
    if (mySeat !== 1 || !localRef.current || !partnerReadyRef.current ||
        peerRef.current || openingRef.current) return;
    openingRef.current = true;
    try {
      const peer = makePeer();
      sessionRef.current = crypto.randomUUID();
      const description = await peer.createOffer();
      await peer.setLocalDescription(description);
      if (peer.signalingState === "closed" || !localRef.current) return;
      send({ kind: "offer", session: sessionRef.current, description: peer.localDescription!.toJSON() });
    } catch {
      closePeer();
      setError("Could not start the video call. Try turning video off and on.");
    } finally {
      openingRef.current = false;
    }
  }, [closePeer, makePeer, mySeat, send]);

  const onSignal = useCallback(async (signal: Signal) => {
    if (signal.to !== mySeat || signal.from !== partnerSeat) return;
    if (signal.kind === "hello") {
      partnerReadyRef.current = Boolean(signal.active);
      setPartnerReady(Boolean(signal.active));
      if (!signal.active) {
        closePeer();
      } else if (localRef.current) {
        if (mySeat === 1) void offer();
        else send({ kind: "hello", active: true });
      }
      return;
    }
    if (signal.kind === "bye") {
      partnerReadyRef.current = false;
      setPartnerReady(false);
      closePeer();
      return;
    }
    if (!localRef.current || !signal.session) return;
    try {
      if (signal.kind === "offer" && mySeat === 2 && signal.description?.type === "offer") {
        if (sessionRef.current === signal.session) return;
        closePeer();
        sessionRef.current = signal.session;
        const peer = makePeer();
        await peer.setRemoteDescription(signal.description);
        const answer = await peer.createAnswer();
        await peer.setLocalDescription(answer);
        if (peer.signalingState === "closed" || !localRef.current) return;
        send({ kind: "answer", session: signal.session, description: peer.localDescription!.toJSON() });
        for (const candidate of candidatesRef.current) await peer.addIceCandidate(candidate);
        candidatesRef.current = [];
      } else if (signal.kind === "answer" && mySeat === 1 &&
          signal.session === sessionRef.current && signal.description?.type === "answer") {
        const peer = peerRef.current;
        if (!peer || peer.remoteDescription) return;
        await peer.setRemoteDescription(signal.description);
        for (const candidate of candidatesRef.current) await peer.addIceCandidate(candidate);
        candidatesRef.current = [];
      } else if (signal.kind === "candidate" && signal.session === sessionRef.current && signal.candidate) {
        if (peerRef.current?.remoteDescription) await peerRef.current.addIceCandidate(signal.candidate);
        else candidatesRef.current.push(signal.candidate);
      }
    } catch {
      closePeer();
      setError("Video connection was interrupted. Turn video off and on to retry.");
    }
  }, [closePeer, makePeer, mySeat, offer, partnerSeat, send]);

  useEffect(() => {
    if (!gameId || !callTopic || mySeat == null || partnerSeat == null) return;
    const generation = ++generationRef.current;
    const supabase = getSupabase();
    let channel: RealtimeChannel | null = null;
    void (async () => {
      const { data } = await supabase.auth.getSession();
      if (!data.session || generationRef.current !== generation) return;
      await supabase.realtime.setAuth(data.session.access_token);
      if (generationRef.current !== generation) return;
      channel = supabase.channel(callTopic, { config: { private: true } });
      channelRef.current = channel;
      channel.on("broadcast", { event: "signal" }, ({ payload }) => {
        void onSignal(payload as Signal);
      }).subscribe((status) => {
        subscribedRef.current = status === "SUBSCRIBED";
        if (status === "SUBSCRIBED") send({ kind: "hello", active: Boolean(localRef.current) });
        if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
          setError("Video setup is unavailable. Apply the call signaling database migration.");
        }
      });
    })();
    const heartbeat = window.setInterval(() => {
      if (localRef.current) send({ kind: "hello", active: true });
    }, 4000);
    return () => {
      if (generationRef.current === generation) generationRef.current = generation + 1;
      window.clearInterval(heartbeat);
      send({ kind: "bye" });
      subscribedRef.current = false;
      if (channel) void supabase.removeChannel(channel);
      channelRef.current = null;
      closePeer();
      localRef.current?.getTracks().forEach((track) => track.stop());
      localRef.current = null;
      partnerReadyRef.current = false;
      setLocalStream(null);
      setPartnerReady(false);
    };
  }, [gameId, callTopic, mySeat, partnerSeat, send, onSignal, closePeer]);

  const start = useCallback(async () => {
    if (!gameId || localRef.current || starting) return;
    if (!navigator.mediaDevices?.getUserMedia || !window.RTCPeerConnection) {
      setError("Video needs a supported browser and HTTPS (or localhost).");
      return;
    }
    setStarting(true);
    setError(null);
    const generation = generationRef.current;
    let stream: MediaStream;
    try {
      try {
        stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: "user", width: { ideal: 640 }, height: { ideal: 480 }, frameRate: { ideal: 24, max: 30 } },
          audio: { echoCancellation: true, noiseSuppression: true },
        });
      } catch {
        stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "user", width: { ideal: 640 }, height: { ideal: 480 } }, audio: false });
        setMuted(true);
      }
      if (generationRef.current !== generation) {
        stream.getTracks().forEach((track) => track.stop());
        return;
      }
      localRef.current = stream;
      setLocalStream(stream);
      setConnection("waiting");
      stream.getVideoTracks()[0]?.addEventListener("ended", () => {
        // The browser or OS may revoke camera access while a call is open.
        if (localRef.current === stream) {
          stream.getTracks().forEach((track) => track.stop());
          localRef.current = null;
          setLocalStream(null);
          send({ kind: "bye" });
          closePeer();
        }
      });
      iceRef.current = await iceServersFor(gameId);
      if (generationRef.current !== generation || localRef.current !== stream) return;
      send({ kind: "hello", active: true });
      if (mySeat === 1) void offer();
    } catch {
      setError("Camera access was denied or unavailable. You can still play with the character card.");
    } finally {
      setStarting(false);
    }
  }, [closePeer, gameId, mySeat, offer, send, starting]);

  const stop = useCallback(() => {
    send({ kind: "bye" });
    localRef.current?.getTracks().forEach((track) => track.stop());
    localRef.current = null;
    setLocalStream(null);
    setMuted(false);
    closePeer();
    setError(null);
  }, [closePeer, send]);

  const toggleMute = useCallback(() => {
    const audio = localRef.current?.getAudioTracks()[0];
    if (!audio) return;
    audio.enabled = !audio.enabled;
    setMuted(!audio.enabled);
  }, []);

  return { localStream, remoteStream, starting, partnerReady, connection, error, muted, start, stop, toggleMute };
}
