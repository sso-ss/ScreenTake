// Render every scene as its own clip: node scripts/render-clips.mjs [wide|tall|all]
import { execSync } from "node:child_process";
import { readFileSync, mkdirSync } from "node:fs";

const tl = JSON.parse(readFileSync(new URL("../src/lib/timeline.json", import.meta.url)));
const which = process.argv[2] ?? "all";
mkdirSync("out/clips", { recursive: true });
const jobs = [];
if (which !== "tall") for (const s of tl.scenes) jobs.push([`Scene-${s.id}-${s.name}`, `out/clips/${s.id}-${s.name}.mp4`]);
if (which !== "wide") for (const id of tl.vertical) {
  const s = tl.scenes.find((x) => x.id === id);
  jobs.push([`Tall-${s.id}-${s.name}`, `out/clips/tall-${s.id}-${s.name}.mp4`]);
}
for (const [comp, out] of jobs) {
  console.log(`→ ${comp}`);
  execSync(`npx remotion render src/index.ts ${comp} ${out} --log=error`, { stdio: "inherit" });
}
