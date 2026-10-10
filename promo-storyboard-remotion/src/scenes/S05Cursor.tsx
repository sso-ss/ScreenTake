import React from "react";
import { AbsoluteFill } from "remotion";
import { Backdrop } from "../components/Backdrop";
import { PanelSlider } from "../components/AppWindow";
import { ClickRing, Cursor, type CursorShape } from "../components/Cursor";
import { Canvas } from "../components/Demo";
import { Flash, Hud, HudFrame } from "../components/Fx";
import { MotionBlur, Plane, Space } from "../components/Space";
import { CardTitle } from "../components/Type";
import { C, CLICK_COLORS, F } from "../lib/theme";
import { clamp, easeInOutCubic, easeOutCubic, easeOutExpo, keys, lerp, prog, springy, window01 } from "../lib/motion";
import { cues, useFormat, useTime } from "../lib/time";

// 20.0–24.8 s. Rive-style cards cut hard against two demos: the cursor
// changing shape and size, then the six click highlight colours.
const T = cues("s05");
const KS = [T.k0, T.k1, T.k2, T.k3, T.k4, T.k5];

const Card: React.FC<{ lines: string[]; t0: number; accent: number; tag: string }> = ({ lines, t0, accent, tag }) => {
  const t = useTime();
  const tall = useFormat() === "tall";
  const push = 1 + 0.035 * easeOutCubic(prog(t, t0, 0.8));
  return (
    <AbsoluteFill style={{ background: C.night, alignItems: "center", justifyContent: "center" }}>
      <div style={{ transform: `scale(${push})` }}>
        <CardTitle lines={lines} t={t} starts={[t0 + 0.04, t0 + 0.3]} size={tall ? 104 : 142} accent={accent} />
      </div>
      <HudFrame tl="SCREENTAKE" tr={tag} bl="CURSOR" br="MACOS" opacity={clamp((t - t0) / 0.1)} inset={tall ? 64 : 56} />
    </AbsoluteFill>
  );
};

const SHAPES: { id: CursorShape; label: string }[] = [
  { id: "arrow", label: "Arrow" },
  { id: "hand", label: "Hand" },
  { id: "circle", label: "Circle" },
];

export const ShapePanel: React.FC<{ shape: number; size: number }> = ({ shape, size }) => (
  <div style={{ width: 340, borderRadius: 14, background: "rgba(38,38,40,0.97)", boxShadow: "0 30px 70px rgba(0,0,0,0.55), inset 0 0 0 1px rgba(255,255,255,0.09)", padding: "16px 18px 18px", boxSizing: "border-box", fontFamily: F.sans, color: C.label }}>
    <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 12 }}>Cursor</div>
    <div style={{ display: "flex", gap: 10 }}>
      {SHAPES.map((s, i) => {
        const on = clamp(1 - Math.abs(shape - i));
        return (
          <div key={s.id} style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", gap: 6 }}>
            <div style={{ width: "100%", height: 62, borderRadius: 10, background: "#2c2c2f", position: "relative", boxShadow: `inset 0 0 0 ${lerp(1, 2, on)}px ${on > 0.5 ? C.accent : "#434346"}` }}>
              <Cursor x={s.id === "arrow" ? 38 : s.id === "hand" ? 42 : 47} y={s.id === "circle" ? 31 : 14} shape={s.id} scale={0.95} shadow={false} />
            </div>
            <div style={{ fontSize: 11, color: on > 0.5 ? C.label : C.label3, fontWeight: on > 0.5 ? 700 : 500 }}>{s.label}</div>
          </div>
        );
      })}
    </div>
    <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: 16, fontSize: 13 }}>
      <div>Size</div>
      <div style={{ marginLeft: "auto" }}>
        <PanelSlider value={(size - 0.5) / 2.5} w={170} />
      </div>
      <div style={{ fontFamily: F.mono, fontSize: 12, width: 40, textAlign: "right" }}>{Math.round(size * 100)}%</div>
    </div>
  </div>
);

