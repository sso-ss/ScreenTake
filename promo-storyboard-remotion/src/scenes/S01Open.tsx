import React from "react";
import { AbsoluteFill } from "remotion";
import { AppWindow, RECORD_PILL, WIN } from "../components/AppWindow";
import { Backdrop } from "../components/Backdrop";
import { ClickRing, Cursor, glide } from "../components/Cursor";
import { Countdown, FocusMask } from "../components/Fx";
import { MotionBlur, Plane, Space } from "../components/Space";
import { lerpZoom, zoomRig } from "../lib/camera";
import { clamp, easeInCubic, easeInOutCubic, easeOutCubic, easeOutExpo, lerp, prog, window01 } from "../lib/motion";
import { cues, useTime } from "../lib/time";

// 0.0–3.2 s. Macro on the Record pill, a click, a snap pull-out, then the 3-2-1.
const T = cues("s01");
const SC = 1.22; // window scale in the world
const PILL = { x: (RECORD_PILL.x - WIN.w / 2) * SC, y: (RECORD_PILL.y - WIN.h / 2) * SC };

const World: React.FC = () => {
  const t = useTime();
  const pull = easeOutExpo(prog(t, T.pull, 0.42));
  const drift = easeInCubic(prog(t, 0, T.click));
  const macro = lerp(13, 10.5, easeInOutCubic(prog(t, 0, T.click)));
  const zoom = lerpZoom(macro, 1, pull);
  const { dolly, scale } = zoomRig(zoom);
  const count = easeInOutCubic(prog(t, T.c3 - 0.1, 0.35));
  const camera = {
    x: lerp(PILL.x + lerp(34, -18, drift), 0, pull),
    y: lerp(PILL.y + 2, 0, pull),
    rx: lerp(10, 0, pull) + 3 * count,
    ry: lerp(-16, 0, pull) - 2 * count,
    rz: lerp(-2.5, 0, pull),
    dolly: dolly + 60 * count,
    focus: lerp(0, 240, count),
    aperture: 0.35 * count,
  };

  // Pointer glides in over the pill (window-local points).
  const g = prog(t, 0.55, T.click - 0.2 - 0.55);
  const [cx, cy] = glide(g, [RECORD_PILL.x + 70, RECORD_PILL.y + 46], [RECORD_PILL.x + 12, RECORD_PILL.y + 4], 10);
  const press = clamp(1 - Math.abs(t - T.click - 0.04) / 0.1);
  const pulse = 0.5 + 0.5 * Math.sin(t * 5.2);

  return (
    <Space camera={camera} scale={scale}>
      <Plane w={WIN.w} h={WIN.h} s={SC} style={{ boxShadow: "0 60px 140px rgba(0,0,0,0.6)", borderRadius: 12 }}>
        <AppWindow recordPress={press} recordPulse={t < T.click ? pulse : 0}>
          <ClickRing x={cx} y={cy} t={t} t0={T.click} size={70} />
          <Cursor x={cx} y={cy} press={press} opacity={clamp((t - 0.5) / 0.15) * (1 - clamp((t - T.c3 + 0.2) / 0.2))} />
        </AppWindow>
        <div style={{ position: "absolute", inset: 0, borderRadius: 12, background: "black", opacity: 0.14 * count }} />
      </Plane>
      {[T.c3, T.c2, T.c1].map((t0, i) => {
        const next = [T.c2, T.c1, 3.3][i];
        if (t < t0 || t > next + 0.12) return null;
        const out = easeInCubic(prog(t, next - 0.02, 0.12));
        return (
          <Plane key={i} z={240} w={100} h={100} s={2.3 * (1 + 0.25 * out)} opacity={1 - out} sharp>
            <Countdown n={3 - i} t={t} t0={t0} />
          </Plane>
        );
      })}
    </Space>
  );
};

export const S01Open: React.FC = () => {
  const t = useTime();
  const pull = easeOutExpo(prog(t, T.pull, 0.42));
  const wallIn = easeOutCubic(prog(t, 0, 1.1));
  const mb = window01(t, T.pull - 0.03, T.pull + 0.36, 0.08);
  return (
    <AbsoluteFill>
      <Backdrop wall="midnight" wallOpacity={lerp(0.9, 0.55, pull) * wallIn} blur={lerp(26, 60, pull)} scale={lerp(1.35, 1.1, pull)} x={-40 * t} glow={0.8} />
      <AbsoluteFill style={{ opacity: easeOutCubic(prog(t, 0.2, 0.7)) }}>
        <FocusMask amount={1 - pull} blur={10} cx={50} cy={50} r={22}>
          <MotionBlur under={<Backdrop wall="midnight" wallOpacity={lerp(0.9, 0.55, pull) * wallIn} blur={lerp(26, 60, pull)} scale={lerp(1.35, 1.1, pull)} x={-40 * t} glow={0.8} />} active={mb > 0} amount={mb} samples={16} shutter={0.012}>
            <World />
          </MotionBlur>
        </FocusMask>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
