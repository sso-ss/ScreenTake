import { lerp } from "./motion";
import { zoomToDolly } from "../components/Space";

/**
 * Split a zoom factor into a real dolly (for perspective) and a flat scale on
 * top, so extreme macro shots don't push the camera through the plane.
 */
export function zoomRig(zoom: number, maxDolly = 1.8, P = 1600) {
  const d = Math.min(zoom, maxDolly);
  return { dolly: zoomToDolly(d, P), scale: zoom / d };
}

/** Log-space interpolation between two zoom factors. */
export const lerpZoom = (a: number, b: number, t: number) => Math.exp(lerp(Math.log(a), Math.log(b), t));
