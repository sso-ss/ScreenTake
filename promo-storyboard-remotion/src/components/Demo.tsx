import React from "react";
import { Img } from "remotion";
import { C, F, type Wall } from "../lib/theme";
import { wallSrc } from "./Backdrop";
import { presenterSrc } from "./AppWindow";
import { Plane, Space, zoomToDolly } from "./Space";

// The walkthrough page being recorded, after website/assets/demo-scene.svg (960 × 600).
export const DEMO = {
  w: 960,
  h: 600,
  cta: { x: 177, y: 336 },
  play: { x: 772, y: 228 },
  cards: [
    { x: 177, y: 478 },
    { x: 480, y: 478 },
    { x: 783, y: 478 },
  ],
};

const CARDS = [
  ["01 / THE IDEA", "Start with why.", "Set the scene"],
  ["02 / THE DETAILS", "Show what’s new.", "Walk through the work"],
  ["03 / NEXT STEPS", "Make it happen.", "Share the next move"],
];

export const DemoPage: React.FC<{ ctaPress?: number; cardPress?: number[]; cardLift?: number[] }> = ({ ctaPress = 0, cardPress = [], cardLift = [] }) => (
  <div style={{ width: DEMO.w, height: DEMO.h, position: "relative", background: "#faf8ff", fontFamily: F.sans, color: "#302244", overflow: "hidden" }}>
    <div style={{ position: "absolute", left: 0, top: 0, width: DEMO.w, height: 62, background: "white", borderBottom: "1px solid #eee8f7", display: "flex", alignItems: "center" }}>
      <div style={{ display: "flex", gap: 8, marginLeft: 25 }}>
        {["#fd8c87", "#edca71", "#83c9a2"].map((c) => (
          <div key={c} style={{ width: 14, height: 14, borderRadius: 14, background: c }} />
        ))}
      </div>
      <div style={{ marginLeft: 40, fontSize: 21, fontWeight: 700, letterSpacing: -0.3 }}>Your next big idea</div>
      <div style={{ marginLeft: "auto", marginRight: 28, display: "flex", gap: 10 }}>
        {[64, 48].map((w, i) => (
          <div key={i} style={{ width: w, height: 10, borderRadius: 5, background: i ? "#e6def3" : "#b3a1e7" }} />
        ))}
      </div>
    </div>
    <div style={{ position: "absolute", left: 40, top: 102, width: 880, height: 272, borderRadius: 20, background: "linear-gradient(135deg, #ebe4ff, #c5b1ee)" }}>
      <div style={{ position: "absolute", left: 32, top: 30, fontSize: 16, letterSpacing: 2.4, color: "#60419a", fontWeight: 600 }}>PROJECT OVERVIEW</div>
      <div style={{ position: "absolute", left: 32, top: 58, fontSize: 46, fontWeight: 800, letterSpacing: -1.4, lineHeight: 1.06 }}>
        Make something
        <br />
        worth sharing.
      </div>
      <div style={{ position: "absolute", left: 32, top: 176, fontSize: 19, color: "#59496f" }}>A short walkthrough of our next release.</div>
      <div
        style={{
          position: "absolute", left: 32, top: 212, height: 44, width: 210, borderRadius: 22, background: "#7454c4", color: "white", fontSize: 17, fontWeight: 700,
          display: "flex", alignItems: "center", justifyContent: "center", gap: 8, transform: `scale(${1 - 0.07 * ctaPress})`, boxShadow: `0 8px 20px rgba(116,84,196,${0.35 - 0.2 * ctaPress})`,
        }}
      >
        Let’s take a look →
      </div>
      <div style={{ position: "absolute", left: 657, top: 51, width: 151, height: 151, borderRadius: 36, background: "#7454c4", boxShadow: "0 20px 40px rgba(96,65,154,0.35)" }}>
        <svg width={151} height={151} viewBox="0 0 151 151">
          <path d="m61 40 51 35.5-51 35.5z" fill="white" />
        </svg>
      </div>
    </div>
    {CARDS.map(([a, b, c], i) => (
      <div
        key={i}
        style={{
          position: "absolute", left: 40 + i * 303, top: 402, width: 274, height: 153, borderRadius: 16, background: "white", boxShadow: `inset 0 0 0 1.5px #e1d8ef, 0 ${6 + 18 * (cardLift[i] ?? 0)}px ${14 + 30 * (cardLift[i] ?? 0)}px rgba(48,34,68,${0.05 + 0.12 * (cardLift[i] ?? 0)})`,
          transform: `translateY(${-8 * (cardLift[i] ?? 0)}px) scale(${1 - 0.04 * (cardPress[i] ?? 0)})`,
        }}
      >
        <div style={{ position: "absolute", left: 24, top: 22, fontSize: 16, color: "#7655ab", letterSpacing: 1.2, fontWeight: 600 }}>{a}</div>
        <div style={{ position: "absolute", left: 24, top: 56, fontSize: 25, fontWeight: 750, letterSpacing: -0.5 }}>{b}</div>
        <div style={{ position: "absolute", left: 24, top: 100, fontSize: 18, color: "#675975" }}>{c}</div>
      </div>
    ))}
  </div>
);

