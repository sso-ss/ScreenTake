import { continueRender, delayRender, staticFile } from "remotion";

// Local copies of the macOS SF faces (see scripts/setup-assets.mjs). They are not
// redistributable, so they stay out of git; if missing, the stacks in theme.ts fall back.
const FACES = [
  { family: "ST Sans", file: "fonts/SFNS.ttf" },
  { family: "ST Mono", file: "fonts/SFNSMono.ttf" },
  { family: "ST Rounded", file: "fonts/SFNSRounded.ttf" },
];

let started = false;

export function loadFonts() {
  if (started || typeof document === "undefined") return;
  started = true;
  const handle = delayRender("Loading fonts");
  Promise.all(
    FACES.map(async ({ family, file }) => {
      try {
        const face = new FontFace(family, `url(${staticFile(file)})`, { weight: "100 1000" });
        await face.load();
        document.fonts.add(face);
      } catch (error) {
        console.warn(`Font ${family} unavailable, using fallback`, error);
      }
    }),
  ).finally(() => continueRender(handle));
}
