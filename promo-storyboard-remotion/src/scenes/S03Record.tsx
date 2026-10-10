import React from "react";
import { AbsoluteFill } from "remotion";
import { Backdrop } from "../components/Backdrop";
import { CaptureToolbar, Segmented, SettingsPanel, TOOLBAR, Toggle } from "../components/Capture";
import { ClickRing, Cursor, glide } from "../components/Cursor";
import { DEMO, DemoPage } from "../components/Demo";
import { Flash } from "../components/Fx";
import { IAudio, IMic, ISpeaker } from "../components/Icons";
import { MotionBlur, Plane, Space } from "../components/Space";
import { Caption } from "../components/Type";
import { C } from "../lib/theme";
import { clamp, easeInCubic, easeInOutCubic, easeOutCubic, easeOutExpo, lerp, prog, springy } from "../lib/motion";
import { cues, useTime } from "../lib/time";

// 7.2–12.8 s. Caption, hard cut to the desktop with the capture toolbar, the
// Record click, recording options stacking on, then a push into the page.
const T = cues("s03");
const TB = { x: 0, y: 330, z: 160, s: 1.9 };
const REC = { x: TB.x + (TOOLBAR.record.x - TOOLBAR.w / 2) * TB.s, y: TB.y + (TOOLBAR.record.y - TOOLBAR.h / 2) * TB.s };

const Desktop: React.FC = () => {
  const t = useTime();
  const local = t - T.cut;
  const drift = easeInOutCubic(prog(t, T.cut, T.push - T.cut));
  const push = easeInCubic(prog(t, T.push, 1.0));
  const camera = {
    x: lerp(-40, 30, drift),
    y: lerp(40, 0, drift) - 40 * push,
    rx: lerp(9, 4, drift) - 4 * push,
    ry: lerp(-9, 3, drift),
    dolly: lerp(-60, 60, drift) + 1150 * push,
    focus: lerp(TB.z, -250, easeInOutCubic(prog(t, T.push - 0.2, 0.6))),
    aperture: 1.1,
  };
  const g = prog(t, T.cut + 0.2, T.record - 0.25 - T.cut - 0.2);
  const [cx, cy] = glide(g, [REC.x - 420, REC.y - 250], [REC.x + 4, REC.y + 6], 60);
  const press = clamp(1 - Math.abs(t - T.record - 0.04) / 0.1);
  const panel = easeOutExpo(prog(t, T.panel, 0.3));
  const panelBump = (t0: number) => 1 + 0.035 * Math.sin(prog(t, t0, 0.25) * Math.PI);
  const on = (t0: number) => springy(t - t0, 0.25, 0.3);
  const toolbarIn = easeOutCubic(prog(local, 0, 0.4));
  return (
    <Space camera={camera}>
      <Plane z={-250} y={-40} w={DEMO.w} h={DEMO.h} s={1.32} style={{ borderRadius: 14, boxShadow: "0 50px 120px rgba(0,0,0,0.45)", overflow: "hidden" }}>
        <DemoPage />
      </Plane>
      <Plane x={TB.x} y={TB.y + 40 * (1 - toolbarIn)} z={TB.z} w={TOOLBAR.w} h={TOOLBAR.h} s={TB.s} opacity={toolbarIn} style={{ overflow: "visible" }}>
        <CaptureToolbar press={press} tooltip={1 - clamp((t - T.record) / 0.15)} />
      </Plane>
      <Plane x={lerp(1500, 390, panel)} y={-70} z={320} ry={-12} w={360} h={200} res={2} s={1.38 * panelBump(T.t1)} opacity={clamp(panel * 2)} sharp style={{ overflow: "visible" }}>
        <SettingsPanel
          title="Recording"
          w={360}
          rows={[
            { label: "Frame Rate", icon: <IAudio size={15} color={C.label2} style={{ opacity: 0 }} />, control: <Segmented options={["30 FPS", "60 FPS"]} value={lerp(0, 1, on(T.t1))} w={150} />, hi: clamp(1 - Math.abs(t - T.t1 - 0.15) / 0.3) },
            { label: "Microphone", icon: <IMic size={15} color={C.label2} />, control: <Toggle on={on(T.t2)} />, hi: clamp(1 - Math.abs(t - T.t2 - 0.15) / 0.3) },
            { label: "System Audio", icon: <ISpeaker size={15} color={C.label2} />, control: <Toggle on={on(T.t3)} />, hi: clamp(1 - Math.abs(t - T.t3 - 0.15) / 0.3) },
          ]}
        />
      </Plane>
      <Plane z={TB.z + 2} w={0} h={0} sharp style={{ overflow: "visible" }}>
        <ClickRing x={REC.x} y={REC.y} t={t} t0={T.record} size={130} />
        <Cursor x={cx} y={cy} press={press} scale={1.9} opacity={clamp((local - 0.1) / 0.2) * (1 - clamp((t - T.panel - 0.1) / 0.2))} />
      </Plane>
    </Space>
  );
};

export const S03Record: React.FC = () => {
  const t = useTime();
  if (t < T.cut) {
    return (
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <Backdrop glow={0.6} />
        <div style={{ transform: `scale(${1 + 0.06 * (t / T.cut)})` }}>
          <Caption lines={[["Start", "with", "a"], ["good", { text: "take.", color: C.accentLight }]]} t={t} t0={0.05} size={132} stagger={0.07} />
        </div>
      </AbsoluteFill>
    );
  }
  const push = t > T.push + 0.45;
  return (
    <AbsoluteFill>
      <Backdrop wall="lagoon" wallOpacity={1} blur={2} scale={1.08} x={-20 * (t - T.cut)} glow={0} />
      <MotionBlur under={<Backdrop wall="lagoon" wallOpacity={1} blur={2} scale={1.08} x={-20 * (t - T.cut)} glow={0} />} active={push}>
        <Desktop />
      </MotionBlur>
      <Flash t={t} t0={T.cut} strength={0.25} />
    </AbsoluteFill>
  );
};
