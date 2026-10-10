import React from "react";
import { C, F } from "../lib/theme";
import { clamp, easeInCubic, easeOutCubic, easeOutExpo, lerp, prog } from "../lib/motion";

export type Word = string | { text: string; color?: string };

/**
 * 2D caption: each word rises out of a mask with a short stagger, then the
 * whole block leaves by blurring back. Lines are arrays of words.
 */
export const Caption: React.FC<{
  lines: Word[][];
  t: number;
  t0: number;
  t1?: number;
  size?: number;
  color?: string;
  weight?: number;
  align?: "left" | "center" | "right";
  stagger?: number;
  tracking?: number;
  lineHeight?: number;
  style?: React.CSSProperties;
}> = ({ lines, t, t0, t1 = 99, size = 96, color = C.label, weight = 700, align = "center", stagger = 0.05, tracking = -0.035, lineHeight = 1.04, style }) => {
  const out = easeInCubic(prog(t, t1, 0.25));
  if (t < t0 || out >= 1) return null;
  let n = 0;
  return (
    <div style={{ fontFamily: F.sans, fontSize: size, fontWeight: weight, letterSpacing: `${tracking}em`, lineHeight, color, textAlign: align, opacity: 1 - out, filter: out > 0 ? `blur(${out * 12}px)` : undefined, transform: `translateY(${-30 * out}px)`, ...style }}>
      {lines.map((line, li) => (
        <div key={li} style={{ display: "flex", justifyContent: align === "center" ? "center" : align === "right" ? "flex-end" : "flex-start", gap: `0 ${size * 0.24}px`, flexWrap: "wrap" }}>
          {line.map((w, wi) => {
            const word = typeof w === "string" ? { text: w } : w;
            const p = easeOutExpo(prog(t, t0 + n++ * stagger, 0.6));
            return (
              <span key={wi} style={{ display: "inline-block", overflow: "hidden", paddingBottom: size * 0.14, marginBottom: -size * 0.14 }}>
                <span style={{ display: "inline-block", transform: `translateY(${(1 - p) * 105}%)`, color: word.color, opacity: clamp(p * 3) }}>{word.text}</span>
              </span>
            );
          })}
        </div>
      ))}
    </div>
  );
};

/**
 * Letters that fly in from depth. Must sit inside a preserve-3d parent (Group).
 * Rendered at `k`× and scaled down so glyphs stay sharp near the camera.
 */
export const FlyText: React.FC<{
  text: string;
  t: number;
  t0: number;
  size?: number;
  color?: string;
  weight?: number;
  from?: number;
  stagger?: number;
  dur?: number;
  font?: string;
  tracking?: number;
  k?: number;
  out?: number;
}> = ({ text, t, t0, size = 150, color = C.label, weight = 750, from = 700, stagger = 0.03, dur = 0.7, font = F.sans, tracking = -0.04, k = 2, out = 0 }) => {
  const chars = [...text];
  return (
    <div style={{ position: "absolute", left: 0, top: 0, transformStyle: "preserve-3d", transform: `scale3d(${1 / k},${1 / k},${1 / k})` }}>
      <div style={{ position: "absolute", left: 0, top: 0, transformStyle: "preserve-3d", transform: "translate(-50%, -50%)", display: "flex", whiteSpace: "pre", fontFamily: font, fontSize: size * k, fontWeight: weight, letterSpacing: `${tracking}em`, color, lineHeight: 1 }}>
        {chars.map((ch, i) => {
          const p = easeOutExpo(prog(t, t0 + i * stagger, dur));
          const o = clamp(prog(t, t0 + i * stagger, dur * 0.35));
          const z = lerp(from, 0, p) * k + out * k;
          const b = (1 - p) * 10 * k;
          return (
            <span key={i} style={{ display: "inline-block", transform: `translate3d(0, ${(1 - p) * 40 * k}px, ${z}px) rotateX(${(1 - p) * -40}deg)`, opacity: o, filter: b > 0.3 ? `blur(${b}px)` : undefined }}>
              {ch}
            </span>
          );
        })}
      </div>
    </div>
  );
};

/** Bold uppercase title card line with chunked reveal (Rive-style). */
export const CardTitle: React.FC<{ lines: string[]; t: number; starts: number[]; size?: number; color?: string; accent?: number }> = ({ lines, t, starts, size = 132, color = "white", accent }) => (
  <div style={{ fontFamily: F.sans, fontWeight: 850, fontSize: size, letterSpacing: "0.01em", lineHeight: 0.98, textTransform: "uppercase", color, textAlign: "center" }}>
    {lines.map((l, i) => {
      const p = easeOutCubic(prog(t, starts[i], 0.18));
      return (
        <div key={i} style={{ opacity: t >= starts[i] ? 1 : 0, transform: `translateY(${(1 - p) * 18}px)`, color: accent === i ? C.accentLight : undefined }}>
          {l}
        </div>
      );
    })}
  </div>
);
