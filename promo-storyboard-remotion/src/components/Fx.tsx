import React from "react";
import { AbsoluteFill } from "remotion";
import { C, F } from "../lib/theme";
import { clamp, easeOutCubic, springy } from "../lib/motion";

/**
 * Optical focus falloff: a blurred copy underneath and a sharp copy masked to a
 * radial spot or a horizontal band. Renders the children twice.
 */
export const FocusMask: React.FC<{
  amount: number;
  blur?: number;
  mode?: "spot" | "band";
  cx?: number;
  cy?: number;
  r?: number;
  angle?: number;
  band?: number;
  children: React.ReactNode;
}> = ({ amount, blur = 14, mode = "spot", cx = 50, cy = 50, r = 30, angle = 0, band = 22, children }) => {
  if (amount <= 0.01) return <>{children}</>;
  const soft = r * 1.1;
  const mask =
    mode === "spot"
      ? `radial-gradient(${r + soft}% ${(r + soft) * 1.25}% at ${cx}% ${cy}%, #000 ${(r / (r + soft)) * 100}%, transparent 100%)`
      : `linear-gradient(${180 + angle}deg, transparent ${cy - band * 2}%, #000 ${cy - band / 2}%, #000 ${cy + band / 2}%, transparent ${cy + band * 2}%)`;
  return (
    <AbsoluteFill>
      <AbsoluteFill style={{ filter: `blur(${(blur * amount).toFixed(2)}px)` }}>{children}</AbsoluteFill>
      <AbsoluteFill style={{ WebkitMaskImage: mask, maskImage: mask }}>{children}</AbsoluteFill>
    </AbsoluteFill>
  );
};

/** ScreenTake's countdown: 100 pt dark disc, 3 pt accent ring, bold rounded digit. */
export const Countdown: React.FC<{ n: number; t: number; t0: number; ring?: number }> = ({ n, t, t0, ring = 0.4 }) => {
  const s = springy(t - t0, 0.32, 0.4);
  const p = clamp((t - t0) / ring);
  const r = 48.5;
  const len = 2 * Math.PI * r;
  return (
    <div style={{ width: 100, height: 100, position: "relative", transform: `scale(${0.6 + 0.4 * s})`, opacity: clamp((t - t0) / 0.06) }}>
      <svg width={100} height={100} style={{ position: "absolute", inset: 0 }}>
        <circle cx={50} cy={50} r={49} fill="rgba(20,20,22,0.82)" />
        <circle cx={50} cy={50} r={r} fill="none" stroke="rgba(255,255,255,0.12)" strokeWidth={3} />
        <circle cx={50} cy={50} r={r} fill="none" stroke={C.accent} strokeWidth={3} strokeLinecap="round" strokeDasharray={len} strokeDashoffset={len * p} transform="rotate(-90 50 50)" />
      </svg>
      <div style={{ position: "absolute", inset: 0, display: "flex", alignItems: "center", justifyContent: "center", fontFamily: F.rounded, fontWeight: 700, fontSize: 48, color: "white", lineHeight: 1 }}>{n}</div>
    </div>
  );
};

/** Mono uppercase micro-label, used for HUD corners and state chips. */
export const Hud: React.FC<{ children: React.ReactNode; color?: string; size?: number; style?: React.CSSProperties }> = ({ children, color = "rgba(255,255,255,0.62)", size = 15, style }) => (
  <div style={{ fontFamily: F.mono, fontSize: size, letterSpacing: size * 0.14, textTransform: "uppercase", color, whiteSpace: "nowrap", ...style }}>{children}</div>
);

/** Corner ticks framing the shot, with small labels. */
export const HudFrame: React.FC<{ tl?: string; tr?: string; bl?: string; br?: string; opacity?: number; inset?: number }> = ({ tl, tr, bl, br, opacity = 1, inset = 56 }) => {
  const tick = (pos: React.CSSProperties, rot: number) => (
    <div style={{ position: "absolute", width: 22, height: 22, borderLeft: "1.5px solid rgba(255,255,255,0.45)", borderTop: "1.5px solid rgba(255,255,255,0.45)", transform: `rotate(${rot}deg)`, ...pos }} />
  );
  return (
    <AbsoluteFill style={{ opacity, pointerEvents: "none" }}>
      {tick({ left: inset, top: inset }, 0)}
      {tick({ right: inset, top: inset }, 90)}
      {tick({ right: inset, bottom: inset }, 180)}
      {tick({ left: inset, bottom: inset }, 270)}
      {tl && <Hud style={{ position: "absolute", left: inset + 34, top: inset + 2 }}>{tl}</Hud>}
      {tr && <Hud style={{ position: "absolute", right: inset + 34, top: inset + 2 }}>{tr}</Hud>}
      {bl && <Hud style={{ position: "absolute", left: inset + 34, bottom: inset + 2 }}>{bl}</Hud>}
      {br && <Hud style={{ position: "absolute", right: inset + 34, bottom: inset + 2 }}>{br}</Hud>}
    </AbsoluteFill>
  );
};

/** Quick white flash for hard cuts on the beat. */
export const Flash: React.FC<{ t: number; t0: number; dur?: number; strength?: number }> = ({ t, t0, dur = 0.18, strength = 0.35 }) => {
  const p = (t - t0) / dur;
  if (p < 0 || p > 1) return null;
  return <AbsoluteFill style={{ background: "white", opacity: strength * (1 - easeOutCubic(p)), pointerEvents: "none" }} />;
};
