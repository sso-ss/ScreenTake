import React from "react";
import { AbsoluteFill, Img, staticFile, useCurrentFrame } from "remotion";
import { C, type Wall } from "../lib/theme";

export const wallSrc = (w: Wall) => staticFile(`wallpapers/${w}.jpg`);

/** The dark stage everything floats in; optionally a soft, blown-up wallpaper. */
export const Backdrop: React.FC<{ wall?: Wall; wallOpacity?: number; blur?: number; scale?: number; x?: number; y?: number; glow?: number }> = ({
  wall, wallOpacity = 1, blur = 0, scale = 1.05, x = 0, y = 0, glow = 0.5,
}) => (
  <AbsoluteFill style={{ background: C.night, overflow: "hidden" }}>
    <AbsoluteFill
      style={{
        background: `radial-gradient(60% 55% at 50% 58%, rgba(108,92,231,${0.22 * glow}), rgba(108,92,231,0) 70%)`,
      }}
    />
    {wall && wallOpacity > 0 && (
      <Img
        src={wallSrc(wall)}
        style={{
          position: "absolute",
          inset: 0,
          width: "100%",
          height: "100%",
          objectFit: "cover",
          opacity: wallOpacity,
          filter: blur > 0 ? `blur(${blur}px)` : undefined,
          transform: `translate(${x}px, ${y}px) scale(${scale})`,
        }}
      />
    )}
    <Vignette />
  </AbsoluteFill>
);

export const Vignette: React.FC<{ strength?: number }> = ({ strength = 0.55 }) => (
  <AbsoluteFill style={{ background: `radial-gradient(120% 95% at 50% 50%, rgba(0,0,0,0) 55%, rgba(0,0,0,${strength}) 100%)`, pointerEvents: "none" }} />
);

/** Film grain over the whole film; the tile jumps every frame. */
export const Grain: React.FC<{ opacity?: number }> = ({ opacity = 0.075 }) => {
  const f = useCurrentFrame();
  const ox = (f * 173) % 512;
  const oy = (f * 311) % 512;
  return (
    <AbsoluteFill
      style={{
        backgroundImage: `url(${staticFile("images/grain.png")})`,
        backgroundPosition: `${ox}px ${oy}px`,
        mixBlendMode: "overlay",
        opacity,
        pointerEvents: "none",
      }}
    />
  );
};
