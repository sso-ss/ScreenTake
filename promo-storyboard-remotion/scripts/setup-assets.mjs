// Copies ScreenTake's own wallpapers and app mark, the presenter photo, and the
// local macOS SF faces into public/. The ScreenTake repository is only read.
import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";

const repo = process.env.SCREENTAKE_REPO ?? new URL("../../", import.meta.url).pathname;
const out = new URL("../public/", import.meta.url).pathname;
for (const dir of ["wallpapers", "fonts", "images"]) mkdirSync(join(out, dir), { recursive: true });

// Full-resolution wallpapers (2560 × 1536) from the app's asset catalog, re-encoded as JPEG.
for (const name of ["Prism", "Lagoon", "Ember", "Midnight"]) {
  const src = join(repo, `Screen/Assets.xcassets/Wallpaper${name}.imageset/wallpaper.png`);
  const dst = join(out, "wallpapers", `${name.toLowerCase()}.jpg`);
  if (!existsSync(src)) { console.log(`wallpaper: ${src} not found`); continue; }
  execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "92", src, "--out", dst], { stdio: "ignore" });
  console.log(`wallpaper: ${name}`);
}
copyFileSync(join(repo, "website/assets/mark.svg"), join(out, "images/mark.svg"));

// Presenter photo for the webcam bubble (supplied by the user).
const presenter = new URL("../assets/webcam-presenter.png", import.meta.url).pathname;
if (existsSync(presenter)) {
  execFileSync("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "90", presenter, "--out", join(out, "images/presenter.jpg")], { stdio: "ignore" });
  console.log("presenter: ok");
}

// SF Pro, SF Mono and SF Pro Rounded ship with macOS but may not be redistributed,
// so they are copied at setup time only. Without them the CSS stacks fall back.
for (const f of ["SFNS.ttf", "SFNSMono.ttf", "SFNSRounded.ttf"]) {
  const src = join("/System/Library/Fonts", f);
  if (existsSync(src)) { copyFileSync(src, join(out, "fonts", f)); console.log(`font: ${f}`); }
}
