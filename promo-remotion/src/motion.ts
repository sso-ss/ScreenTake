export const clamp = (x: number, a = 0, b = 1) => Math.max(a, Math.min(b, x));
export const mix = (a: number, b: number, t: number) => a + (b - a) * t;
export const smooth = (x: number) => { const p = clamp(x); return p * p * (3 - 2 * p); };
export const out = (x: number) => 1 - (1 - clamp(x)) ** 4;
export const during = (t: number, start: number, duration: number) => smooth((t - start) / duration);
export const arrive = (t: number, start = 0.15, duration = 0.5) => out((t - start) / duration);
export const pulse = (t: number, at: number, duration = 0.55) => clamp((t - at) / duration);
export const finite = (x: number) => Number.isFinite(x) ? x : 0;
