import React, { createContext, useContext } from "react";
import { TimeOffset } from "../lib/time";

// A small CSS-3D camera rig. World units are pixels; the camera looks at
// (x, y, z) from `perspective` px away. `dolly` moves the camera toward the
// target, so on-screen scale at the target is P / (P - dolly).
export type Camera = {
  x?: number;
  y?: number;
  z?: number;
  dolly?: number;
  rx?: number;
  ry?: number;
  rz?: number;
  /** World z that is in focus. */
  focus?: number;
  /** Blur px per 100 px of depth away from focus. */
  aperture?: number;
  maxBlur?: number;
};

type Rig = Required<Camera> & { P: number; scale: number };
const RigContext = createContext<Rig>({ x: 0, y: 0, z: 0, dolly: 0, rx: 0, ry: 0, rz: 0, focus: 0, aperture: 0, maxBlur: 24, P: 1600, scale: 1 });
export const useRig = () => useContext(RigContext);

export const zoomToDolly = (zoom: number, P = 1600) => P - P / zoom;

export const Space: React.FC<{
  camera: Camera;
  perspective?: number;
  scale?: number;
  style?: React.CSSProperties;
  children: React.ReactNode;
}> = ({ camera, perspective = 1600, scale = 1, style, children }) => {
  const rig: Rig = { x: 0, y: 0, z: 0, dolly: 0, rx: 0, ry: 0, rz: 0, focus: 0, aperture: 0, maxBlur: 24, ...camera, P: perspective, scale };
  const transform = [
    `translateZ(${rig.dolly}px)`,
    `rotateX(${rig.rx}deg)`,
    `rotateY(${rig.ry}deg)`,
    `rotateZ(${rig.rz}deg)`,
    scale !== 1 ? `scale3d(${scale},${scale},${scale})` : "",
    `translate3d(${-rig.x}px, ${-rig.y}px, ${-rig.z}px)`,
  ].join(" ");
  return (
    <div style={{ position: "absolute", inset: 0, perspective, perspectiveOrigin: "50% 50%", overflow: "hidden", ...style }}>
      <div style={{ position: "absolute", left: "50%", top: "50%", width: 0, height: 0, transformStyle: "preserve-3d", transform }}>
        <RigContext.Provider value={rig}>{children}</RigContext.Provider>
      </div>
    </div>
  );
};

/** Depth-of-field blur for something at world z. */
export function useDof(z: number, extra = 0) {
  const rig = useRig();
  return Math.min(rig.maxBlur, (rig.aperture * Math.abs(z - rig.focus)) / 100) + extra;
}

type PlaneProps = {
  x?: number;
  y?: number;
  z?: number;
  rx?: number;
  ry?: number;
  rz?: number;
  s?: number;
  w: number;
  h: number;
  /** Always sharp (captions, HUD). */
  sharp?: boolean;
  blur?: number;
  opacity?: number;
  /** Layout resolution: content is laid out at res× and scaled back, so it rasterises sharply when the camera is close. */
  res?: number;
  /** Transparent margin around the box so spilled shadows are not clipped by the layer. */
  bleed?: number;
  style?: React.CSSProperties;
  children?: React.ReactNode;
};

/** A flat, centred card placed in the world. Blur follows the camera's focus. */
/** Approximate on-screen magnification of something at world z with scale s. */
export function useScreenScale(z: number, s = 1) {
  const rig = useRig();
  const dist = Math.max(80, rig.P - rig.dolly - (z - rig.z) * rig.scale);
  return (rig.scale * s * rig.P) / dist;
}

// Raster resolution for a plane. Kept modest: CSS shadows are scaled by it too, and
// very large blur radii make Chrome fall back to hard, blocky shadows.
const autoRes = (k: number) => Math.min(12, Math.max(1, Math.ceil(k * 1.15 * 4) / 4));

