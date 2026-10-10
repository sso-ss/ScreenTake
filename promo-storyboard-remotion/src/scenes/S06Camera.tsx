import React from "react";
import { AbsoluteFill } from "remotion";
import { Backdrop } from "../components/Backdrop";
import { Bubble, Canvas } from "../components/Demo";
import { Hud } from "../components/Fx";
import { IMic, ISpeaker } from "../components/Icons";
import { Group, MotionBlur, Plane, Space } from "../components/Space";
import { Caption } from "../components/Type";
import { C, F } from "../lib/theme";
import { clamp, easeInOutCubic, easeOutExpo, lerp, prog, springy, window01 } from "../lib/motion";
import { cues, useTime } from "../lib/time";

// 24.8–30.4 s. The presenter bubble springs onto an Ember canvas, rounds its
// corners, hops corner to corner (flipping to mirror), then audio joins in.
const T = cues("s06");
const CW = 1280;
const CH = 720;
const B = 210;
const M = 40;
const corner = (cx: number, cy: number) => ({ x: cx * (CW / 2 - M - B / 2), y: cy * (CH / 2 - M - B / 2) });
const SPOTS = [corner(1, 1), corner(-1, 1), corner(-1, -1), corner(1, -1)];
const HOP = 0.42;
// Each hop lands on its cue (the thunk).
const HOPS = [T.hop1, T.hop2, T.hop3].map((c) => c - HOP);

const bubbleState = (t: number) => {
  let i = 0;
  HOPS.forEach((h) => t >= h && i++);
  const h = HOPS[i - 1];
  if (i === 0 || t > h + HOP) return { ...SPOTS[i], lift: 0, squash: i === 0 ? 0 : Math.exp(-(t - h - HOP) * 9) * Math.sin((t - h - HOP) * 30) * 0.06 };
  const p = easeInOutCubic(prog(t, h, HOP));
  const a = SPOTS[i - 1];
  const b = SPOTS[i];
  return { x: lerp(a.x, b.x, p), y: lerp(a.y, b.y, p), lift: Math.sin(p * Math.PI) * 170, squash: 0 };
};

const Wave: React.FC<{ seed: number; t: number; w: number; on: number }> = ({ seed, t, w, on }) => {
  const n = 46;
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 3, width: w, height: 48 }}>
      {Array.from({ length: n }, (_, i) => {
        const u = i - t * 22;
        const v = Math.abs(Math.sin(u * 0.41 + seed) * Math.sin(u * 0.13 + seed * 2.1) + 0.35 * Math.sin(u * 1.7 + seed));
        const grow = clamp((on * n * 1.6 - i) / 6);
        return <div key={i} style={{ flex: 1, height: Math.max(3, 44 * v * grow), borderRadius: 3, background: C.audio, opacity: 0.35 + 0.65 * grow }} />;
      })}
    </div>
  );
};

export const Track: React.FC<{ label: string; icon: React.ReactNode; seed: number; t: number; on: number }> = ({ label, icon, seed, t, on }) => (
  <div style={{ width: 560, height: 76, borderRadius: 14, background: "rgba(30,30,33,0.96)", boxShadow: "0 24px 60px rgba(0,0,0,0.55), inset 0 0 0 1px rgba(255,255,255,0.08)", display: "flex", alignItems: "center", gap: 14, padding: "0 18px", boxSizing: "border-box" }}>
    <div style={{ width: 36, height: 36, borderRadius: 10, background: "rgba(251,191,36,0.16)", display: "flex", alignItems: "center", justifyContent: "center" }}>{icon}</div>
    <div style={{ fontFamily: F.sans, fontSize: 15, fontWeight: 600, color: C.label, width: 108 }}>{label}</div>
    <Wave seed={seed} t={t} w={370} on={on} />
  </div>
);

const LABELS: [number, string][] = [
  [T.bubble, "Camera · On"],
  [T.shape, "Shape · Rounded"],
  [T.hop1, "Position · Bottom left"],
  [T.hop2, "Position · Top left · Mirrored"],
  [T.hop3, "Size · 125%"],
];

