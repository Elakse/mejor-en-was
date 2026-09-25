"use client";

import { useEffect, useRef, useState } from "react";
import { Button, CharacterImage } from "@/components/ui";
import { foreheadPose, type FaceCardPose } from "@/lib/faceCard";
import type { Character } from "@/lib/types";
import type { VideoCallApi } from "@/lib/useVideoCall";

function useFaceCard(
  videoRef: React.RefObject<HTMLVideoElement | null>,
  cardRef: React.RefObject<HTMLDivElement | null>,
  active: boolean,
) {
  const [hasFace, setHasFace] = useState(false);
  const [status, setStatus] = useState<"loading" | "ready" | "unavailable">("loading");

  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    let videoFrameId: number | undefined;
    let fallbackFrameId: number | undefined;
    let motionFrameId: number | undefined;
    let detector: import("@mediapipe/tasks-vision").FaceDetector | undefined;
    let target: FaceCardPose | null = null;
    let displayed: FaceCardPose | null = null;
    let tracked = false;
    let lastSeen = 0;
    let lastDetection = 0;
    let lastMotion = 0;
    let lastModelTimestamp = 0;
    let inferenceInterval = 16;
    const videoElement = videoRef.current;

    const clearTracking = (updateState: boolean) => {
      target = null;
      displayed = null;
      lastMotion = 0;
      if (!tracked) return;
      tracked = false;
      const card = cardRef.current;
      if (card) {
        delete card.dataset.tracked;
        for (const property of ["--card-x", "--card-y", "--card-width", "--card-roll", "--card-yaw"]) {
          card.style.removeProperty(property);
        }
      }
      if (updateState) setHasFace(false);
    };

    const animate = (now: number) => {
      if (cancelled) return;
      if (tracked && now - lastSeen > 500) clearTracking(true);
      if (tracked && target && displayed && cardRef.current) {
        const elapsed = lastMotion ? Math.min(now - lastMotion, 50) : 16;
        const distance = Math.hypot(target.x - displayed.x, target.y - displayed.y);
        const positionAlpha = 1 - Math.exp(-elapsed / (distance > 14 ? 18 : 42));
        const sizeAlpha = 1 - Math.exp(-elapsed / 55);
        displayed.x += (target.x - displayed.x) * positionAlpha;
        displayed.y += (target.y - displayed.y) * positionAlpha;
        displayed.width += (target.width - displayed.width) * sizeAlpha;
        displayed.roll += (target.roll - displayed.roll) * positionAlpha;
        displayed.yaw += (target.yaw - displayed.yaw) * sizeAlpha;
        const style = cardRef.current.style;
        style.setProperty("--card-x", `${displayed.x.toFixed(2)}px`);
        style.setProperty("--card-y", `${displayed.y.toFixed(2)}px`);
        style.setProperty("--card-width", `${displayed.width.toFixed(2)}px`);
        style.setProperty("--card-roll", `${displayed.roll.toFixed(2)}deg`);
        style.setProperty("--card-yaw", `${displayed.yaw.toFixed(2)}deg`);
      }
      lastMotion = now;
      motionFrameId = tracked ? window.requestAnimationFrame(animate) : undefined;
    };

    const scheduleDetection = () => {
      const video = videoRef.current;
      if (!video || cancelled) return;
      if ("requestVideoFrameCallback" in video) {
        videoFrameId = video.requestVideoFrameCallback(detectFrame);
      } else {
        fallbackFrameId = window.requestAnimationFrame(detectFrame);
      }
    };

    const detectFrame = (now: number) => {
      if (cancelled || !detector) return;
      const video = videoRef.current;
      if (document.visibilityState === "visible" && video && video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA &&
          video.videoWidth && now - lastDetection >= inferenceInterval) {
        lastDetection = now;
        try {
          const started = performance.now();
          const timestamp = Math.max(started, lastModelTimestamp + 1);
          lastModelTimestamp = timestamp;
          const detections = detector.detectForVideo(video, timestamp).detections;
          const face = detections.reduce<(typeof detections)[number] | null>((best, candidate) => {
            const area = (candidate.boundingBox?.width ?? 0) * (candidate.boundingBox?.height ?? 0);
            const bestArea = (best?.boundingBox?.width ?? 0) * (best?.boundingBox?.height ?? 0);
            return area > bestArea ? candidate : best;
          }, null);
          inferenceInterval = Math.min(42, Math.max(16, (performance.now() - started) * 1.15));
          const pose = face && foreheadPose(face, video.videoWidth, video.videoHeight, video.clientWidth, video.clientHeight);
          if (pose) {
            target = pose;
            lastSeen = now;
            if (!displayed) displayed = { ...pose };
            if (!tracked) {
              tracked = true;
              if (cardRef.current) cardRef.current.dataset.tracked = "true";
              setHasFace(true);
              motionFrameId = window.requestAnimationFrame(animate);
            }
          }
        } catch {
          setStatus("unavailable");
          clearTracking(true);
          detector.close();
          detector = undefined;
          return;
        }
      }
      scheduleDetection();
    };

    void (async () => {
      try {
        const { FaceDetector, FilesetResolver } = await import("@mediapipe/tasks-vision");
        const files = await FilesetResolver.forVisionTasks(
          "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@1.0.1/wasm",
        );
        if (cancelled) return;
        detector = await FaceDetector.createFromOptions(files, {
          baseOptions: {
            modelAssetPath: "https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite",
          },
          runningMode: "VIDEO",
          minDetectionConfidence: 0.55,
        });
        if (cancelled) { detector.close(); return; }
        setStatus("ready");
        scheduleDetection();
      } catch {
        if (!cancelled) setStatus("unavailable");
      }
    })();
    return () => {
      cancelled = true;
      if (videoElement && videoFrameId != null) videoElement.cancelVideoFrameCallback(videoFrameId);
      if (fallbackFrameId != null) window.cancelAnimationFrame(fallbackFrameId);
      if (motionFrameId != null) window.cancelAnimationFrame(motionFrameId);
      clearTracking(false);
      detector?.close();
    };
  }, [active, cardRef, videoRef]);

  return { hasFace: active && hasFace, status };
}