export const Plane: React.FC<PlaneProps> = ({ x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, s = 1, w, h, sharp, blur = 0, opacity = 1, res: resProp, bleed = 0, style, children }) => {
  const dof = useDof(z, blur);
  const screen = useScreenScale(z, s);
  const res = resProp ?? autoRes(screen);
  const b = (sharp ? blur : dof) * res;
  if (opacity <= 0.001) return null;
  const W = w + bleed * 2;
  const H = h + bleed * 2;
  const box: React.CSSProperties = { position: "absolute", left: bleed * res, top: bleed * res, width: w, height: h };
  const inner = res === 1 ? (bleed ? <div style={box}>{children}</div> : children) : <div style={{ ...box, zoom: res, left: bleed, top: bleed }}>{children}</div>;
  return (
    <div
      style={{
        position: "absolute",
        left: (-W * res) / 2,
        top: (-H * res) / 2,
        width: W * res,
        height: H * res,
        transform: `translate3d(${x}px, ${y}px, ${z}px) rotateZ(${rz}deg) rotateX(${rx}deg) rotateY(${ry}deg) scale(${s / res})`,
        filter: b > 0.25 ? `blur(${b.toFixed(2)}px)` : undefined,
        opacity,
        ...style,
        borderRadius: style?.borderRadius !== undefined ? Number(style.borderRadius) * res : undefined,
        boxShadow: undefined,
      }}
    >
      {style?.boxShadow && <div style={{ position: "absolute", left: bleed * res, top: bleed * res, width: w * res, height: h * res, borderRadius: Number(style.borderRadius ?? 0) * res, boxShadow: scaleShadow(String(style.boxShadow), res) }} />}
      {inner}
    </div>
  );
};

const scaleShadow = (shadow: string, k: number) => (k === 1 ? shadow : shadow.replace(/(-?\d*\.?\d+)px/g, (_, n) => `${Number(n) * k}px`));

/** A 3D group: children keep their own depth (no blur/opacity allowed here). */
export const Group: React.FC<{ x?: number; y?: number; z?: number; rx?: number; ry?: number; rz?: number; s?: number; children: React.ReactNode }> = ({
  x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, s = 1, children,
}) => (
  <div
    style={{
      position: "absolute",
      left: 0,
      top: 0,
      transformStyle: "preserve-3d",
      transform: `translate3d(${x}px, ${y}px, ${z}px) rotateZ(${rz}deg) rotateX(${rx}deg) rotateY(${ry}deg) scale3d(${s},${s},${s})`,
    }}
  >
    {children}
  </div>
);

/**
 * Motion blur by averaging sub-frame samples: copy i is drawn at opacity
 * 1/(i+1), which weights all copies equally. That average is only exact when
 * every copy is opaque, so pass the scene's backdrop as `under`; it is drawn
 * inside each copy. (With transparent copies, anti-aliased text edges and
 * shadows accumulate, and everything turns heavier while the blur is on.)
 */
export const MotionBlur: React.FC<{ active: boolean; amount?: number; samples?: number; shutter?: number; under?: React.ReactNode; children: React.ReactNode }> = ({
  active, amount = 1, samples = 7, shutter: shutterFull = 0.028, under, children,
}) => {
  const base = useContext(TimeOffset);
  // Fade the shutter (amount) rather than switching it, so blur never pops on or off.
  const shutter = shutterFull * amount;
  if (!active || amount < 0.02) return <>{children}</>;
  return (
    <div style={{ position: "absolute", inset: 0 }}>
      {Array.from({ length: samples }, (_, i) => (
        <TimeOffset.Provider key={i} value={base + (i / (samples - 1) - 0.5) * shutter}>
          <div style={{ position: "absolute", inset: 0, opacity: 1 / (i + 1) }}>
            {under}
            {children}
          </div>
        </TimeOffset.Provider>
      ))}
      {/* Cross-fade to the plain frame at the window edges: stacked copies come out
          ~1% darker from 8-bit rounding, so a hard switch would visibly pop. */}
      {amount < 1 && (
        <div style={{ position: "absolute", inset: 0, opacity: 1 - amount }}>
          {under}
          {children}
        </div>
      )}
    </div>
  );
};

/** Plain absolutely positioned box in 2D screen space. */
export const Abs: React.FC<{ x?: number; y?: number; w?: number; h?: number; style?: React.CSSProperties; children?: React.ReactNode }> = ({ x = 0, y = 0, w, h, style, children }) => (
  <div style={{ position: "absolute", left: x, top: y, width: w, height: h, ...style }}>{children}</div>
);
