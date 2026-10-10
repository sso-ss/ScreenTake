import React from "react";
import { AbsoluteFill, Img } from "remotion";
import { Backdrop, wallSrc } from "../components/Backdrop";
import { ClickRing, Cursor } from "../components/Cursor";
import { Bubble, Canvas } from "../components/Demo";
import { FocusMask } from "../components/Fx";
import { ICheck, IChevL, IChevR, IClose, IMinus, IPlay, IPlus, IScissors, ISilence, ISkipBack, ISkipFwd, ITrash, IUndo } from "../components/Icons";
import { Plane, Space } from "../components/Space";
import { Caption } from "../components/Type";
import { C, F, type Wall } from "../lib/theme";
import { clamp, easeInOutCubic, easeOutCubic, easeOutExpo, keys, lerp, prog, springy } from "../lib/motion";
import { cues, useTime } from "../lib/time";

// 30.4–37.6 s. One continuous take across the editor, laid back like a sheet
// on a desk: split, drag to reorder, review and remove two pauses, then undo.
// The camera finally rises to the preview.
const T = cues("s07");
const W = 1600;
const H = 1000;
const X0 = 100;
const PPS = 280;
const ROW = { y: 720, h: 56 };
const RULER = 800;
const TRACK = { y: 842, h: 118 };
const SPLIT_AT = 1.8;
const PAUSES: [number, number][] = [
  [1.1, 1.6],
  [3.4, 3.9],
];
const CYAN = "#22d3ee";
const WALLS: Wall[] = ["prism", "lagoon", "ember", "midnight"];
const tx = (s: number) => X0 + s * PPS;
/** Sheet-local point to world. */
const wp = (x: number, y: number) => ({ x: x - W / 2, y: y - H / 2 });

const BTN = {
  split: { x: 108, y: ROW.y + 28 },
  silence: { x: 262, y: ROW.y + 28 },
  undo: { x: 394, y: ROW.y + 28 },
  remove2: { x: 1175, y: ROW.y - 38 },
};

/** A strip of the recording between two source times. */
export const Strip: React.FC<{ s0: number; s1: number; w: number; selected?: number; lifted?: number }> = ({ s0, s1, w, selected = 0, lifted = 0 }) => {
  const tiles = Math.max(1, Math.ceil(w / 74));
  const bars = Math.max(2, Math.floor(w / 6));
  return (
    <div style={{ width: w, height: TRACK.h, borderRadius: 12, overflow: "hidden", position: "relative", background: "#141417", boxShadow: `0 0 0 ${2 + selected}px ${selected > 0.5 ? C.accent : "rgba(255,255,255,0.1)"}, 0 ${10 + 30 * lifted}px ${20 + 50 * lifted}px rgba(0,0,0,${0.3 + 0.3 * lifted})` }}>
      <div style={{ position: "absolute", left: 0, top: 0, height: 80, display: "flex" }}>
        {Array.from({ length: tiles }, (_, i) => {
          const src = s0 + ((i + 0.5) / tiles) * (s1 - s0);
          return (
            <div key={i} style={{ width: 74, height: 80, flexShrink: 0, borderRight: "1px solid rgba(0,0,0,0.35)", position: "relative", overflow: "hidden" }}>
              <Img src={wallSrc(WALLS[Math.min(3, Math.floor(src / 1.25))])} style={{ width: "100%", height: "100%", objectFit: "cover" }} />
              <div style={{ position: "absolute", left: 12, top: 14, right: 12, bottom: 12, borderRadius: 4, background: "rgba(245,245,250,0.9)" }} />
            </div>
          );
        })}
      </div>
      <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, height: 38, background: "rgba(34,211,238,0.1)", display: "flex", alignItems: "center", gap: 2, padding: "0 6px", boxSizing: "border-box" }}>
        {Array.from({ length: bars }, (_, i) => {
          const src = s0 + (i / bars) * (s1 - s0);
          const quiet = PAUSES.some(([p0, p1]) => src > p0 && src < p1);
          const v = quiet ? 0.06 : Math.abs(Math.sin(src * 13.1) * Math.sin(src * 3.7 + 1)) * 0.85 + 0.12;
          return <div key={i} style={{ flex: 1, height: 30 * v, borderRadius: 2, background: CYAN, opacity: 0.85 }} />;
        })}
      </div>
      {selected > 0 && (
        <>
          <div style={{ position: "absolute", left: 0, top: 0, bottom: 0, width: 12, background: C.accent, opacity: selected, borderRadius: "12px 0 0 12px" }} />
          <div style={{ position: "absolute", right: 0, top: 0, bottom: 0, width: 12, background: C.accent, opacity: selected, borderRadius: "0 12px 12px 0" }} />
        </>
      )}
    </div>
  );
};

