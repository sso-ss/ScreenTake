import {continueRender, delayRender, staticFile} from 'remotion';
let started = false;
export const loadFonts = () => {
  if (started || typeof document === 'undefined') return;
  started = true;
  const handle = delayRender('Load local production fonts');
  Promise.all([
    ['ST Sans', 'fonts/SFNS.ttf'], ['ST Mono', 'fonts/SFNSMono.ttf'],
  ].map(async ([name, file]) => {
    const font = new FontFace(name, `url(${staticFile(file)})`, {weight: '100 1000'});
    await font.load(); document.fonts.add(font);
  })).then(() => continueRender(handle)).catch(() => continueRender(handle));
};
