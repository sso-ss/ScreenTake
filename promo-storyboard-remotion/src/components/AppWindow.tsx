import React from "react";
import { Img, staticFile } from "remotion";
import { C, F, PRESETS } from "../lib/theme";
import { wallSrc } from "./Backdrop";
import { IAudio, ICamera, ICanvas, ICorners, ICursor, IDesktop, IFolder, IOutput, IPerson, IPhone, IRatio, IUpDown } from "./Icons";

// ScreenTake's main window, redrawn from distribution/screen-interface.png at 1:1
// (1348 × 738 window points).
export const WIN = { w: 1348, h: 738, header: 82, panelX: 980, railX: 1280 };
// Centre of the Record pill, relative to the window's top-left.
export const RECORD_PILL = { x: 1260 + 41, y: 54, w: 83, h: 25 };

export const TrafficLights: React.FC<{ active?: boolean; size?: number; gap?: number }> = ({ active = true, size = 12, gap = 8 }) => (
  <div style={{ display: "flex", gap }}>
    {(active ? [C.close, C.minimize, C.maximize] : ["#4a4a4d", "#4a4a4d", "#4a4a4d"]).map((c, i) => (
      <div key={i} style={{ width: size, height: size, borderRadius: size, background: c, boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.25)" }} />
    ))}
  </div>
);

export const RecordPill: React.FC<{ press?: number; pulse?: number; style?: React.CSSProperties }> = ({ press = 0, pulse = 0, style }) => (
  <div
    style={{
      height: 25, width: 83, borderRadius: 13, background: C.accent, display: "flex", alignItems: "center", justifyContent: "center", gap: 6,
      color: "white", fontFamily: F.sans, fontSize: 13, fontWeight: 650, letterSpacing: -0.1,
      transform: `scale(${1 - 0.06 * press})`, filter: press > 0 ? `brightness(${1 - 0.12 * press})` : undefined,
      boxShadow: `0 0 0 ${3 * pulse}px rgba(108,92,231,${0.35 * pulse})`, ...style,
    }}
  >
    <div style={{ width: 7, height: 7, borderRadius: 7, background: "white", opacity: 0.75 + 0.25 * pulse }} />
    Record
  </div>
);

const RailItem: React.FC<{ icon: React.ReactNode; label: string; on?: boolean }> = ({ icon, label, on }) => (
  <div style={{ width: 60, height: 52, borderRadius: 8, background: on ? "#3a3a3d" : "transparent", display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 5, color: on ? C.label : C.label2 }}>
    {icon}
    <div style={{ fontSize: 9.5, fontWeight: 500 }}>{label}</div>
  </div>
);

export const Swatch: React.FC<{ name: string; stops: string[]; image?: string; on?: boolean; w?: number; h?: number }> = ({ name, stops, image, on, w = 84, h = 48 }) => (
  <div style={{ width: w, display: "flex", flexDirection: "column", alignItems: "center", gap: 5 }}>
    <div
      style={{
        width: w, height: h, borderRadius: 4, overflow: "hidden", position: "relative",
        background: image ? "#111" : `linear-gradient(120deg, ${stops.join(", ")})`,
        boxShadow: on ? `0 0 0 2px ${C.accent}` : "inset 0 0 0 0.5px rgba(255,255,255,0.12)",
      }}
    >
      {image && <Img src={wallSrc(image as never)} style={{ width: "100%", height: "100%", objectFit: "cover" }} />}
    </div>
    <div style={{ fontSize: 9, color: on ? C.label : C.label3, fontWeight: on ? 700 : 500 }}>{name}</div>
  </div>
);

export const PanelSlider: React.FC<{ value: number; w?: number }> = ({ value, w = 250 }) => (
  <div style={{ position: "relative", width: w, height: 18 }}>
    <div style={{ position: "absolute", top: 7.5, left: 0, right: 0, height: 3, borderRadius: 3, background: "#48484b" }} />
    <div style={{ position: "absolute", top: 7.5, left: 0, width: value * w, height: 3, borderRadius: 3, background: C.accent }} />
    <div style={{ position: "absolute", top: 0, left: value * w - 9, width: 18, height: 18, borderRadius: 18, background: "white", boxShadow: "0 1px 3px rgba(0,0,0,0.4)" }} />
  </div>
);

/** Placeholder recording shown in the app's own preview. */
export const PreviewCanvas: React.FC<{ w: number; h: number; wall?: string }> = ({ w, h, wall = "lagoon" }) => (
  <div style={{ width: w, height: h, borderRadius: 6, overflow: "hidden", position: "relative" }}>
    <Img src={wallSrc(wall as never)} style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover" }} />
    <div style={{ position: "absolute", left: w * 0.122, top: h * 0.08, width: w * 0.756, height: h * 0.84, borderRadius: 7, background: "#232325", boxShadow: "0 12px 40px rgba(0,0,0,0.45)", overflow: "hidden" }}>
      <div style={{ height: 30, background: "#2e2e30", display: "flex", alignItems: "center", paddingLeft: 12 }}>
        <TrafficLights size={9} gap={6} />
      </div>
      {[0.45, 0.36, 0.4].map((wd, i) => (
        <div key={i} style={{ position: "absolute", left: `${50 - wd * 50}%`, top: `${48 + i * 6}%`, width: `${wd * 100}%`, height: 12, borderRadius: 6, background: "#353537" }} />
      ))}
      <div style={{ position: "absolute", left: "67%", top: "62%", width: 38, height: 38, borderRadius: 38, background: "radial-gradient(circle at 40% 35%, #9a9a9e, #4c4c50)", boxShadow: "0 0 0 1.5px rgba(255,255,255,0.85)" }} />
    </div>
    <div style={{ position: "absolute", right: -34, top: 8, width: 76, height: 76, borderRadius: 76, background: "linear-gradient(145deg, #2d3a8c, #5a2f86)", boxShadow: "0 0 0 1.5px rgba(255,255,255,0.7)", display: "flex", alignItems: "center", justifyContent: "center" }}>
      <IPerson size={30} color="#d8d8e0" />
    </div>
  </div>
);

export const AppWindow: React.FC<{
  recordPress?: number;
  recordPulse?: number;
  hideRecord?: boolean;
  wall?: string;
  children?: React.ReactNode;
}> = ({ recordPress = 0, recordPulse = 0, hideRecord, wall = "lagoon", children }) => (
  <div
    style={{
      width: WIN.w, height: WIN.h, borderRadius: 12, overflow: "hidden", position: "relative", background: "#171718",
      fontFamily: F.sans, color: C.label, boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.09)",
    }}
  >
    {/* Toolbar */}
    <div style={{ position: "absolute", left: 0, top: 0, width: WIN.w, height: WIN.header, background: "linear-gradient(#303032, #2a2a2c)", borderBottom: `1px solid ${C.separator}` }}>
      <div style={{ position: "absolute", left: 14, top: 8 }}>
        <TrafficLights />
      </div>
      <div style={{ position: "absolute", left: 12, top: 44, fontSize: 15, fontWeight: 750, letterSpacing: -0.2 }}>ScreenTake</div>
      <div style={{ position: "absolute", left: 1163, top: 42, width: 78, height: 25, borderRadius: 6, background: "#3a3a3c", display: "flex", alignItems: "center", justifyContent: "center", gap: 6, fontSize: 13, color: C.label2 }}>
        <IFolder size={13} color={C.label2} /> Import
      </div>
      {!hideRecord && (
        <div style={{ position: "absolute", left: RECORD_PILL.x - RECORD_PILL.w / 2, top: RECORD_PILL.y - RECORD_PILL.h / 2 }}>
          <RecordPill press={recordPress} pulse={recordPulse} />
        </div>
      )}
    </div>
    {/* Preview */}
    <div style={{ position: "absolute", left: 0, top: WIN.header, width: WIN.panelX, height: WIN.h - WIN.header, background: "#151516" }}>
      <div style={{ position: "absolute", left: 32, top: 58 }}>
        <PreviewCanvas w={915} h={514} wall={wall} />
      </div>
      <div style={{ position: "absolute", left: 0, width: WIN.panelX, top: 585, textAlign: "center", fontSize: 12, color: C.label3 }}>Recording Preview</div>
    </div>
    {/* Canvas panel */}
    <div style={{ position: "absolute", left: WIN.panelX, top: WIN.header, width: WIN.railX - WIN.panelX, height: WIN.h - WIN.header, background: "#262628", borderLeft: `1px solid ${C.separator}` }}>
      <div style={{ position: "absolute", left: 16, top: 16, fontSize: 13, fontWeight: 700 }}>Canvas</div>
      <div style={{ position: "absolute", left: 16, top: 44, display: "flex", alignItems: "center", gap: 8, fontSize: 13 }}>
        <IRatio size={15} color={C.label2} /> Ratio
        <div style={{ marginLeft: 2, width: 200, height: 20, borderRadius: 5, background: "#48484b", display: "flex", alignItems: "center", justifyContent: "space-between", padding: "0 5px 0 8px", boxSizing: "border-box", fontSize: 12.5 }}>
          16:9 · Widescreen <IUpDown size={11} color={C.label} />
        </div>
      </div>
      {[
        { l: "Desktop", i: <IDesktop size={20} color={C.label} />, on: true },
        { l: "iPhone", i: <IPhone size={20} color={C.label2} /> },
      ].map((t, k) => (
        <div key={k} style={{ position: "absolute", left: 16 + k * 138, top: 75, width: 130, height: 58, borderRadius: 7, background: t.on ? "#3a335f" : "#333335", boxShadow: t.on ? `inset 0 0 0 1.5px ${C.accent}` : undefined, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 6, fontSize: 11, fontWeight: 650 }}>
          {t.i}
          {t.l}
        </div>
      ))}
      <div style={{ position: "absolute", left: 16, top: 146, width: 267, display: "flex", alignItems: "center", gap: 8, fontSize: 13 }}>
        <ICorners size={15} color={C.label2} /> Corners
        <span style={{ marginLeft: "auto", fontFamily: F.mono, fontSize: 11, color: C.label2 }}>19 px</span>
      </div>
      <div style={{ position: "absolute", left: 25, top: 168 }}>
        <PanelSlider value={0.21} />
      </div>
      <div style={{ position: "absolute", left: 16, top: 208, width: 267, height: 1, background: "#343436" }} />
      <div style={{ position: "absolute", left: 16, top: 229, fontSize: 13, fontWeight: 700 }}>Background</div>
      <div style={{ position: "absolute", left: 16, top: 257, display: "grid", gridTemplateColumns: "repeat(3, 84px)", columnGap: 8, rowGap: 8 }}>
        {PRESETS.map((p) => (
          <Swatch key={p.name} {...p} on={p.name.toLowerCase() === wall} />
        ))}
      </div>
    </div>
    {/* Icon rail */}
    <div style={{ position: "absolute", left: WIN.railX, top: WIN.header, width: WIN.w - WIN.railX, height: WIN.h - WIN.header, background: "#29292b", borderLeft: `1px solid ${C.separator}`, display: "flex", flexDirection: "column", alignItems: "center", paddingTop: 11, gap: 6 }}>
      <RailItem icon={<ICanvas size={18} />} label="Canvas" on />
      <RailItem icon={<ICursor size={18} />} label="Cursor" />
      <RailItem icon={<ICamera size={18} />} label="Camera" />
      <RailItem icon={<IAudio size={18} />} label="Audio" />
      <RailItem icon={<IOutput size={18} />} label="Output" />
    </div>
    {children}
  </div>
);

export const presenterSrc = () => staticFile("images/presenter.jpg");
