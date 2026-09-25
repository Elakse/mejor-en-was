"use client";

import { useEffect, useRef, useState } from "react";
import { Button, CharacterImage } from "@/components/ui";
import type { Character } from "@/lib/types";
import type { VideoCallApi } from "@/lib/useVideoCall";

type CardPosition = { left: number; top: number; width: number };

function useFaceCard(videoRef: React.RefObject<HTMLVideoElement | null>, active: boolean) {
  const [position, setPosition] = useState<CardPosition | null>(null);
  const [status, setStatus] = useState<"loading" | "ready" | "unavailable">("loading");

  useEffect(() => {
    if (!active) return;
    let cancelled = false;
    let timeout: number | undefined;
    let detector: import("@mediapipe/tasks-vision").FaceDetector | undefined;
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
        const detect = () => {
          if (cancelled || !detector) return;
          const video = videoRef.current;
          if (document.visibilityState === "visible" && video?.readyState === HTMLMediaElement.HAVE_ENOUGH_DATA && video.videoWidth) {
            try {
              const face = detector.detectForVideo(video, performance.now()).detections[0]?.boundingBox;
              if (face && video.clientWidth && video.clientHeight) {
                const scale = Math.max(video.clientWidth / video.videoWidth, video.clientHeight / video.videoHeight);
                const offsetX = (video.clientWidth - video.videoWidth * scale) / 2;
                const offsetY = (video.clientHeight - video.videoHeight * scale) / 2;
                const width = Math.min(150, Math.max(58, face.width * scale * 0.55));
                const margin = width / 2 + 8;
                setPosition({
                  left: Math.max(margin, Math.min(video.clientWidth - margin, offsetX + (face.originX + face.width / 2) * scale)),
                  top: Math.max(margin, Math.min(video.clientHeight - margin, offsetY + (face.originY + face.height * 0.12) * scale)),
                  width,
                });
              } else setPosition(null);
            } catch {
              setStatus("unavailable");
              detector?.close();
              detector = undefined;
              return;
            }
          }
          timeout = window.setTimeout(detect, 125);
        };
        detect();
      } catch {
        if (!cancelled) setStatus("unavailable");
      }
    })();
    return () => {
      cancelled = true;
      window.clearTimeout(timeout);
      detector?.close();
    };
  }, [active, videoRef]);

  return { position: active ? position : null, status };
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
  const { position, status } = useFaceCard(ref, Boolean(character));
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
          aria-label="Their character card"
          className="pointer-events-none absolute z-10 flex aspect-square items-center justify-center overflow-hidden rounded-xl border-2 border-amber-200 bg-[#241044] shadow-xl shadow-black/70"
          style={position ? {
            left: position.left,
            top: position.top,
            width: position.width,
            transform: "translate(-50%, -50%)",
          } : {
            left: "50%", top: 6, width: 72, transform: "translateX(-50%)",
          }}
        >
          {failedImageUrl === character.imageUrl ? (
            <span className="text-4xl" aria-hidden>{character.emoji}</span>
          ) : (
            <img src={character.imageUrl} alt="" className="h-full w-full object-contain" onError={() => setFailedImageUrl(character.imageUrl)} />
          )}
        </div>
      )}
      {character && !position && (
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
      <VideoCallControls call={call} />
    </div>
  );
}