const Btn: React.FC<{ icon: React.ReactNode; label?: string; press?: number; w?: number; tint?: string }> = ({ icon, label, press = 0, w, tint }) => (
  <div style={{ height: 40, width: w, padding: label ? "0 14px" : 0, borderRadius: 10, display: "flex", alignItems: "center", justifyContent: "center", gap: 8, background: press > 0 ? `rgba(108,92,231,${0.25 + 0.4 * press})` : "#2a2a2d", color: tint ?? C.label, fontSize: 15, fontWeight: 600, boxSizing: "border-box", transform: `scale(${1 - 0.06 * press})`, boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.06)" }}>
    {icon}
    {label && <span>{label}</span>}
  </div>
);

const fmt = (s: number) => `00:0${Math.max(0, s).toFixed(1)}`;

/** Timeline layout at time t: segments in source time with their timeline start. */
const layout = (t: number) => {
  const split = t >= T.split;
  const drag = easeInOutCubic(prog(t, T.lift + 0.1, T.drop - T.lift - 0.2));
  const undo = easeInOutCubic(prog(t, T.undo, 0.4));
  const moved = drag;
  const swap = easeInOutCubic(prog(moved, 0.3, 0.5));
  const r = easeInOutCubic(prog(t, T.close, 0.5)) * (1 - undo);
  const lift = t >= T.lift && t < T.drop + 0.2 ? springy(t - T.lift, 0.3, 0.3) * (1 - easeOutCubic(prog(t, T.drop - 0.05, 0.25))) : 0;
  // Reordering keeps source spans intact. Removal collapses pauses in their new timeline order.
  const sourceAt = (s: number) => s >= SPLIT_AT ? s - SPLIT_AT : 5 - SPLIT_AT + s;
  const cut = (s: number) => {
    const at = sourceAt(s);
    return PAUSES.reduce((a, [p0, p1]) => a + clamp(at - sourceAt(p0), 0, p1 - p0), 0) * r;
  };
  return { split, moved, swap, r, lift, cut, sourceAt };
};

const Sheet: React.FC<{ t: number }> = ({ t }) => {
  const L = layout(t);
  const detect = (i: number) => easeOutExpo(prog(t, T.detect + i * 0.14, 0.4)) * (1 - easeInOutCubic(prog(t, T.undo, 0.2)));
  const barIn = easeOutExpo(prog(t, T.detect + 0.2, 0.35)) * (1 - easeInOutCubic(prog(t, T.remove + 0.15, 0.3)));
  const dur = 5 - 1 * L.r;
  const head = keys(t, [[0, 0.5], [T.split - 0.08, SPLIT_AT], [T.close, SPLIT_AT], [T.close + 0.5, 0.3], [7.2, 0.3 + (7.2 - T.close - 0.5)]], easeInOutCubic);
  const press = (t0: number) => clamp(1 - Math.abs(t - t0 - 0.03) / 0.12);
  const a1 = { s0: 0, s1: SPLIT_AT };
  const a2 = { s0: SPLIT_AT, s1: 5 };
  // Before the removal, whole clips; after, the four kept pieces slide together.
  const pieces: { s0: number; s1: number; at: number; key: string; sel?: number }[] = [];
  if (!L.split) pieces.push({ s0: 0, s1: 5, at: 0, key: "a" });
  else if (L.r <= 0) {
    pieces.push({ s0: a2.s0, s1: a2.s1, at: lerp(SPLIT_AT, 0, L.swap), key: "a2" });
    if (L.lift <= 0.001) pieces.push({ s0: a1.s0, s1: a1.s1, at: lerp(0, 5 - SPLIT_AT, L.moved), key: "a1", sel: clamp((t - T.split) / 0.15) * (1 - clamp((t - T.silence) / 0.2)) });
  } else {
    const keep: [number, number][] = [[1.8, 3.4], [3.9, 5], [0, 1.1], [1.6, 1.8]];
    keep.forEach(([s0, s1], i) => pieces.push({ s0, s1, at: L.sourceAt(s0) - L.cut(s0), key: `k${i}` }));
  }
  return (
    <div style={{ width: W, height: H, borderRadius: 26, background: "#1b1b1e", position: "relative", fontFamily: F.sans, color: C.label, boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.07)" }}>
      <div style={{ position: "absolute", left: 280, top: 36 }}>
        <Canvas w={1040} h={585} wall={WALLS[Math.min(3, Math.floor(head / 1.25))]} radius={14} corners={12} overlay={<div style={{position:"absolute",right:36,top:36}}><Bubble size={145} shape={1} mirror={1} /></div>} />
      </div>
      {/* Transport */}
      <div style={{ position: "absolute", left: 60, top: ROW.y + 8, display: "flex", gap: 10 }}>
        <Btn icon={<IScissors size={17} />} label="Split" press={press(T.split)} />
        <Btn icon={<ISilence size={17} />} label="Remove Silence" press={press(T.silence)} />
        <Btn icon={<ITrash size={17} />} w={40} />
        <Btn icon={<IUndo size={17} />} w={40} press={press(T.undo)} />
      </div>
      <div style={{ position: "absolute", left: 640, top: ROW.y + 8, display: "flex", gap: 10, alignItems: "center" }}>
        <Btn icon={<ISkipBack size={17} />} w={40} />
        <Btn icon={<IPlay size={17} />} w={52} tint="white" />
        <Btn icon={<ISkipFwd size={17} />} w={40} />
        <div style={{ fontFamily: F.mono, fontSize: 17, marginLeft: 12, color: C.label2, fontVariantNumeric: "tabular-nums" }}>
          <span style={{ color: "white" }}>{fmt(head)}</span> / <span style={{ color: L.r > 0 ? C.accentLight : C.label2 }}>{fmt(dur)}</span>
        </div>
      </div>
      <div style={{ position: "absolute", right: 60, top: ROW.y + 8, display: "flex", gap: 10 }}>
        <Btn icon={<IMinus size={17} />} w={40} />
        <Btn icon={<IPlus size={17} />} w={40} />
        <Btn icon={null} label="Fit" />
      </div>
      {/* Ruler */}
      {Array.from({ length: 11 }, (_, i) => (
        <div key={i} style={{ position: "absolute", left: tx(i * 0.5), top: RULER, height: i % 2 ? 8 : 14, width: 1.5, background: "rgba(255,255,255,0.3)" }}>
          {i % 2 === 0 && <div style={{ position: "absolute", left: 6, top: -4, fontFamily: F.mono, fontSize: 13, color: C.label3 }}>{i / 2}s</div>}
        </div>
      ))}
      {/* Track */}
      {pieces.map((p) => (
        <div key={p.key} style={{ position: "absolute", left: tx(p.at), top: TRACK.y }}>
          <Strip s0={p.s0} s1={p.s1} w={(p.s1 - p.s0) * PPS - 4} selected={p.sel} />
        </div>
      ))}
      {/* Detected pauses (reviewed) */}
      {L.split &&
        PAUSES.map(([p0, p1], i) => {
          const d = detect(i);
          if (d <= 0) return null;
          const at = L.sourceAt(p0) - L.cut(p0);
          const w = (p1 - p0) * (1 - L.r) * PPS;
          return (
            <div key={i} style={{ position: "absolute", left: tx(at), top: TRACK.y - 8, width: w, height: TRACK.h + 16, borderRadius: 10, background: `rgba(245,158,11,${0.28 * d})`, boxShadow: `inset 0 0 0 2px rgba(245,158,11,${d})`, opacity: 1 - clamp((L.r - 0.7) / 0.3) }}>
              <div style={{ position: "absolute", left: "50%", top: -22, width: 30, height: 30, marginLeft: -15, borderRadius: 30, background: C.warning, display: "flex", alignItems: "center", justifyContent: "center", transform: `scale(${springy(t - T.detect - 0.2 - i * 0.14, 0.3, 0.4)})` }}>
                <ICheck size={18} color="#1b1b1e" stroke={3} />
              </div>
            </div>
          );
        })}
      {/* Playhead */}
      <div style={{ position: "absolute", left: tx(head) - 1, top: RULER - 6, width: 3, height: TRACK.y + TRACK.h - RULER + 20, background: "white", borderRadius: 2, boxShadow: "0 0 12px rgba(255,255,255,0.4)" }}>
        <div style={{ position: "absolute", left: -8, top: -10, width: 19, height: 14, borderRadius: 4, background: "white" }} />
      </div>
      {/* Pause review bar */}
      {barIn > 0.01 && (
        <div style={{ position: "absolute", left: 700, top: ROW.y - 64, width: 560, height: 52, borderRadius: 14, background: "#2c2c30", boxShadow: "0 20px 50px rgba(0,0,0,0.5), inset 0 0 0 1px rgba(245,158,11,0.5)", display: "flex", alignItems: "center", gap: 12, padding: "0 10px 0 16px", boxSizing: "border-box", opacity: barIn, transform: `translateY(${(1 - barIn) * 16}px)`, fontSize: 15 }}>
          <div style={{ width: 10, height: 10, borderRadius: 10, background: C.warning }} />
          <div style={{ fontWeight: 700 }}>2 pauses</div>
          <IChevL size={16} color={C.label2} />
          <IChevR size={16} color={C.label2} />
          <IPlay size={15} color={C.label2} />
          <div style={{ display: "flex", alignItems: "center", gap: 6, color: C.label2 }}>
            <div style={{ width: 17, height: 17, borderRadius: 5, background: C.accent, display: "flex", alignItems: "center", justifyContent: "center" }}><ICheck size={12} color="white" stroke={3} /></div>
            Remove
          </div>
          <div style={{ marginLeft: "auto", height: 34, padding: "0 14px", borderRadius: 9, background: C.warning, color: "#1b1b1e", fontWeight: 700, display: "flex", alignItems: "center", transform: `scale(${1 - 0.07 * press(T.remove)})` }}>Remove 2</div>
          <IClose size={15} color={C.label2} />
        </div>
      )}
    </div>
  );
};

/** Cursor path in sheet coordinates, with the lifted clip following it. */
const cursorAt = (t: number) => {
  const L = layout(t);
  const clipGrab = { x: tx(0.9), y: TRACK.y + 50 };
  const pts: [number, number, number][] = [
    [0, 700, 980],
    [T.split - 0.08, BTN.split.x, BTN.split.y],
    [T.lift - 0.12, clipGrab.x, clipGrab.y],
  ];
  if (t < T.lift) return keyPath(t, pts);
  if (t < T.drop) return { x: clipGrab.x + L.moved * (5 - SPLIT_AT) * PPS, y: clipGrab.y - 26 * L.lift };
  return keyPath(t, [
    [T.drop, clipGrab.x + (5 - SPLIT_AT) * PPS, clipGrab.y],
    [T.silence - 0.08, BTN.silence.x, BTN.silence.y],
    [T.detect + 0.3, 560, 1010],
    [T.remove - 0.08, BTN.remove2.x, BTN.remove2.y],
    [T.remove + 0.45, 1180, 1000],
    [T.undo - 0.08, BTN.undo.x, BTN.undo.y],
    [T.undo + 0.3, BTN.undo.x + 70, BTN.undo.y + 50],
  ]);
};
const keyPath = (t: number, pts: [number, number, number][]) => ({
  x: keys(t, pts.map(([k, x]) => [k, x]), easeInOutCubic),
  y: keys(t, pts.map(([k, , y]) => [k, y]), easeInOutCubic),
});

const World: React.FC = () => {
  const t = useTime();
  const L = layout(t);
  const rise = easeInOutCubic(prog(t, T.rise, 1.3));
  const follow = keys(t, [[0, -120], [1.0, -260], [2.4, 180], [2.9, -200], [3.6, -120], [4.6, 200], [5.4, 80], [T.undo, -220], [T.rise, -220]], easeInOutCubic);
  const trackC = wp(0, TRACK.y);
  const prevC = wp(0, 36 + 292);
  const camera = {
    x: lerp(follow, 0, rise),
    y: lerp(trackC.y - 60, prevC.y, rise),
    rx: lerp(48, 6, rise),
    ry: lerp(0, -4, rise),
    rz: lerp(-11, -1.5, rise),
    dolly: lerp(lerp(330, 420, easeInOutCubic(prog(t, 0, 5.6))), 520, rise),
  };
  const c = cursorAt(t);
  const cw = wp(c.x, c.y);
  const press = [T.split, T.undo, T.silence, T.remove].reduce((a, k) => Math.max(a, clamp(1 - Math.abs(t - k - 0.03) / 0.1)), 0);
  const lifted = L.lift > 0.001;
  const grabOff = (5 - SPLIT_AT) * PPS * L.moved;
  const a1 = wp(tx(0) + grabOff + (SPLIT_AT * PPS - 4) / 2, TRACK.y + TRACK.h / 2);
  const rings: [number, { x: number; y: number }][] = [[T.split, BTN.split], [T.undo, BTN.undo], [T.silence, BTN.silence], [T.remove, BTN.remove2]];
  return (
    <Space camera={camera}>
      <Plane w={W} h={H} style={{ borderRadius: 26, boxShadow: "0 80px 160px rgba(0,0,0,0.6)" }}>
        <Sheet t={t} />
      </Plane>
      {lifted && (
        <Plane x={a1.x} y={a1.y - 20 * L.lift} z={70 * L.lift} w={SPLIT_AT * PPS - 4} h={TRACK.h} s={1 + 0.04 * L.lift} rz={-1.5 * L.lift} style={{ overflow: "visible" }}>
          <Strip s0={0} s1={SPLIT_AT} w={SPLIT_AT * PPS - 4} selected={1} lifted={L.lift} />
        </Plane>
      )}
      <Plane x={cw.x} y={cw.y} z={lifted ? 90 * L.lift + 4 : 4} w={0} h={0} sharp style={{ overflow: "visible" }}>
        {rings.map(([k, b]) => {
          const bw = wp(b.x, b.y);
          return (
            <div key={k} style={{ position: "absolute", left: bw.x - cw.x, top: bw.y - cw.y }}>
              <ClickRing x={0} y={0} t={t} t0={k} size={90} />
            </div>
          );
        })}
        <Cursor x={0} y={0} press={press} scale={1.6} opacity={1 - rise} />
      </Plane>
    </Space>
  );
};

export const S07Edit: React.FC = () => {
  const t = useTime();
  const rise = easeInOutCubic(prog(t, T.rise, 1.0));
  return (
    <AbsoluteFill>
      <Backdrop glow={0.6} />
      <FocusMask amount={1 - rise} mode="band" cy={62} band={26} angle={-9} blur={9}>
        <World />
      </FocusMask>
      <AbsoluteFill style={{ background: "linear-gradient(180deg, rgba(11,11,14,0.85), rgba(11,11,14,0) 32%)", opacity: 1 - rise }} />
      <div style={{ position: "absolute", left: 110, top: 80 }}>
        <Caption lines={[["Trim,", "split,", { text: "reorder.", color: C.accentLight }]]} t={t} t0={0.2} t1={T.silence - 0.35} size={80} align="left" stagger={0.07} />
      </div>
      <div style={{ position: "absolute", left: 110, top: 80 }}>
        <Caption lines={[["Review", "detected", { text: "pauses.", color: C.warning }]]} t={t} t0={T.silence} t1={T.rise - 0.2} size={80} align="left" stagger={0.07} />
      </div>
    </AbsoluteFill>
  );
};