const World: React.FC = () => {
  const t = useTime();
  const drift = easeInOutCubic(prog(t, 0, 5.6));
  const toSound = easeInOutCubic(prog(t, T.sound - 0.2, 0.9));
  const camera = {
    x: lerp(-20, 30, drift) - 40 * toSound,
    y: lerp(-10, 10, drift) + 90 * toSound,
    rx: lerp(8, 4, drift) + 4 * toSound,
    ry: lerp(-6, 4, drift),
    dolly: lerp(40, 170, drift) + 60 * toSound,
    focus: lerp(40, 180, toSound),
    aperture: 0.9,
  };
  const b = bubbleState(t);
  const pop = springy(t - T.bubble, 0.45, 0.42);
  const shape = clamp(springy(t - T.shape, 0.4, 0.3));
  const flip = 180 * easeInOutCubic(prog(t, HOPS[1] + 0.04, HOP - 0.04));
  const size = lerp(1, 1.25, springy(t - T.hop3, 0.4, 0.35));
  const labelIdx = LABELS.filter(([k]) => t >= k).length - 1;
  const label = labelIdx >= 0 ? LABELS[labelIdx] : null;
  const labelP = label ? easeOutExpo(prog(t, label[0], 0.3)) : 0;
  const soundIn = (d: number) => easeOutExpo(prog(t, T.sound + d, 0.45));
  const sk = 1 + b.squash;
  const labelOut = 1 - clamp((t - T.sound) / 0.25);
  // Bubble anchor offset so it grows toward the canvas centre.
  const grow = ((size - 1) * B) / 2;
  const bx = b.x - Math.sign(b.x) * grow;
  const by = b.y - Math.sign(b.y) * grow;
  return (
    <Space camera={camera}>
      <Group x={150} y={110} ry={-12} rx={4} s={0.86}>
        <Plane w={CW} h={CH} style={{ borderRadius: 22, boxShadow: "0 60px 140px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.08)" }}>
          <Canvas w={CW} h={CH} wall="ember" radius={22} corners={16} />
        </Plane>
        {/* Contact shadow shrinks and softens as the bubble lifts. */}
        <Plane x={bx} y={by + 18} z={1} w={B} h={B} s={size * (1 - b.lift / 600)} opacity={0.5 * pop * (1 - b.lift / 260)} sharp
          style={{ borderRadius: B, background: "rgba(0,0,0,0.9)", filter: `blur(${18 + b.lift / 6}px)` }} />
        <Plane x={bx} y={by} z={8 + b.lift} ry={flip} w={B} h={B} s={pop * size} opacity={clamp(pop * 3)}>
          <div style={{ transform: `scale(${1 / sk}, ${sk})`, transformOrigin: "50% 100%" }}>
            <Bubble size={B} shape={shape} />
          </div>
        </Plane>
        {label && (
          <Plane x={bx + (bx > 0 ? (B * size) / 2 - 230 : 230 - (B * size) / 2)} y={by + (by > 0 ? -1 : 1) * ((B * size) / 2 + 34)} z={60 + b.lift} w={460} h={36} sharp opacity={labelP * labelOut}>
            <div style={{ display: "flex", justifyContent: bx > 0 ? "flex-end" : "flex-start", transform: `translateY(${(1 - labelP) * 10}px)` }}>
              <Hud size={17} color="white" style={{ background: "rgba(16,16,20,0.86)", borderRadius: 8, padding: "6px 12px", boxShadow: "0 10px 30px rgba(0,0,0,0.4)" }}>
                <span style={{ color: C.accentLight }}>●</span> {label[1]}
              </Hud>
            </div>
          </Plane>
        )}
      </Group>
      <Plane x={-330} y={300} z={220} ry={10} w={560} h={76} opacity={soundIn(0)} sharp>
        <Track label="Microphone" icon={<IMic size={17} color={C.audio} />} seed={1.3} t={t} on={soundIn(0)} />
      </Plane>
      <Plane x={-270} y={400} z={250} ry={10} w={560} h={76} opacity={soundIn(0.12)} sharp>
        <Track label="System Audio" icon={<ISpeaker size={17} color={C.audio} />} seed={4.1} t={t} on={soundIn(0.12)} />
      </Plane>
    </Space>
  );
};

export const S06Camera: React.FC = () => {
  const t = useTime();
  const hopping = Math.max(...HOPS.map((h) => window01(t, h, h + HOP, 0.1)));
  return (
    <AbsoluteFill>
      <Backdrop glow={0.8} />
      <MotionBlur under={<Backdrop glow={0.8} />} active={hopping > 0} amount={hopping} samples={8} shutter={0.022}>
        <World />
      </MotionBlur>
      <div style={{ position: "absolute", left: 110, top: 86 }}>
        <Caption lines={[["Put", "yourself"], ["in", "the", { text: "picture.", color: C.accentLight }]]} t={t} t0={0.4} t1={T.sound - 0.3} size={86} align="left" stagger={0.06} />
      </div>
      <div style={{ position: "absolute", left: 110, top: 86 }}>
        <Caption lines={[["Sound", { text: "included.", color: C.audio }]]} t={t} t0={T.sound} size={86} align="left" stagger={0.06} />
      </div>
    </AbsoluteFill>
  );
};