function StreamVideo({ stream, className, muted }: { stream: MediaStream; className: string; muted: boolean }) {
  const ref = useRef<HTMLVideoElement>(null);
  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    video.srcObject = stream;
    void video.play().catch(() => {});
    return () => { video.srcObject = null; };
  }, [stream]);
  return <video ref={ref} className={className} autoPlay playsInline muted={muted} />;
}

function RemoteVideo({ stream, character }: { stream: MediaStream; character: Character | null }) {
  const ref = useRef<HTMLVideoElement>(null);
  const cardRef = useRef<HTMLDivElement>(null);
  const { hasFace, status } = useFaceCard(ref, cardRef, Boolean(character));
  const [failedImageUrl, setFailedImageUrl] = useState<string | null>(null);
  useEffect(() => {
    const video = ref.current;
    if (!video) return;
    video.srcObject = stream;
    void video.play().catch(() => {});
    return () => { video.srcObject = null; };
  }, [stream]);
  return (
    <div className="absolute inset-0 overflow-hidden rounded-2xl bg-black" data-face-tracking={status}>
      <video ref={ref} className="h-full w-full object-cover" autoPlay playsInline muted />
      {character && (
        <div
          ref={cardRef}
          aria-label="Their character card"
          className="forehead-card pointer-events-none absolute z-10 flex items-center justify-center rounded-xl border-[3px] border-[#fff4dc] bg-[#fffaf0] p-1 shadow-xl shadow-black/70"
        >
          {failedImageUrl === character.imageUrl ? (
            <span className="text-4xl" aria-hidden>{character.emoji}</span>
          ) : (
            <img src={character.imageUrl} alt="" className="h-full w-full rounded-md bg-[#241044] object-contain" onError={() => setFailedImageUrl(character.imageUrl)} />
          )}
        </div>
      )}
      {character && !hasFace && (
        <span className="absolute top-20 left-1/2 -translate-x-1/2 rounded-full bg-black/60 px-2 py-1 text-[10px] font-bold text-white/80">
          {status === "unavailable" ? "Face tracking unavailable — card pinned" : "Looking for a face — card pinned"}
        </span>
      )}
    </div>
  );
}

