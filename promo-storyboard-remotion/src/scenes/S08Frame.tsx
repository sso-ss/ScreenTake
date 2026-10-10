import React from "react";
import { AbsoluteFill } from "remotion";
import { Backdrop } from "../components/Backdrop";
import { Bubble, Canvas, DemoMobile, PhoneFrame } from "../components/Demo";
import { Flash, Hud, HudFrame } from "../components/Fx";
import { IPhone, IRatio } from "../components/Icons";
import { MotionBlur, Plane, Space } from "../components/Space";
import { Caption } from "../components/Type";
import { C, type Wall } from "../lib/theme";
import { clamp, easeInOutCubic, easeOutExpo, lerp, prog, springy, window01 } from "../lib/motion";
import { cues, useFormat, useTime } from "../lib/time";

// 37.6–42.4 s. The same recording re-framed on each beat. Each new canvas
// changes shape in one continuous hero canvas, with a small turn and a focus pull.
const T = cues("s08");
export type Frame = { name: string; ratio: string; wall: Wall; w: number; h: number; phone?: boolean };
const FRAMES_WIDE: Frame[] = [
  { name: "Widescreen", ratio: "16:9", wall: "prism", w: 1120, h: 630 },
  { name: "Square", ratio: "1:1", wall: "lagoon", w: 660, h: 660 },
  { name: "Stories / Reels", ratio: "9:16", wall: "ember", w: 382, h: 680 },
  { name: "iPhone", ratio: "", wall: "prism", w: 560, h: 680, phone: true },
  { name: "Widescreen", ratio: "16:9", wall: "midnight", w: 1120, h: 630 },
];
const FRAMES_TALL: Frame[] = FRAMES_WIDE.map((f) => {
  const k = Math.min(1, 900 / f.w) * 1.12;
  return { ...f, w: f.w * k, h: f.h * k };
});
const STARTS = [0, T.r1, T.r2, T.r3, T.r4];

const FrameCard: React.FC<{ f: Frame; t0: number; t: number }> = ({ f, t0, t }) => {
  const b = Math.min(f.w, f.h) * 0.2;
  const pop = springy(t - t0 - 0.18, 0.35, 0.45);
  const bubble = b > 0 && (
    <div style={{ position: "absolute", right: f.w * 0.045, bottom: f.w * 0.045, transform: `scale(${pop})`, transformOrigin: "100% 100%" }}>
      <Bubble size={b} shape={1} mirror={1} />
    </div>
  );
  if (f.phone)
    return <Canvas w={f.w} h={f.h} wall={f.wall} radius={22} pad={0.06} contentW={414} contentH={868} overlay={bubble} content={<div style={{ position: "absolute", left: 0, top: 0 }}><PhoneFrame h={844}><DemoMobile /></PhoneFrame></div>} />;
  return <Canvas w={f.w} h={f.h} wall={f.wall} radius={22} corners={14} overlay={bubble} />;
};

const World: React.FC = () => {
  const t = useTime();
  const tall = useFormat() === "tall";
  const frames = tall ? FRAMES_TALL : FRAMES_WIDE;
  let cur = 0;
  STARTS.forEach((s, i) => t >= s && (cur = i));
  const target = frames[cur];
  const previous = frames[Math.max(0,cur-1)];
  const morph = easeInOutCubic(prog(t, STARTS[cur], .5));
  const f = {...target,w:lerp(previous.w,target.w,morph),h:lerp(previous.h,target.h,morph)};
  const turn = Math.sin(morph*Math.PI)*(cur%2 ? 12 : -12);
  const camera = {x:0,y:tall?-30:-35,ry:lerp(-3,3,prog(t,0,4.8)),rx:2,dolly:lerp(-80,80,prog(t,0,4.8)),focus:0,aperture:1.2};
  return <Space camera={camera}>
    {/* Wallpaper arrives in the far plane while the same hero canvas reshapes. */}
    <Plane z={-900} w={1800} h={1100} opacity={.22} blur={22}>
      <Backdrop wall={target.wall} wallOpacity={.8} glow={0}/>
    </Plane>
    <Plane z={-200*(1-morph)} ry={turn} w={f.w} h={f.h} style={{borderRadius:22,boxShadow:"0 50px 120px rgba(0,0,0,.6)"}}>
      <FrameCard f={f} t0={STARTS[cur]} t={t}/>
    </Plane>
    <Plane y={tall?600:420} z={80} w={440} h={60} sharp s={tall?1.35:1}>
      <RatioChip f={target} t={t} t0={STARTS[cur]}/>
    </Plane>
  </Space>;
};

export const RatioChip: React.FC<{ f: Frame; t: number; t0: number }> = ({ f, t, t0 }) => {
  const p = easeOutExpo(prog(t, t0 + 0.08, 0.35));
  const label = f.phone ? "iPhone frame" : `${f.ratio} · ${f.name}`;
  return (
    <div style={{ width: 440, height: 60, display: "flex", justifyContent: "center", alignItems: "center" }}>
      <div style={{ height: 48, padding: "0 20px", borderRadius: 24, display: "flex", alignItems: "center", gap: 12, background: "rgba(22,22,26,0.82)", boxShadow: "inset 0 0 0 1px rgba(255,255,255,0.12), 0 14px 30px rgba(0,0,0,0.4)", transform: `translateY(${(1 - p) * 10}px) scale(${0.94 + 0.06 * p})`, opacity: clamp(p * 2) }}>
        {f.phone ? <IPhone size={20} color={C.accentLight} /> : <IRatio size={20} color={C.accentLight} />}
        <Hud size={16} color={C.label} style={{ letterSpacing: 2.4 }}>{label}</Hud>
      </div>
    </div>
  );
};

export const S08Frame: React.FC = () => {
  const t = useTime();
  const tall = useFormat() === "tall";
  const moving = Math.max(...STARTS.slice(1).map((s) => window01(t, s - 0.02, s + 0.3, 0.08)));
  return (
    <AbsoluteFill>
      <Backdrop glow={0.7} />
      <MotionBlur under={<Backdrop glow={0.7} />} active={moving > 0} amount={moving} samples={8} shutter={0.03}>
        <World />
      </MotionBlur>
      <HudFrame tl="SCREENTAKE" tr="FRAMING" bl="CANVAS" br="RATIO" opacity={0.8} />
      {STARTS.slice(1).map((s) => <Flash key={s} t={t} t0={s} strength={0.12} />)}
      <div style={tall ? { position: "absolute", left: 0, right: 0, top: 170 } : { position: "absolute", left: 110, top: 86 }}>
        <Caption lines={[["Frame", "your", "video."]]} t={t} t0={0.3} t1={T.r4 - 0.3} size={tall ? 96 : 80} align={tall ? "center" : "left"} stagger={0.07} />
      </div>
      <div style={tall ? { position: "absolute", left: 0, right: 0, top: 170 } : { position: "absolute", left: 110, top: 86 }}>
        <Caption lines={[["Make", "it", { text: "yours.", color: C.accentLight }]]} t={t} t0={T.r4 + 0.1} size={tall ? 96 : 80} align={tall ? "center" : "left"} stagger={0.07} />
      </div>
    </AbsoluteFill>
  );
};
