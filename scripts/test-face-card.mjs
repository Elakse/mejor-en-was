import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import ts from "typescript";

const source = await readFile(new URL("../lib/faceCard.ts", import.meta.url), "utf8");
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext } }).outputText;
const { foreheadPose } = await import(`data:text/javascript;base64,${Buffer.from(compiled).toString("base64")}`);

const face = (left, right, nose) => ({
  keypoints: [left, right, nose].map(([x, y]) => ({ x: x / 600, y: y / 600 })),
  boundingBox: { originX: 175, originY: 215, width: 170, height: 190, angle: 0 },
  categories: [],
});

const front = foreheadPose(face([220, 270], [290, 270], [255, 305]), 600, 600, 600, 600);
assert.ok(front);
assert.ok(front.y + front.width * 5 / 8 < 270 - 10, "card bottom should clear the eye line");
assert.ok(front.y - front.width * 5 / 8 > 160, "card should stay on the forehead instead of floating above the hair");
assert.ok(Math.abs(front.x - 255) < 1, "card should center over both eyes");
assert.equal(front.roll, 0);

const tilted = foreheadPose(face([220, 285], [290, 255], [260, 305]), 600, 600, 600, 600);
assert.ok(tilted);
assert.ok(tilted.roll < -15, "card should rotate with head tilt");
assert.ok(tilted.x < 255 && tilted.y < 270, "card should move along the tilted forehead");

const rollOnly = foreheadPose(face([220, 285], [290, 255], [270, 305]), 600, 600, 600, 600);
assert.ok(rollOnly && Math.abs(rollOnly.yaw) < 5, "head tilt alone should not introduce a side turn");

const turned = foreheadPose(face([220, 270], [290, 270], [275, 305]), 600, 600, 600, 600);
assert.ok(turned && turned.yaw > 10, "card should turn in perspective with the face");

const cropped = foreheadPose(face([220, 270], [290, 270], [255, 305]), 600, 600, 300, 450);
assert.ok(cropped && Math.abs(cropped.x - 116.25) < 1, "object-cover crop should keep the card aligned");

const boxOnly = foreheadPose({ keypoints: [], boundingBox: face([220, 270], [290, 270], [255, 305]).boundingBox, categories: [] }, 600, 600, 600, 600);
assert.ok(boxOnly && boxOnly.y <= 215, "box fallback should sit at the top of the face");

console.log("Forehead placement, tilt, turn, crop, and fallback passed.");