export function RemoteAudio({ call }: { call: VideoCallApi }) {
  const ref = useRef<HTMLAudioElement>(null);
  useEffect(() => {
    const audio = ref.current;
    if (!audio) return;
    audio.srcObject = call.remoteStream;
    if (call.remoteStream) void audio.play().catch(() => {});
    return () => { audio.srcObject = null; };
  }, [call.remoteStream]);
  return <audio ref={ref} autoPlay />;
}

export function VideoCallControls({ call }: { call: VideoCallApi }) {
  return (
    <div className="flex shrink-0 items-center justify-between gap-2 text-xs font-bold text-white/65">
      <span role="status" className="min-w-0 truncate">
        {call.error ?? (call.connection === "connected" ? "Live video call" :
          call.localStream ? call.partnerReady ? "Connecting video…" : "Waiting for their video…" :
          call.partnerReady ? "They're ready for video" : "Video call is optional")}
      </span>
      {call.localStream ? (
        <span className="flex shrink-0 gap-1">
          {call.localStream.getAudioTracks().length > 0 && (
            <Button size="sm" variant="secondary" className="h-9 px-2 text-[11px]" onClick={call.toggleMute}>
              {call.muted ? "Unmute" : "Mute"}
            </Button>
          )}
          <Button size="sm" variant="secondary" className="h-9 px-2 text-[11px]" onClick={call.stop}>Stop video</Button>
        </span>
      ) : (
        <Button size="sm" variant="secondary" className="h-9 shrink-0 px-3 text-[11px]" disabled={call.starting} onClick={() => void call.start()}>
          {call.starting ? "Opening camera…" : "Start video call"}
        </Button>
      )}
    </div>
  );
}

export function VideoStage({
  call, character, partnerName, compact = false,
}: {
  call: VideoCallApi;
  character: Character | null;
  partnerName: string;
  compact?: boolean;
}) {
  return (
    <div className="flex min-h-0 flex-1 flex-col gap-1.5">
      <div className={`relative min-h-0 overflow-hidden rounded-2xl bg-gradient-to-b from-white/10 to-white/[0.03] ${compact ? "h-40 shrink-0" : "flex-1"}`}>
        {call.remoteStream ? (
          <RemoteVideo stream={call.remoteStream} character={character} />
        ) : character ? (
          <CharacterImage character={character} eager />
        ) : (
          <div className="flex h-full items-center justify-center text-sm font-bold text-white/50">
            {call.localStream ? "Waiting for the other camera…" : "Turn on video to see each other"}
          </div>
        )}
        {call.localStream && (
          <div className="absolute right-2 bottom-2 z-20 h-20 w-15 overflow-hidden rounded-xl border-2 border-white/70 bg-black shadow-xl">
            <StreamVideo stream={call.localStream} className="h-full w-full -scale-x-100 object-cover" muted />
            <span className="absolute bottom-0 left-0 bg-black/60 px-1 text-[9px] font-bold">You</span>
          </div>
        )}
        <span className="absolute bottom-2 left-2 z-20 rounded-full bg-black/60 px-2.5 py-1 text-[10px] font-black tracking-widest text-white/85 uppercase backdrop-blur">
          {partnerName}
        </span>
      </div>
      {character && (
        <div data-partner-character-name className="flex shrink-0 items-baseline justify-center gap-2 rounded-xl border border-amber-200/25 bg-amber-200/10 px-3 py-1.5 text-center">
          <span className="shrink-0 text-[10px] font-black tracking-wider text-amber-200/75 uppercase">
            Their character
          </span>
          <strong className="min-w-0 text-sm leading-tight text-white">{character.name}</strong>
        </div>
      )}
      <VideoCallControls call={call} />
    </div>
  );
}
