export const C = {
  ink: '#111016', stage: '#09090e', plum: '#20132f', accent: '#6C5CE7', light: '#b9adff',
  text: '#f5f3fa', muted: '#aaa4b8', teal: '#6bd8da', border: '#42404c',
};
export const FONT = 'ST Sans, -apple-system, BlinkMacSystemFont, Arial, sans-serif';
export const MONO = 'ST Mono, ui-monospace, monospace';
export const scenes = [
  {id: 'Promise', start: 0, duration: 4, title: 'The promise'},
  {id: 'Record', start: 4, duration: 4, title: 'Start recording'},
  {id: 'Zoom', start: 8, duration: 7, title: 'Give every click its close-up'},
  {id: 'Cursor', start: 15, duration: 4, title: 'Make every click clear'},
  {id: 'Edit', start: 19, duration: 7, title: 'Keep the good parts'},
  {id: 'Voiceover', start: 26, duration: 7, title: 'Add your voice after'},
  {id: 'Frame', start: 33, duration: 6, title: 'Frame it your way'},
  {id: 'Result', start: 39, duration: 5, title: 'Ready to show'},
  {id: 'End', start: 44, duration: 4, title: 'ScreenTake'},
] as const;
export type SceneID = typeof scenes[number]['id'];
