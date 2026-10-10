import React from "react";
import { AbsoluteFill } from "remotion";
import { Backdrop } from "../components/Backdrop";
import { SettingsPanel, Toggle } from "../components/Capture";
import { PanelSlider } from "../components/AppWindow";
import { ClickRing, Cursor, glide } from "../components/Cursor";
import { Canvas, DEMO, DemoPage } from "../components/Demo";
import { MotionBlur, Plane, Space } from "../components/Space";
import { Caption } from "../components/Type";
import { C, F } from "../lib/theme";
import { clamp, easeInOutCubic, easeOutCubic, easeOutExpo, keys, lerp, prog, springy, window01 } from "../lib/motion";
import { lerpZoom } from "../lib/camera";
import { cues, useFormat, useTime } from "../lib/time";

// 12.8–20.0 s. A floating 16:9 output canvas. The recording zooms in ahead of
// the click, follows the cursor to the next click, then eases back out.
const T = cues("s04");
const CW = 1280;
const CH = 720;
const CTA = DEMO.cta;
const CARD = { x: DEMO.cards[1].x, y: DEMO.cards[1].y };
const ZOOM = 3;

/** Inner recording zoom: leads click 1 by 0.1 s, holds through the follow, eases out. */
const innerZoom = (t: number) => {
  if (t < T.zoomIn) return 1;
  if (t < T.pullBack) return lerpZoom(1, ZOOM, easeInOutCubic(prog(t, T.zoomIn, T.click1 - 0.1 - T.zoomIn)));
  return lerpZoom(ZOOM, 1, easeInOutCubic(prog(t, T.pullBack, 0.55)));
};

// Fixed widths throughout: a size-to-content pill re-measures its text whenever
// the plane's raster resolution changes, which reads as the pill jittering.
const CHIP = { pad: 24, gap: 16, label: 124, value: 104, follow: 286 };
const StatusChip: React.FC<{ zoom: number; follow: number; t: number }> = ({ zoom, follow, t }) => (
  <div style={{ display: "flex", alignItems: "center", height: 68, padding: `0 ${CHIP.pad}px`, gap: CHIP.gap, borderRadius: 34, background: "rgba(14,14,18,0.86)", boxShadow: "0 20px 50px rgba(0,0,0,0.45), inset 0 0 0 1px rgba(255,255,255,0.12)", fontFamily: F.sans, color: "white", boxSizing: "border-box", width: CHIP.pad * 2 + CHIP.label + CHIP.gap + CHIP.value + (CHIP.gap + CHIP.follow) * follow, overflow: "hidden", whiteSpace: "nowrap" }}>
    <div style={{ width: CHIP.label, flexShrink: 0, fontSize: 24, fontWeight: 600, color: C.label2 }}>Auto Zoom</div>
    <div style={{ width: CHIP.value, flexShrink: 0, fontFamily: F.mono, fontSize: 30, fontWeight: 600, fontVariantNumeric: "tabular-nums", color: "white" }}>{zoom.toFixed(2)}×</div>
    <div style={{ width: CHIP.follow, flexShrink: 0, opacity: follow, display: "flex", alignItems: "center", gap: 12 }}>
      <div style={{ width: 1.5, height: 30, background: "rgba(255,255,255,0.18)", flexShrink: 0 }} />
      <div style={{ width: 12, height: 12, borderRadius: 12, background: C.accentLight, flexShrink: 0, boxShadow: `0 0 ${10 + 8 * Math.sin(t * 8)}px ${C.accentLight}` }} />
      <div style={{ fontSize: 24, fontWeight: 600, color: C.accentLight }}>Following cursor</div>
    </div>
  </div>
);