/** Phone-sized version of the same page, for the iPhone framing. */
export const DemoMobile: React.FC = () => (
  <div style={{ width: 390, height: 844, background: "#faf8ff", fontFamily: F.sans, color: "#302244", position: "relative", overflow: "hidden" }}>
    <div style={{ position: "absolute", left: 20, top: 70, right: 20, height: 330, borderRadius: 26, background: "linear-gradient(135deg, #ebe4ff, #c5b1ee)", padding: 26, boxSizing: "border-box" }}>
      <div style={{ fontSize: 13, letterSpacing: 2, color: "#60419a", fontWeight: 600 }}>PROJECT OVERVIEW</div>
      <div style={{ fontSize: 38, fontWeight: 800, letterSpacing: -1.2, lineHeight: 1.05, marginTop: 14 }}>Make something worth sharing.</div>
      <div style={{ marginTop: 26, height: 46, width: 200, borderRadius: 23, background: "#7454c4", color: "white", fontSize: 16, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center" }}>Let’s take a look →</div>
    </div>
    {CARDS.map(([a, b], i) => (
      <div key={i} style={{ position: "absolute", left: 20, right: 20, top: 424 + i * 124, height: 108, borderRadius: 18, background: "white", boxShadow: "inset 0 0 0 1.5px #e1d8ef", padding: "18px 22px", boxSizing: "border-box" }}>
        <div style={{ fontSize: 13, color: "#7655ab", letterSpacing: 1, fontWeight: 600 }}>{a}</div>
        <div style={{ fontSize: 23, fontWeight: 750, marginTop: 10, letterSpacing: -0.4 }}>{b}</div>
      </div>
    ))}
  </div>
);

/**
 * ScreenTake's output canvas: wallpaper, the recording inset with rounded
 * corners, optional webcam bubble. `inner` zooms the recording (auto zoom).
 */
export const Canvas: React.FC<{
  w: number;
  h: number;
  wall: Wall;
  radius?: number;
  corners?: number;
  pad?: number;
  zoom?: number;
  focus?: { x: number; y: number };
  content?: React.ReactNode;
  contentW?: number;
  contentH?: number;
  overlay?: React.ReactNode;
  children?: React.ReactNode;
}> = ({ w, h, wall, radius = 18, corners = 14, pad = 0.075, zoom = 1, focus, content, contentW = DEMO.w, contentH = DEMO.h, overlay, children }) => {
  const fit = Math.min((w * (1 - pad * 2)) / contentW, (h * (1 - pad * 2)) / contentH);
  const cw = contentW * fit;
  const ch = contentH * fit;
  const f = focus ?? { x: contentW / 2, y: contentH / 2 };
  // Zoom about the focus point, clamped so the recording never shows its own edge.
  const tx = Math.min(0, Math.max(cw - cw * zoom, cw / 2 - f.x * fit * zoom));
  const ty = Math.min(0, Math.max(ch - ch * zoom, ch / 2 - f.y * fit * zoom));
  const zx = zoom === 1 ? 0 : tx;
  const zy = zoom === 1 ? 0 : ty;
  return (
    <div style={{ width: w, height: h, borderRadius: radius, overflow: "hidden", position: "relative", background: "#111" }}>
      <Img src={wallSrc(wall)} style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover" }} />
      <div style={{ position: "absolute", left: (w - cw) / 2, top: (h - ch) / 2, width: cw, height: ch, borderRadius: corners, overflow: "hidden", boxShadow: "0 24px 60px rgba(0,0,0,0.38), 0 0 0 1px rgba(0,0,0,0.08)" }}>
        <div style={{ position: "absolute", left: 0, top: 0, width: contentW, height: contentH, transformOrigin: "0 0", transform: `scale(${fit})` }}>
          <Space perspective={1200} camera={{ x: (cw / 2 - zx) / (fit * zoom) - contentW / 2, y: (ch / 2 - zy) / (fit * zoom) - contentH / 2, dolly: zoomToDolly(zoom, 1200), focus: 0, aperture: 0.3 }}>
            <Plane w={contentW} h={contentH} sharp>{content ?? <DemoPage />}</Plane>
            {children && <Plane w={contentW} h={contentH} z={6} sharp>{children}</Plane>}
          </Space>
        </div>
      </div>
      {overlay}
    </div>
  );
};

/** Convert content coordinates to canvas coordinates for a given Canvas config. */
export function canvasPoint(p: { x: number; y: number }, o: { w: number; h: number; pad?: number; zoom?: number; focus?: { x: number; y: number }; contentW?: number; contentH?: number }) {
  const { w, h, pad = 0.075, zoom = 1, contentW = DEMO.w, contentH = DEMO.h } = o;
  const fit = Math.min((w * (1 - pad * 2)) / contentW, (h * (1 - pad * 2)) / contentH);
  const cw = contentW * fit;
  const ch = contentH * fit;
  const f = o.focus ?? { x: contentW / 2, y: contentH / 2 };
  const tx = zoom === 1 ? 0 : Math.min(0, Math.max(cw - cw * zoom, cw / 2 - f.x * fit * zoom));
  const ty = zoom === 1 ? 0 : Math.min(0, Math.max(ch - ch * zoom, ch / 2 - f.y * fit * zoom));
  return { x: (w - cw) / 2 + tx + p.x * fit * zoom, y: (h - ch) / 2 + ty + p.y * fit * zoom };
}

/** Webcam overlay with the presenter. `shape` 0 = circle, 1 = rounded square. */
export const Bubble: React.FC<{ size: number; shape?: number; mirror?: number; ring?: string }> = ({ size, shape = 0, mirror = 0, ring = "rgba(255,255,255,0.85)" }) => {
  const r = size / 2 - shape * (size / 2 - size * 0.22);
  return (
    <div style={{ width: size, height: size, borderRadius: r, overflow: "hidden", position: "relative", boxShadow: `0 0 0 ${size * 0.014}px ${ring}` , background: "#222" }}>
      <Img src={presenterSrc()} style={{ width: "100%", height: "100%", objectFit: "cover", transformOrigin: "44% 36%", transform: `scaleX(${1 - 2 * mirror}) scale(1.7)` }} />
    </div>
  );
};

export const PhoneFrame: React.FC<{ h: number; children: React.ReactNode }> = ({ h, children }) => {
  const k = h / 844;
  return (
    <div style={{ width: 390 * k + 24 * k, height: h + 24 * k, borderRadius: 62 * k, background: "#0d0d0f", boxShadow: `inset 0 0 0 ${2 * k}px #3a3a3e, 0 30px 70px rgba(0,0,0,0.5)`, position: "relative" }}>
      <div style={{ position: "absolute", left: 12 * k, top: 12 * k, width: 390 * k, height: h, borderRadius: 50 * k, overflow: "hidden" }}>
        <div style={{ width: 390, height: 844, transform: `scale(${k})`, transformOrigin: "0 0" }}>{children}</div>
      </div>
      <div style={{ position: "absolute", left: "50%", top: 22 * k, width: 120 * k, height: 34 * k, marginLeft: -60 * k, borderRadius: 20 * k, background: "#000" }} />
    </div>
  );
};

export { C };
