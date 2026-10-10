import React from "react";

// Stroke icons redrawn after the SF Symbols the app uses. 24-unit grid.
type P = { size?: number; color?: string; stroke?: number; style?: React.CSSProperties };
const S: React.FC<P & { children: React.ReactNode; fill?: boolean }> = ({ size = 16, color = "currentColor", stroke = 1.8, style, children, fill }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill={fill ? color : "none"} stroke={fill ? "none" : color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round" style={{ display: "block", flexShrink: 0, ...style }}>
    {children}
  </svg>
);

export const IFolder = (p: P) => <S {...p}><path d="M3 7.5a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /></S>;
export const ICanvas = (p: P) => <S {...p}><rect x="3" y="5" width="18" height="14" rx="2.5" /><rect x="6" y="8" width="12" height="8" rx="1" fill={p.color ?? "currentColor"} stroke="none" /></S>;
export const ICursor = (p: P) => <S {...p} fill><path d="M6 3v15.5l4.2-4 2.9 6.4 2.4-1.1-2.8-6.3H18.5z" /></S>;
export const ICamera = (p: P) => <S {...p} fill><rect x="2.5" y="6" width="13.5" height="12" rx="2.5" /><path d="M17 10.5 21.5 8v8L17 13.5z" /></S>;
export const IAudio = (p: P) => <S {...p}><path d="M4 10v4M7.5 7v10M11 4v16M14.5 8v8M18 6v12M21.5 10.5v3" /></S>;
export const IOutput = (p: P) => <S {...p}><path d="M12 3v11M8 7l4-4 4 4M6 11H5v9h14v-9h-1" /></S>;
export const IRatio = (p: P) => <S {...p}><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M3 10h8v9" /></S>;
export const ICorners = (p: P) => <S {...p}><rect x="3" y="6" width="18" height="12" rx="4" /></S>;
export const IDesktop = (p: P) => <S {...p}><rect x="2.5" y="4.5" width="19" height="15" rx="2" /><path d="M2.5 8.5h19M5 6.5h.01M7 6.5h.01M9 6.5h.01" /></S>;
export const IPhone = (p: P) => <S {...p}><rect x="7" y="2.5" width="10" height="19" rx="2.2" /><path d="M10.5 5h3" /></S>;
export const IScissors = (p: P) => <S {...p}><circle cx="6" cy="6.5" r="2.6" /><circle cx="6" cy="17.5" r="2.6" /><path d="M8.2 8 20 18M8.2 16 20 6" /></S>;
export const ISilence = (p: P) => <S {...p}><path d="M3 10.5v3M6 8v8M9 5v14M12 9v6" /><path d="M15 12h1M18 12h1M21 12h.5" /></S>;
export const ITrash = (p: P) => <S {...p}><path d="M4 7h16M9 7V4.5h6V7M6 7l1 13h10l1-13" /></S>;
export const IUndo = (p: P) => <S {...p}><path d="M9 14 4 9l5-5" /><path d="M4 9h10a6 6 0 0 1 0 12h-3" /></S>;
export const IRedo = (p: P) => <S {...p}><path d="m15 14 5-5-5-5" /><path d="M20 9H10a6 6 0 0 0 0 12h3" /></S>;
export const IPlay = (p: P) => <S {...p} fill><path d="M7 4.5v15l12.5-7.5z" /></S>;
export const ISkipBack = (p: P) => <S {...p} fill><path d="M6 5h2.4v14H6zM20 5v14L9.5 12z" /></S>;
export const ISkipFwd = (p: P) => <S {...p} fill><path d="M18 5h-2.4v14H18zM4 5v14l10.5-7z" /></S>;
export const IMinus = (p: P) => <S {...p}><circle cx="10.5" cy="10.5" r="6.5" /><path d="M7.5 10.5h6M15.5 15.5 20 20" /></S>;
export const IPlus = (p: P) => <S {...p}><circle cx="10.5" cy="10.5" r="6.5" /><path d="M7.5 10.5h6M10.5 7.5v6M15.5 15.5 20 20" /></S>;
export const IClose = (p: P) => <S {...p}><path d="M6 6l12 12M18 6 6 18" /></S>;
export const ICheck = (p: P) => <S {...p}><path d="m5 12.5 4.5 4.5L19 7.5" /></S>;
export const IChevL = (p: P) => <S {...p}><path d="m14.5 5-7 7 7 7" /></S>;
export const IChevR = (p: P) => <S {...p}><path d="m9.5 5 7 7-7 7" /></S>;
export const IUpDown = (p: P) => <S {...p}><path d="m8 9 4-4 4 4M8 15l4 4 4-4" /></S>;
export const IDownload = (p: P) => <S {...p}><path d="M12 4v11M8 11l4 4 4-4M5 19h14" /></S>;
export const IReset = (p: P) => <S {...p}><path d="M4 12a8 8 0 1 0 2.4-5.7L4 8.5" /><path d="M4 4v4.5h4.5" /></S>;
export const IPerson = (p: P) => <S {...p} fill><circle cx="12" cy="8" r="4" /><path d="M4 20c.5-4 3.8-6 8-6s7.5 2 8 6z" /></S>;
export const IMic = (p: P) => <S {...p}><rect x="9" y="3" width="6" height="11" rx="3" /><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21" /></S>;
export const ISpeaker = (p: P) => <S {...p}><path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z" /><path d="M15.5 9a4.5 4.5 0 0 1 0 6M18 6.5a8 8 0 0 1 0 11" /></S>;
export const IDisplay = (p: P) => <S {...p}><rect x="3" y="4.5" width="18" height="12" rx="1.8" /><path d="M9 20h6M12 16.5V20" /></S>;
export const IWindow = (p: P) => <S {...p}><rect x="3" y="5" width="18" height="14" rx="2" /><path d="M3 9h18M5.8 7h.01M8 7h.01M10.2 7h.01" /></S>;
export const IXCircle = (p: P) => <S {...p} fill><circle cx="12" cy="12" r="10" /><path d="M8.5 8.5l7 7M15.5 8.5l-7 7" stroke="#2a2a2c" strokeWidth={2.2} /></S>;
export const IArrowRight = (p: P) => <S {...p}><path d="M5 12h14M13 6l6 6-6 6" /></S>;
export const IApple = (p: P) => (
  <S {...p} fill>
    <path d="M16.4 12.6c0-2.3 1.9-3.4 2-3.5-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.1-2.8.9-3.5.9s-1.8-.9-3-.8C7 7.4 5.6 8.3 4.8 9.7c-1.6 2.8-.4 6.9 1.2 9.2.8 1.1 1.7 2.3 2.9 2.3 1.1 0 1.6-.7 3-.7s1.8.7 3 .7 2-1.1 2.8-2.3c.9-1.3 1.2-2.5 1.3-2.6-.1 0-2.5-1-2.6-3.7zM14.1 5.7c.6-.8 1.1-1.8 1-2.9-.9 0-2.1.6-2.7 1.4-.6.7-1.1 1.8-1 2.8 1 .1 2.1-.5 2.7-1.3z" />
  </S>
);