const World: React.FC = () => {
  const t = useTime();
  const tall = useFormat() === "tall";
  const zoom = innerZoom(t);
  const follow = easeInOutCubic(prog(t, T.follow, 0.62));
  const focus = { x: lerp(CTA.x, CARD.x, follow), y: lerp(CTA.y, CARD.y, follow) };

  // Cursor path in recording coordinates.
  let [cx, cy] = glide(prog(t, 0.2, 1.6), [640, 160], [CTA.x + 6, CTA.y + 4], 50);
  if (t > T.click1 + 0.35) [cx, cy] = glide(prog(t, T.follow - 0.05, 0.72), [CTA.x + 6, CTA.y + 4], [CARD.x, CARD.y + 6], -40);
  if (t > T.click2 + 0.3) [cx, cy] = glide(prog(t, T.click2 + 0.35, 0.9), [CARD.x, CARD.y + 6], [700, 300], 30);
  const press1 = clamp(1 - Math.abs(t - T.click1 - 0.03) / 0.1);
  const press2 = clamp(1 - Math.abs(t - T.click2 - 0.03) / 0.1);

  const pull = easeInOutCubic(prog(t, T.pullBack, 0.9));
  const settleIn = easeOutCubic(prog(t, 0, 1.4));
  // Linear creep after the pull-back so the final shot never sits still.
  const creep = prog(t, T.pullBack, 7.2 - T.pullBack);
  const camera = {
    x: 40 * creep + (tall ? 0 : lerp(-60, 60, settleIn) + keys(t, [[1.3, 0], [2.0, -90], [2.8, -90], [3.5, 40], [4.8, 40]]) * (1 - pull)),
    y: tall ? 90 : lerp(20, 0, settleIn) + keys(t, [[1.3, 0], [2.0, 30], [2.8, 30], [3.5, 70], [4.8, 70]]) * (1 - pull) + 190 * pull,
    rx: lerp(10, 5, settleIn) + keys(t, [[1.3, 0], [2.0, -3]]) + 8 * pull,
    ry: lerp(-18, -10, settleIn) + keys(t, [[1.3, 0], [2.0, 5], [2.8, 5], [3.5, 12]]) * (1 - pull) - 4 * pull + 7 * creep,
    rz: lerp(-3, -1.5, settleIn) + 1.5 * creep,
    dolly: lerp(-380, -160, settleIn) + keys(t, [[1.3, 0], [2.0, 190], [4.8, 230]]) * (1 - pull) - 520 * pull + 110 * creep,
    focus: lerp(0, 520, pull),
    aperture: lerp(0.6, 1.3, pull),
  };

  const panelIn = easeOutExpo(prog(t, T.hud, 0.35));
  const panelOut = easeInOutCubic(prog(t, T.pullBack - 0.1, 0.4));
  const on = (t0: number) => springy(t - t0, 0.25, 0.3);
  const hi = (t0: number) => clamp(1 - Math.abs(t - t0 - 0.15) / 0.3);
  const setMag = easeInOutCubic(prog(t, T.hud + 0.3, 0.5));
  const mag = lerp(1.25, ZOOM, setMag);
  const panelX = tall ? 0 : lerp(1200, 450, panelIn) + 1000 * panelOut;
  const panelY = tall ? lerp(1000, 330, panelIn) + 700 * panelOut : -175;

  const s = tall ? 0.8 : 1;
  const readout = clamp(prog(t, T.zoomIn - 0.1, 0.2)) * (1 - panelOut);
  return (
    <Space camera={camera}>
      <Plane z={-600} w={CW} h={CH} s={1.5 * s} opacity={0.18} blur={10} style={{ borderRadius: 30, background: C.accent, filter: "blur(80px)" }} />
      <Plane w={CW} h={CH} s={s} style={{ borderRadius: 22, boxShadow: "0 60px 140px rgba(0,0,0,0.55), 0 0 0 1px rgba(255,255,255,0.08)" }}>
        <Canvas w={CW} h={CH} wall="prism" radius={22} corners={16} zoom={zoom} focus={focus} content={<DemoPage ctaPress={press1} cardPress={[0, press2, 0]} />}>
          <ClickRing x={CTA.x} y={CTA.y} t={t} t0={T.click1} size={70} />
          <ClickRing x={CARD.x} y={CARD.y} t={t} t0={T.click2} size={70} />
          <Cursor x={cx} y={cy} press={Math.max(press1, press2)} scale={1.25} opacity={clamp(t / 0.3)} />
        </Canvas>
      </Plane>
      {/* Live status chip: the zoom level counts up, then "Following cursor" joins. */}
      <Plane x={(-CW / 2 + 30) * s + 330 * 1.45 + (tall ? 70 : 0)} y={(-CH / 2 + 8) * s} z={110} w={660} h={68} s={1.45} res={4} sharp opacity={readout} style={{ overflow: "visible" }}>
        <StatusChip zoom={zoom} follow={easeOutExpo(prog(t, T.follow, 0.35))} t={t} />
      </Plane>
      <Plane x={panelX} y={panelY} z={tall ? 260 : 220} ry={tall ? 0 : -14} w={360} h={200} s={tall ? 1.6 : 1.32} opacity={clamp(panelIn * 2) * (1 - panelOut)} sharp style={{ overflow: "visible" }}>
        <SettingsPanel
          title="Zoom"
          tag="EXPERIMENTAL"
          w={360}
          rows={[
            { label: "Auto Zoom", control: <Toggle on={on(T.hud + 0.15)} />, hi: hi(T.hud + 0.1) },
            {
              label: "Zoom magnification",
              control: (
                <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <PanelSlider value={(mag - 1.25) / (3 - 1.25)} w={96} />
                  <div style={{ fontFamily: F.mono, fontSize: 12, width: 38, textAlign: "right", color: C.label }}>{mag.toFixed(2)}×</div>
                </div>
              ),
              hi: hi(T.hud + 0.45),
            },
            { label: "Follow Cursor", control: <Toggle on={on(T.follow - 0.25)} />, hi: hi(T.follow - 0.3) },
          ]}
        />
      </Plane>
    </Space>
  );
};

export const S04Zoom: React.FC = () => {
  const t = useTime();
  const tall = useFormat() === "tall";
  const moving = Math.max(window01(t, T.zoomIn, T.click1 - 0.1, 0.12), window01(t, T.follow, T.follow + 0.62, 0.12), window01(t, T.pullBack, T.pullBack + 0.8, 0.12));
  return (
    <AbsoluteFill>
      <Backdrop glow={0.9} />
      <MotionBlur under={<Backdrop glow={0.9} />} active={moving > 0} amount={moving} samples={10} shutter={0.02}>
        <World />
      </MotionBlur>
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", paddingTop: tall ? 980 : 520 }}>
        <Caption
          lines={tall ? [["Give", "every", "click"], ["its", { text: "close-up.", color: C.accentLight }]] : [["Give", "every", "click", "its", { text: "close-up.", color: C.accentLight }]]}
          t={t}
          t0={T.caption}
          size={tall ? 104 : 96}
          stagger={0.06}
        />
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
