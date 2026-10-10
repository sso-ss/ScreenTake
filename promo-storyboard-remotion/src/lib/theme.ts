// ScreenTake's own palette: Screen/DesignSystem/DesignTokens.swift and website/styles.css.
export const C = {
  accent: "#6C5CE7",
  accentDark: "#5034bf",
  accentLight: "#a79bff",
  markTop: "#998AFF",
  markBottom: "#5B45D6",
  window: "#1c1c1e",
  control: "#2c2c2e",
  input: "#3a3a3c",
  separator: "#1a1a1c",
  inputBorder: "#48484a",
  label: "#e5e5ea",
  label2: "#98989d",
  label3: "#636366",
  chrome: "#2b2b2d",
  panel: "#252527",
  rail: "#29292b",
  preview: "#151516",
  camera: "#60a5fa",
  cursor: "#4ade80",
  keystroke: "#fb923c",
  audio: "#fbbf24",
  warning: "#f59e0b",
  success: "#22c55e",
  close: "#ff5f57",
  minimize: "#febc2e",
  maximize: "#28c840",
  systemBlue: "#0a84ff",
  // Website demo document
  ink: "#211936",
  muted: "#594b6b",
  lavender: "#eee7fc",
  line: "#e1d8ee",
  night: "#0b0b0e",
};

// ClickHighlightColor in Screen/App/CaptureSettings.swift
export const CLICK_COLORS: { name: string; color: string }[] = [
  { name: "White", color: "rgb(255,255,255)" },
  { name: "Yellow", color: "rgb(255,209,46)" },
  { name: "Coral", color: "rgb(255,82,71)" },
  { name: "Green", color: "rgb(64,219,122)" },
  { name: "Blue", color: "rgb(56,148,255)" },
  { name: "Pink", color: "rgb(255,77,173)" },
];

// Gradient presets in Screen/Models/BackgroundStyle.swift, used for the swatch grid.
export const PRESETS: { name: string; stops: string[]; image?: string }[] = [
  { name: "Sonoma", stops: ["#1e1b4b", "#6a3de8", "#f472b6", "#38bdf8"] },
  { name: "Aurora", stops: ["#0c0a1a", "#22d3ee", "#a78bfa", "#042f2e"] },
  { name: "Sunset", stops: ["#1c1917", "#ec4899", "#f97316", "#1e1b4b"] },
  { name: "Ocean", stops: ["#020617", "#0891b2", "#6366f1", "#064e3b"] },
  { name: "Blossom", stops: ["#fdf2f8", "#f9a8d4", "#c4b5fd", "#ede9fe"] },
  { name: "Nebula", stops: ["#0a0a0f", "#7c3aed", "#ec4899", "#0f0518"] },
  { name: "Moss", stops: ["#022c22", "#4ade80", "#22d3ee", "#0c1a0f"] },
  { name: "Dusk", stops: ["#1e1338", "#f472b6", "#818cf8", "#0f172a"] },
  { name: "Prism", stops: [], image: "prism" },
  { name: "Lagoon", stops: [], image: "lagoon" },
  { name: "Ember", stops: [], image: "ember" },
  { name: "Midnight", stops: [], image: "midnight" },
];

export type Wall = "prism" | "lagoon" | "ember" | "midnight";

export const F = {
  sans: '"ST Sans", -apple-system, "SF Pro Display", "Helvetica Neue", Arial, sans-serif',
  mono: '"ST Mono", "SF Mono", ui-monospace, Menlo, monospace',
  rounded: '"ST Rounded", "SF Pro Rounded", ui-rounded, -apple-system, sans-serif',
};