const CursorDemo: React.FC = () => {
  const t = useTime();
  const tall = useFormat() === "tall";
  const local = t - T.cut1;
  const shapeIdx = t < T.hand ? 0 : t < T.circle ? 1 : 2;
  const shapeId = SHAPES[shapeIdx].id;
  const from = shapeIdx === 1 ? "arrow" : shapeIdx === 2 ? "hand" : undefined;
  const morph = springy(t - (shapeIdx === 1 ? T.hand : T.circle), 0.35, 0.45);
  const size = keys(t, [[T.big, 1], [T.big + 0.28, 3], [T.small, 3], [T.small + 0.25, 0.5]], easeInOutCubic) + 0.12 * Math.sin(prog(t, T.big + 0.2, 0.3) * Math.PI) * (t < T.small ? 1 : 0);
  // A slow looping path, as a smoothed pointer would travel.
  const path = (u: number) => [Math.sin(u * 1.7) * 170 - 40, Math.sin(u * 3.4) * 50 - 20] as const;
  const [px, py] = path(local);
  const trail = Array.from({ length: 14 }, (_, i) => path(local - (i + 1) * 0.035));
  const camera = {
    x: lerp(-30, 30, prog(local, 0, 1.8)),
    y: tall ? 60 : 0,
    rx: 6,
    ry: lerp(-12, -4, easeInOutCubic(prog(local, 0, 1.8))),
    dolly: lerp(-80, 60, easeOutCubic(prog(local, 0, 1.8))),
    focus: 200,
    aperture: 1.6,
  };
  const panelIn = easeOutExpo(prog(local, 0.08, 0.4));
  return (
    <Space camera={camera}>
      <Plane z={-420} w={1280} h={720} s={tall ? 1.9 : 1.35}>
        <Canvas w={1280} h={720} wall="lagoon" radius={24} />
      </Plane>
      <Plane z={200} w={0} h={0} sharp style={{ overflow: "visible" }}>
        {trail.map(([x, y], i) => (
          <div key={i} style={{ position: "absolute", left: x - 4, top: y - 4, width: 8, height: 8, borderRadius: 8, background: C.accentLight, opacity: 0.4 * (1 - i / trail.length) }} />
        ))}
        <Cursor x={px} y={py} shape={shapeId} from={from} morph={from ? morph : 1} scale={2.9 * size} />
      </Plane>
      <Plane x={tall ? 0 : lerp(-1000, -470, panelIn)} y={tall ? lerp(1000, 520, panelIn) : 250} z={120} ry={tall ? 0 : 14} w={340} h={180} s={tall ? 2.3 : 1.3} sharp opacity={clamp(panelIn * 2)} style={{ overflow: "visible" }}>
        <ShapePanel shape={shapeIdx === 0 ? 0 : lerp(shapeIdx - 1, shapeIdx, morph)} size={size} />
      </Plane>
    </Space>
  );
};

const CHIP = { w: 220, h: 128 };
const chipPos = (i: number, tall: boolean) => (tall ? { x: ((i % 2) - 0.5) * 280, y: (Math.floor(i / 2) - 1) * 200 } : { x: (i - 2.5) * 260, y: 0 });

