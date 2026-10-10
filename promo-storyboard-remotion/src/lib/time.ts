import { createContext, useContext } from "react";
import { useCurrentFrame, useVideoConfig } from "remotion";
import TL from "./timeline.json";

export { TL };
export type SceneId = keyof typeof TL.cues;

/** Sub-frame offset (seconds) used by MotionBlur to sample neighbouring instants. */
export const TimeOffset = createContext(0);

/** Local scene time in seconds, including any motion-blur sub-frame offset. */
export function useTime() {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return frame / fps + useContext(TimeOffset);
}

/** Cue times for a scene, as { cueId: seconds }. Shared with scripts/audio.py. */
export function cues<S extends SceneId>(scene: S) {
  const table = TL.cues[scene] as Record<keyof (typeof TL.cues)[S], (number | string)[]>;
  const out = {} as Record<keyof (typeof TL.cues)[S], number>;
  for (const k in table) out[k] = table[k][0] as number;
  return out;
}

export const sceneById = (id: string) => TL.scenes.find((s) => s.id === id)!;

export type Format = "wide" | "tall";
export const FormatContext = createContext<Format>("wide");
export const useFormat = () => useContext(FormatContext);

/** Size of the current composition in world units (the tall cut keeps 1080 wide). */
export function useFrameSize() {
  const { width, height } = useVideoConfig();
  return { w: width, h: height, tall: height > width };
}
