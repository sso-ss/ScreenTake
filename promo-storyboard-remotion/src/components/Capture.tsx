import React from "react";
import { C, F } from "../lib/theme";
import { clamp, lerp } from "../lib/motion";
import { IDisplay, IWindow, IXCircle } from "./Icons";

// Capture toolbar, after website/assets/toolbar.png. 272 × 52.
export const TOOLBAR = { w: 272, h: 52, record: { x: 226, y: 26 } };

export const CaptureToolbar: React.FC<{ press?: number; tooltip?: number }> = ({ press = 0, tooltip = 1 }) => (
  <div style={{ width: TOOLBAR.w, height: TOOLBAR.h, position: "relative", fontFamily: F.sans }}>
    <div
      style={{
        position: "absolute", left: 38, top: -44, height: 30, padding: "0 12px", borderRadius: 8, background: "rgba(34,34,36,0.96)", color: "#f2f2f5", fontSize: 13, fontWeight: 600,
        display: "flex", alignItems: "center", opacity: tooltip, transform: `translateY(${(1 - tooltip) * 6}px)`, boxShadow: "0 6px 16px rgba(0,0,0,0.35)",
      }}
    >
      Record Entire Screen
    </div>
    <div style={{ position: "absolute", inset: 0, borderRadius: 26, background: "rgba(30,30,32,0.94)", boxShadow: "0 18px 40px rgba(0,0,0,0.45), inset 0 0 0 1px rgba(255,255,255,0.1)", display: "flex", alignItems: "center", padding: "0 8px 0 14px", gap: 10 }}>
      <IXCircle size={22} color="#8e8e93" />
      <div style={{ width: 1, height: 26, background: "rgba(255,255,255,0.12)" }} />
      <div style={{ width: 40, height: 36, borderRadius: 8, background: "#454548", display: "flex", alignItems: "center", justifyContent: "center" }}>
        <IDisplay size={20} color="#f2f2f5" />
      </div>
      <div style={{ width: 40, height: 36, borderRadius: 8, display: "flex", alignItems: "center", justifyContent: "center" }}>
        <IWindow size={20} color="#aeaeb2" />
      </div>
      <div style={{ width: 1, height: 26, background: "rgba(255,255,255,0.12)" }} />
      <div style={{ width: 80, height: 34, borderRadius: 17, background: C.systemBlue, color: "white", fontSize: 14, fontWeight: 700, display: "flex", alignItems: "center", justifyContent: "center", transform: `scale(${1 - 0.07 * press})`, filter: `brightness(${1 - 0.15 * press})` }}>
        Record
      </div>
    </div>
  </div>
);

export const Toggle: React.FC<{ on: number; scale?: number }> = ({ on, scale = 1 }) => (
  <div style={{ width: 38 * scale, height: 22 * scale, borderRadius: 11 * scale, background: on > 0.5 ? C.accent : "#48484b", position: "relative", transition: "none" }}>
    <div style={{ position: "absolute", top: 2 * scale, left: lerp(2, 18, clamp(on)) * scale, width: 18 * scale, height: 18 * scale, borderRadius: 18 * scale, background: "white", boxShadow: "0 1px 3px rgba(0,0,0,0.35)" }} />
  </div>
);

export const Segmented: React.FC<{ options: string[]; value: number; w?: number }> = ({ options, value, w = 170 }) => {
  const seg = (w - 4) / options.length;
  return (
    <div style={{ width: w, height: 26, borderRadius: 7, background: "#3a3a3d", position: "relative", fontFamily: F.sans }}>
      <div style={{ position: "absolute", top: 2, left: 2 + value * seg, width: seg, height: 22, borderRadius: 5, background: "#636366", boxShadow: "0 1px 2px rgba(0,0,0,0.3)" }} />
      <div style={{ position: "absolute", inset: 0, display: "flex", padding: "0 2px" }}>
        {options.map((o) => (
          <div key={o} style={{ width: seg, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 12, fontWeight: 600, color: C.label }}>{o}</div>
        ))}
      </div>
    </div>
  );
};

/** A settings sheet in the app's panel style. */
export const SettingsPanel: React.FC<{ title: string; w?: number; rows: { label: string; icon?: React.ReactNode; control: React.ReactNode; hi?: number }[]; tag?: string }> = ({ title, w = 340, rows, tag }) => (
  <div style={{ width: w, borderRadius: 14, background: "rgba(38,38,40,0.97)", boxShadow: "0 30px 70px rgba(0,0,0,0.55), inset 0 0 0 1px rgba(255,255,255,0.09)", fontFamily: F.sans, color: C.label, padding: "16px 18px 8px", boxSizing: "border-box" }}>
    <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
      <div style={{ fontSize: 14, fontWeight: 700 }}>{title}</div>
      {tag && <div style={{ marginLeft: "auto", fontFamily: F.mono, fontSize: 9.5, letterSpacing: 1.2, color: C.warning, border: `1px solid ${C.warning}`, borderRadius: 5, padding: "2px 6px" }}>{tag}</div>}
    </div>
    {rows.map((r, i) => (
      <div key={i} style={{ display: "flex", alignItems: "center", gap: 9, height: 44, borderTop: i ? "1px solid #343436" : undefined, fontSize: 13, position: "relative" }}>
        {r.hi !== undefined && r.hi > 0 && <div style={{ position: "absolute", left: -10, right: -10, top: 4, bottom: 4, borderRadius: 8, background: "rgba(108,92,231,0.18)", opacity: r.hi }} />}
        {r.icon && <div style={{ color: C.label2, position: "relative" }}>{r.icon}</div>}
        <div style={{ position: "relative" }}>{r.label}</div>
        <div style={{ marginLeft: "auto", position: "relative" }}>{r.control}</div>
      </div>
    ))}
  </div>
);