const ClickDemo: React.FC = () => {
  const t = useTime();
  const tall = useFormat() === "tall";
  const local = t - T.cut2;
  // The pointer hops chip to chip, landing just before each click.
  let cx = chipPos(0, tall).x - 200;
  let cy = chipPos(0, tall).y + 150;
  KS.forEach((k, i) => {
    const p = easeInOutCubic(prog(t, k - 0.17, 0.15));
    const a = i === 0 ? { x: cx, y: cy } : chipPos(i - 1, tall);
    const b = chipPos(i, tall);
    if (t >= k - 0.17) {
      cx = lerp(a.x, b.x, p) + 8;
      cy = lerp(a.y, b.y, p) + 10 - 30 * Math.sin(p * Math.PI);
    }
  });
  const track = easeInOutCubic(prog(t, T.k0 - 0.2, 1.4));
  const camera = {
    x: tall ? 0 : lerp(-240, 240, track),
    y: tall ? lerp(-120, 120, track) : 0,
    rx: 20,
    ry: tall ? 0 : lerp(10, -10, track),
    rz: tall ? 0 : -3,
    dolly: lerp(tall ? 420 : 220, tall ? 520 : 400, easeOutCubic(prog(local, 0, 1.6))),
    focus: 0,
    aperture: 1.2,
  };
  const labelIn = easeOutCubic(prog(local, 0.05, 0.4));
  return (
    <Space camera={camera}>
      <Plane y={tall ? -420 : -190} z={40} w={600} h={40} sharp opacity={labelIn}>
        <Hud size={20} color="rgba(255,255,255,0.8)" style={{ textAlign: "center" }}>
          Highlight Clicks · <span style={{ color: CLICK_COLORS[Math.max(0, KS.filter((k) => t >= k).length - 1)].color }}>{CLICK_COLORS[Math.max(0, KS.filter((k) => t >= k).length - 1)].name}</span>
        </Hud>
      </Plane>
      {CLICK_COLORS.map((c, i) => {
        const { x, y } = chipPos(i, tall);
        const hit = t >= KS[i];
        const pop = hit ? 1 + 0.08 * Math.sin(prog(t, KS[i], 0.25) * Math.PI) : 1;
        const lift = hit ? 40 * springy(t - KS[i], 0.4, 0.3) : 0;
        const inP = easeOutExpo(prog(local, 0.02 * i, 0.35));
        return (
          <React.Fragment key={c.name}>
            <Plane x={x} y={y + 60 * (1 - inP)} z={lift} w={CHIP.w} h={CHIP.h} s={pop} opacity={inP}
              style={{ borderRadius: 18, background: hit ? "rgba(34,34,38,0.98)" : "rgba(26,26,29,0.95)", boxShadow: `0 ${20 + lift}px ${50 + lift}px rgba(0,0,0,0.5), inset 0 0 0 1.5px ${hit ? c.color : "rgba(255,255,255,0.08)"}` }}>
              <div style={{ position: "absolute", left: 20, top: 20, width: 30, height: 30, borderRadius: 30, background: c.color, boxShadow: hit ? `0 0 26px ${c.color}` : undefined }} />
              <div style={{ position: "absolute", left: 20, bottom: 20, fontFamily: F.mono, fontSize: 15, letterSpacing: 2, textTransform: "uppercase", color: hit ? "white" : C.label3 }}>{c.name}</div>
            </Plane>
            <Plane x={x} y={y} z={lift + 2} w={0} h={0} sharp style={{ overflow: "visible" }}>
              <ClickRing x={0} y={0} t={t} t0={KS[i]} color={c.color} size={210} dur={0.6} />
            </Plane>
          </React.Fragment>
        );
      })}
      <Plane z={60} w={0} h={0} sharp style={{ overflow: "visible" }}>
        <Cursor x={cx} y={cy} scale={2.4} press={Math.max(...KS.map((k) => clamp(1 - Math.abs(t - k - 0.02) / 0.08)))} opacity={labelIn} />
      </Plane>
    </Space>
  );
};

export const S05Cursor: React.FC = () => {
  const t = useTime();
  if (t < T.cut1) return <Card lines={["A cursor", "with presence."]} t0={T.card1} accent={1} tag="01 / SHAPE" />;
  if (t >= T.card2 && t < T.cut2) return <Card lines={["Make every", "click clear."]} t0={T.card2} accent={1} tag="02 / CLICKS" />;
  const cut = t < T.card2 ? T.cut1 : T.cut2;
  const hop = Math.max(...KS.map((k) => window01(t, k - 0.17, k - 0.02, 0.04)));
  return (
    <AbsoluteFill>
      <Backdrop glow={0.7} />
      {t < T.card2 ? <CursorDemo /> : <MotionBlur under={<Backdrop glow={0.7} />} active={hop > 0} amount={hop} samples={10} shutter={0.02}><ClickDemo /></MotionBlur>}
      <Flash t={t} t0={cut} strength={0.2} />
    </AbsoluteFill>
  );
};
