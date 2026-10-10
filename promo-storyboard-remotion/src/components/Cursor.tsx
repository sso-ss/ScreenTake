import React from "react";
import { CLICK_COLORS } from "../lib/theme";
import { clamp, easeOutCubic, lerp } from "../lib/motion";

export type CursorShape = "arrow" | "hand" | "circle";

const Arrow: React.FC = () => (
  <svg width={26} height={36} viewBox="0 0 26 36" style={{ display: "block", overflow: "visible" }}>
    <path d="M2 2v27.2l7.1-6.9 4.6 10.6 4.7-2-4.6-10.4h9.9z" fill="#111" stroke="white" strokeWidth={2.2} strokeLinejoin="round" />
  </svg>
);

const Hand: React.FC = () => (
  <svg width={30} height={34} viewBox="0 0 30 34" style={{ display: "block", overflow: "visible" }}>
    <path
      d="M10.2 3.2c0-1.4 1-2.2 2.2-2.2s2.2.8 2.2 2.2v9.3c.4-.9 1.3-1.4 2.3-1.3 1.2.1 2 1 2 2.3v1c.4-.8 1.3-1.2 2.2-1.1 1.2.1 1.9 1 1.9 2.2v1.2c.4-.7 1.2-1 2-.9 1.1.2 1.8 1 1.8 2.3v5.6c0 5.5-3.7 9.2-8.8 9.2h-2.5c-3 0-5.1-1.3-6.8-3.7L3 20.6c-.7-1-.5-2.3.4-3 .9-.7 2.2-.6 3 .3l3.8 4.2z"
      fill="white" stroke="#111" strokeWidth={1.7} strokeLinejoin="round"
    />
    <path d="M14.6 13.5v6M18.9 14.6v5.2M23 16v4" stroke="#111" strokeWidth={1.4} strokeLinecap="round" />
  </svg>
);

const Circle: React.FC = () => (
  <div style={{ width: 34, height: 34, borderRadius: 34, background: "radial-gradient(circle at 38% 32%, #a9a9ae, #505055 75%)", boxShadow: "0 0 0 1.8px rgba(255,255,255,0.92), 0 3px 8px rgba(0,0,0,0.35)" }} />
);

// Hotspot offsets in cursor-local px (tip of the arrow, tip of the finger, circle centre).
const HOT: Record<CursorShape, [number, number]> = { arrow: [2, 2], hand: [12, 1], circle: [17, 17] };

/**
 * Pointer placed with its hotspot at (x, y). `morph` crossfades from `from`
 * to `shape` with a springy scale pop; `press` squeezes it during a click.
 */
export const Cursor: React.FC<{
  x: number;
  y: number;
  shape?: CursorShape;
  from?: CursorShape;
  morph?: number;
  scale?: number;
  press?: number;
  opacity?: number;
  shadow?: boolean;
}> = ({ x, y, shape = "arrow", from, morph = 1, scale = 1, press = 0, opacity = 1, shadow = true }) => {
  const layers: { s: CursorShape; o: number; k: number }[] = [];
  if (from && morph < 1) layers.push({ s: from, o: 1 - clamp(morph * 1.6), k: lerp(1, 0.6, morph) });
  layers.push({ s: shape, o: from ? clamp(morph * 1.6 - 0.2) : 1, k: from ? lerp(0.6, 1, morph) : 1 });
  const s = scale * (1 - 0.14 * press);
  return (
    <div style={{ position: "absolute", left: x, top: y, width: 0, height: 0, opacity }}>
      {layers.map(({ s: sh, o, k }) => {
        const [hx, hy] = HOT[sh];
        return (
          <div
            key={sh}
            style={{
              position: "absolute", left: -hx, top: -hy, opacity: o, transformOrigin: `${hx}px ${hy}px`, transform: `scale(${s * k})`,
              filter: shadow ? "drop-shadow(0 4px 6px rgba(0,0,0,0.35))" : undefined,
            }}
          >
            {sh === "arrow" ? <Arrow /> : sh === "hand" ? <Hand /> : <Circle />}
          </div>
        );
      })}
    </div>
  );
};

/** Click highlight: a filled flash and an expanding ring in the chosen colour. */
export const ClickRing: React.FC<{ x: number; y: number; t: number; t0: number; color?: string; size?: number; dur?: number }> = ({
  x, y, t, t0, color = CLICK_COLORS[0].color, size = 90, dur = 0.55,
}) => {
  const p = (t - t0) / dur;
  if (p < 0 || p > 1) return null;
  const e = easeOutCubic(p);
  const d = lerp(size * 0.25, size, e);
  return (
    <div style={{ position: "absolute", left: x, top: y, width: 0, height: 0 }}>
      <div style={{ position: "absolute", left: -d / 2, top: -d / 2, width: d, height: d, borderRadius: d, background: color, opacity: 0.35 * (1 - e) }} />
      <div style={{ position: "absolute", left: -d / 2, top: -d / 2, width: d, height: d, borderRadius: d, boxShadow: `inset 0 0 0 ${lerp(5, 1.5, e)}px ${color}`, opacity: 1 - p * p }} />
    </div>
  );
};

/** Position along a glide path with ScreenTake-like smoothing (ease in-out, slight arc). */
export const glide = (p: number, a: [number, number], b: [number, number], arcPx = 40): [number, number] => {
  const e = p <= 0 ? 0 : p >= 1 ? 1 : p < 0.5 ? 4 * p * p * p : 1 - (-2 * p + 2) ** 3 / 2;
  const nx = -(b[1] - a[1]);
  const ny = b[0] - a[0];
  const len = Math.hypot(nx, ny) || 1;
  const bow = Math.sin(Math.PI * e) * arcPx;
  return [lerp(a[0], b[0], e) + (nx / len) * bow, lerp(a[1], b[1], e) + (ny / len) * bow];
};
