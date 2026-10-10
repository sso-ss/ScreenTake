import React from "react";
import { AbsoluteFill, Img, staticFile } from "remotion";
import { Backdrop } from "../components/Backdrop";
import { Hud } from "../components/Fx";
import { IApple } from "../components/Icons";
import { Plane, Space } from "../components/Space";
import { C, F } from "../lib/theme";
import { clamp, easeInCubic, easeInOutCubic, easeOutExpo, keys, lerp, prog, springy } from "../lib/motion";
import { cues, useFormat, useTime } from "../lib/time";

// 42.4–48 s. "ScreenTake for ___" ticks through the features on the beat,
// the two lines close into one point, and the mark pulls into focus.
const T = cues("s09");
const WORDS = ["RECORDING", "ZOOM", "CURSORS", "CAMERA", "AUDIO", "EDITING", "YOUR NEXT DEMO."];
const W_AT = [T.w0, T.w1, T.w2, T.w3, T.w4, T.w5, T.w6];

const Word: React.FC<{ text: string; size: number; color: string }> = ({ text, size, color }) => (
  <div style={{ width: "100%", height: "100%", display: "flex", alignItems: "center", justifyContent: "center", fontFamily: F.sans, fontWeight: 850, fontSize: size, letterSpacing: "0.005em", lineHeight: 1, color, whiteSpace: "nowrap" }}>{text}</div>
);

const World: React.FC = () => {
  const t = useTime();
  const tall = useFormat() === "tall";
  const close = easeInOutCubic(prog(t, T.close, 0.55));
  const mark = easeOutExpo(prog(t, T.mark, 0.9));
  const wordSize = tall ? 104 : 150;
  const leadSize = tall ? 64 : 76;
  const gap = tall ? 96 : 110;
  const camera = {
    dolly: keys(t, [[0, 0], [T.close, 90], [T.mark, 40], [5.6, 120]], easeInOutCubic),
    rx: keys(t, [[0, 6], [T.close, 2], [5.6, 0]], easeInOutCubic),
    ry: keys(t, [[0, -5], [T.close, 3], [5.6, 0]], easeInOutCubic),
    y: tall ? 0 : 20,
    focus: 0,
    aperture: 1.4,
  };
  // Lines close toward the centre line and squash away.
  const squash = 1 - close;
  const lead = (
    <Plane y={-gap * squash - 20 * close} w={1400} h={leadSize * 1.3} opacity={1 - clamp(close * 1.4)} s={lerp(1, 0.9, close)}>
      <Word text="ScreenTake for" size={leadSize} color={C.label2} />
    </Plane>
  );
  const words = WORDS.map((w, i) => {
    const t0 = W_AT[i];
    const t1 = W_AT[i + 1] ?? 99;
    if (t < t0 - 0.01 || t > t1 + 0.3) return null;
    const inP = easeOutExpo(prog(t, t0, 0.26));
    const outP = easeInCubic(prog(t, t1 - 0.02, 0.14));
    const z = lerp(520, 0, inP) - 1400 * outP;
    const last = i === WORDS.length - 1;
    const o = clamp((t - t0 - 0.03) / 0.1) * (1 - outP) * (last ? 1 - clamp(close * 1.3) : 1);
    return (
      <Plane key={w} y={gap * 0.45 * squash + 10 * close} z={z} rx={lerp(-24, 0, inP)} w={1800} h={wordSize * 1.25} opacity={o} s={last ? lerp(1, 0.6, close) : 1} style={{ transformOrigin: "50% 50%" }}>
        <div style={{ width: "100%", height: "100%", transform: `scaleY(${lerp(1, 0.05, close)})` }}>
          <Word text={w} size={wordSize} color={last ? C.accentLight : "white"} />
        </div>
      </Plane>
    );
  });
  // A thin light seam where the lines met.
  const seam = Math.sin(clamp((t - T.close - 0.25) / 0.6) * Math.PI);
  const markSize = tall ? 170 : 160;
  const brand = t >= T.mark - 0.05 && (
    <>
      <Plane y={tall ? -250 : -190} z={lerp(-500, 0, mark)} w={markSize} h={markSize} blur={18 * (1 - mark)} opacity={clamp(mark * 3)} style={{ borderRadius: markSize * 0.27, boxShadow: `0 30px 90px rgba(108,92,231,${0.55 * mark})` }}>
        <Img src={staticFile("images/mark.svg")} style={{ width: "100%", height: "100%" }} />
      </Plane>
      <Plane y={tall ? -50 : -12} z={lerp(-260, 0, mark)} w={1000} h={170} blur={14 * (1 - mark)} opacity={clamp(mark * 2.5)}>
        <Word text="ScreenTake" size={tall ? 136 : 140} color="white" />
      </Plane>
    </>
  );
  return (
    <Space camera={camera}>
      <Plane z={-700} w={1600} h={900} opacity={0.5 + 0.4 * mark} style={{ background: "radial-gradient(closest-side, rgba(108,92,231,0.45), rgba(108,92,231,0))" }} />
      {lead}
      {words}
      {seam > 0.01 && <Plane y={10} z={10} w={1400 * seam} h={3} sharp opacity={seam} style={{ background: "linear-gradient(90deg, transparent, #c9c1ff, transparent)", boxShadow: "0 0 30px rgba(167,155,255,0.9)" }} />}
      {brand}
    </Space>
  );
};

export const S09End: React.FC = () => {
  const t = useTime();
  const tall = useFormat() === "tall";
  const tag = easeOutExpo(prog(t, T.mark + 0.3, 0.7));
  const btn = springy(t - T.button, 0.5, 0.35);
  const fine = easeOutExpo(prog(t, T.button + 0.1, 0.6));
  const top = tall ? 1130 : 690;
  return (
    <AbsoluteFill>
      <Backdrop glow={0.5} />
      <World />
      <div style={{ position: "absolute", left: 0, right: 0, top, display: "flex", flexDirection: "column", alignItems: "center", gap: tall ? 48 : 36, fontFamily: F.sans }}>
        <div style={{ fontSize: tall ? 50 : 40, fontWeight: 600, letterSpacing: "-0.02em", color: C.label, opacity: tag, transform: `translateY(${(1 - tag) * 24}px)`, filter: tag < 1 ? `blur(${(1 - tag) * 8}px)` : undefined }}>
          Go ahead. <span style={{ color: C.accentLight }}>Make a better take.</span>
        </div>
        <div style={{ height: tall ? 88 : 72, padding: tall ? "0 40px" : "0 32px", borderRadius: 999, background: `linear-gradient(180deg, #7d6ef0, ${C.accent})`, display: "flex", alignItems: "center", gap: 14, color: "white", fontSize: tall ? 32 : 26, fontWeight: 650, opacity: clamp(btn * 3), transform: `scale(${0.7 + 0.3 * btn})`, boxShadow: "0 18px 50px rgba(108,92,231,0.5), inset 0 1px 0 rgba(255,255,255,0.35)" }}>
          <IApple size={tall ? 32 : 26} color="white" /> Download Mac beta
        </div>
        <Hud size={tall ? 18 : 15} color={C.label3} style={{ opacity: fine }}>Experimental beta · Apple Silicon · macOS 13+</Hud>
        <Hud size={tall ? 18 : 15} color={C.label2} style={{ opacity: fine, marginTop: tall ? -20 : -20 }}>Smart zoom is experimental</Hud>
      </div>
    </AbsoluteFill>
  );
};
