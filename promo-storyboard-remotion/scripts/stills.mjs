// Render review stills: node scripts/stills.mjs <compositionId> <frame,frame,...> [scale]
import { bundle } from "@remotion/bundler";
import { renderStill, selectComposition } from "@remotion/renderer";
import path from "node:path";
import fs from "node:fs";

const [id, framesArg, scaleArg] = process.argv.slice(2);
const frames = framesArg.split(",").map(Number);
const out = path.resolve("out/stills");
fs.mkdirSync(out, { recursive: true });
const serveUrl = await bundle({ entryPoint: path.resolve("src/index.ts") });
const composition = await selectComposition({ serveUrl, id });
for (const frame of frames) {
  const file = path.join(out, `${id}-${frame}.png`);
  await renderStill({ serveUrl, composition, frame, output: file, scale: Number(scaleArg ?? 1), timeoutInMilliseconds: 60000 });
  console.log(file);
}
