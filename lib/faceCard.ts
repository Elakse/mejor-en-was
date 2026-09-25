import type { Detection } from "@mediapipe/tasks-vision";

export interface FaceCardPose {
  x: number;
  y: number;
  width: number;
  roll: number;
  yaw: number;
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

export function foreheadPose(
  detection: Detection,
  videoWidth: number,
  videoHeight: number,
  viewWidth: number,
  viewHeight: number,
): FaceCardPose | null {
  if (!videoWidth || !videoHeight || !viewWidth || !viewHeight) return null;

  // object-cover crops the video. Apply that same crop to the detected points.
  const scale = Math.max(viewWidth / videoWidth, viewHeight / videoHeight);
  const offsetX = (viewWidth - videoWidth * scale) / 2;
  const offsetY = (viewHeight - videoHeight * scale) / 2;
  const toView = (point: { x: number; y: number }) => ({
    x: offsetX + point.x * videoWidth * scale,
    y: offsetY + point.y * videoHeight * scale,
  });

  // BlazeFace keypoints 0 and 1 are the eyes. Place the card above their line,
  // so it stays on the forehead when the head tilts instead of covering eyes.
  const eyeA = detection.keypoints[0] && toView(detection.keypoints[0]);
  const eyeB = detection.keypoints[1] && toView(detection.keypoints[1]);
  if (eyeA && eyeB) {
    const [left, right] = eyeA.x <= eyeB.x ? [eyeA, eyeB] : [eyeB, eyeA];
    const dx = right.x - left.x;
    const dy = right.y - left.y;
    const distance = Math.hypot(dx, dy);
    if (Number.isFinite(distance) && distance > 4) {
      const upX = dy / distance;
      const upY = -dx / distance;
      const eyeMidX = (left.x + right.x) / 2;
      const eyeMidY = (left.y + right.y) / 2;
      const nose = detection.keypoints[2] && toView(detection.keypoints[2]);
      const noseSideways = nose ? ((nose.x - eyeMidX) * dx + (nose.y - eyeMidY) * dy) / distance : 0;
      return {
        x: eyeMidX + upX * distance * 0.9,
        y: eyeMidY + upY * distance * 0.9,
        width: clamp(distance * 0.85, 32, 120),
        roll: clamp(Math.atan2(dy, dx) * 180 / Math.PI, -50, 50),
        yaw: nose ? clamp((noseSideways / distance) * 55, -25, 25) : 0,
      };
    }
  }

  // A box-only detection places the card near the top of the face. Never clamp
  // it down into the eyes merely to keep every pixel inside the video rectangle.
  const box = detection.boundingBox;
  if (!box) return null;
  return {
    x: offsetX + (box.originX + box.width / 2) * scale,
    y: offsetY + box.originY * scale,
    width: clamp(box.width * scale * 0.35, 32, 120),
    roll: 0,
    yaw: 0,
  };
}
