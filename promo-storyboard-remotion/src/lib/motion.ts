// Deterministic easing and motion helpers. All times are in seconds.
export const clamp = (v: number, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
export const prog = (t: number, start: number, dur: number) => clamp((t - start) / dur);

export const easeOutCubic = (x: number) => 1 - (1 - clamp(x)) ** 3;
export const easeInCubic = (x: number) => clamp(x) ** 3;
export const easeInOutCubic = (x: number) => {
  const v = clamp(x);
  return v < 0.5 ? 4 * v * v * v : 1 - (-2 * v + 2) ** 3 / 2;
};
export const easeOutExpo = (x: number) => (clamp(x) >= 1 ? 1 : 1 - 2 ** (-10 * clamp(x)));
export const easeInOutQuint = (x: number) => {
  const v = clamp(x);
  return v < 0.5 ? 16 * v ** 5 : 1 - (-2 * v + 2) ** 5 / 2;
};
export const smoothstep = (x: number) => {
  const v = clamp(x);
  return v * v * (3 - 2 * v);
};

/** Critically damped step response (no overshoot), settling in about `dur`. */
export const settle = (t: number, dur: number) => {
  if (t <= 0) return 0;
  const w = 7 / dur;
  return clamp(1 - (1 + w * t) * Math.exp(-w * t));
};

/** Under-damped spring step: overshoots once, then rests. */
export const springy = (t: number, dur = 0.6, bounce = 0.35) => {
  if (t <= 0) return 0;
  if (t >= dur * 1.6) return 1;
  const w = 9 / dur;
  const zeta = 1 - bounce;
  const wd = w * Math.sqrt(1 - zeta * zeta);
  return 1 - Math.exp(-zeta * w * t) * (Math.cos(wd * t) + (zeta * w / wd) * Math.sin(wd * t));
};

/** Interpolate keyframes [[time, value], ...] with an easing between each pair. */
export const keys = (t: number, frames: [number, number][], ease = easeInOutCubic) => {
  if (t <= frames[0][0]) return frames[0][1];
  for (let i = 1; i < frames.length; i++) {
    const [t1, v1] = frames[i];
    const [t0, v0] = frames[i - 1];
    if (t <= t1) return lerp(v0, v1, ease((t - t0) / (t1 - t0)));
  }
  return frames[frames.length - 1][1];
};

export type Squash = { dy: number; sx: number; sy: number };
export const REST: Squash = { dy: 0, sx: 1, sy: 1 };

/**
 * Anticipation hop from the Rive reference study: squash 0.12 s, air 0.22 s,
 * settle 0.18 s. Volume is roughly preserved (sx ≈ 1/sy).
 */
export const hop = (t: number, t0: number, height = 40, amount = 1): Squash => {
  const s = t - t0;
  const SQ = 0.12, AIR = 0.22, SET = 0.18;
  if (s < 0 || s > SQ + AIR + SET) return REST;
  if (s < SQ) {
    const p = Math.sin((s / SQ) * Math.PI / 2);
    const sy = 1 - 0.12 * amount * p;
    return { dy: 0, sx: 1 / Math.sqrt(sy), sy };
  }
  if (s < SQ + AIR) {
    const p = (s - SQ) / AIR;
    const sy = 1 + 0.07 * amount * Math.cos(p * Math.PI);
    return { dy: -height * Math.sin(p * Math.PI), sx: 1 / Math.sqrt(sy), sy };
  }
  const p = (s - SQ - AIR) / SET;
  const sy = 1 - 0.09 * amount * Math.sin(p * Math.PI) * (1 - p * 0.4);
  return { dy: 0, sx: 1 / Math.sqrt(sy), sy };
};

/** Combine several hops (only one is active at a time). */
export const hops = (t: number, starts: number[], height = 40, amount = 1): Squash => {
  for (const t0 of starts) {
    const h = hop(t, t0, height, amount);
    if (h !== REST) return h;
  }
  return REST;
};

/** A small squash-and-settle used when the cat changes pose in place. */
export const poseSettle = (t: number, t0: number, amount = 1): Squash => {
  const s = t - t0;
  if (s < 0 || s > 0.42) return REST;
  const sy = 1 - 0.08 * amount * Math.sin((s / 0.42) * Math.PI * 2) * Math.exp(-s * 5);
  return { dy: 0, sx: 1 / Math.sqrt(sy), sy };
};

/** Arc between two points; `lift` raises the midpoint. */
export const arc = (a: { x: number; y: number }, b: { x: number; y: number }, p: number, lift: number) => ({
  x: lerp(a.x, b.x, p),
  y: lerp(a.y, b.y, p) - lift * Math.sin(Math.PI * p),
});

/** 0→1→0 over [a, b] with smooth ramps of length r; for easing effects in and out. */
export const window01 = (t: number, a: number, b: number, r: number) => smoothstep(clamp((t - a) / r)) * smoothstep(clamp((b - t) / r));
