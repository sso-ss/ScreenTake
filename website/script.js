'use strict';

const navigation = document.getElementById('nav-links');
const menuToggle = document.querySelector('.menu-toggle');
function closeNavigation() {
  navigation.classList.remove('open');
  menuToggle.setAttribute('aria-expanded', 'false');
  menuToggle.setAttribute('aria-label', 'Open navigation');
}
menuToggle.addEventListener('click', () => {
  const open = navigation.classList.toggle('open');
  menuToggle.setAttribute('aria-expanded', String(open));
  menuToggle.setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
});
navigation.querySelectorAll('a').forEach(link => link.addEventListener('click', closeNavigation));
document.addEventListener('keydown', event => {
  if (event.key === 'Escape' && navigation.classList.contains('open')) {
    closeNavigation();
    menuToggle.focus();
  }
});
window.matchMedia('(min-width: 861px)').addEventListener('change', event => {
  if (event.matches) closeNavigation();
});

document.querySelector('.zoom-toggle').addEventListener('click', event => {
  stopFocusGuide();
  const button = event.currentTarget;
  const zoomed = button.getAttribute('aria-pressed') !== 'true';
  button.setAttribute('aria-pressed', String(zoomed));
  button.querySelector('span').textContent = zoomed ? 'Smart zoom on' : 'Try smart zoom';
  document.querySelector('.focus-visual').classList.toggle('is-zoomed', zoomed);
});

document.querySelectorAll('[data-background]').forEach(button => button.addEventListener('click', () => {
  document.querySelectorAll('[data-background]').forEach(option => {
    const selected = option === button;
    option.classList.toggle('selected', selected);
    option.setAttribute('aria-pressed', String(selected));
  });
  document.getElementById('canvas-frame').style.backgroundImage = `url('assets/${button.dataset.background}.png')`;
  document.getElementById('background-name').textContent = button.dataset.background[0].toUpperCase() + button.dataset.background.slice(1);
}));
document.querySelectorAll('button[data-ratio]').forEach(button => button.addEventListener('click', () => {
  document.querySelectorAll('button[data-ratio]').forEach(option => {
    const selected = option === button;
    option.classList.toggle('selected', selected);
    option.setAttribute('aria-pressed', String(selected));
  });
  document.getElementById('canvas-frame').dataset.ratio = button.dataset.ratio;
}));

// Native dialogs keep keyboard focus contained and Escape closes them.
const downloadDialog = document.getElementById('download-dialog');
const promoDialog = document.getElementById('promo-dialog');
let downloadOpener;
let promoOpener;
function normalActivation(event) {
  return !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey;
}
document.querySelectorAll('[data-download]').forEach(link => link.addEventListener('click', event => {
  if (!normalActivation(event)) return;
  event.preventDefault();
  downloadOpener = event.currentTarget;
  downloadDialog.showModal();
  syncDemoPlayback();
}));
[downloadDialog, promoDialog].forEach(dialog => {
  dialog.querySelector('.close-dialog').addEventListener('click', () => dialog.close());
  dialog.addEventListener('click', event => {
    const rect = dialog.getBoundingClientRect();
    if (event.target === dialog && (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom)) dialog.close();
  });
});
downloadDialog.addEventListener('close', () => downloadOpener?.focus());

const video = promoDialog.querySelector('video');
const audio = promoDialog.querySelector('audio');
const status = promoDialog.querySelector('.promo-status');
function playbackError(error) {
  if (!promoDialog.open || error.name === 'AbortError') return;
  status.textContent = error.name === 'NotAllowedError' ? 'Press Play to start the film.' : 'The film could not play. Try reopening it or reloading the page.';
  status.hidden = false;
}
function syncAudio() {
  if (Math.abs(audio.currentTime - video.currentTime) > .15) audio.currentTime = video.currentTime;
  audio.muted = video.muted;
  audio.volume = video.volume;
  audio.playbackRate = video.playbackRate;
}
document.querySelector('[data-promo]').addEventListener('click', event => {
  if (!normalActivation(event)) return;
  event.preventDefault();
  promoOpener = event.currentTarget;
  status.hidden = true;
  promoDialog.showModal();
  syncDemoPlayback();
  syncAudio();
  video.play().catch(playbackError);
});
video.addEventListener('play', () => {
  syncAudio();
  audio.play().catch(playbackError);
});
video.addEventListener('pause', () => audio.pause());
video.addEventListener('seeking', () => { audio.currentTime = video.currentTime; });
video.addEventListener('timeupdate', syncAudio);
video.addEventListener('volumechange', syncAudio);
video.addEventListener('ratechange', syncAudio);
[video, audio].forEach(media => media.addEventListener('error', () => playbackError({ name: 'MediaError' })));
promoDialog.addEventListener('close', () => {
  video.pause();
  audio.pause();
  video.currentTime = 0;
  audio.currentTime = 0;
  status.hidden = true;
  promoOpener?.focus();
});

// The live editor uses the same controls for guided playback and hands-on editing.
const demoFrame = document.getElementById('hero-demo');
const demoToggle = document.querySelector('.demo-toggle');
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const presenterVideos = [...document.querySelectorAll('.presenter-video')];
const visiblePresenters = new Set();
function syncPresenterPlayback() {
  const wantsPlayback = !reducedMotion.matches;
  const canPlay = wantsPlayback && !document.hidden && !promoDialog.open && !downloadDialog.open;
  presenterVideos.forEach(clip => {
    if (canPlay && visiblePresenters.has(clip)) clip.play().catch(() => {});
    else clip.pause();
  });
}
const presenterObserver = new IntersectionObserver(entries => {
  entries.forEach(entry => {
    if (entry.isIntersecting) visiblePresenters.add(entry.target);
    else visiblePresenters.delete(entry.target);
  });
  syncPresenterPlayback();
}, {threshold:.1});
presenterVideos.forEach(clip => presenterObserver.observe(clip));
let demoVisible = false;
let demoUserIntent = null;
let demoRunning = false;
function syncDemoPlayback() {
  syncPresenterPlayback();
  syncFeatureMotion();
  const wantsPlayback = demoUserIntent ?? !reducedMotion.matches;
  demoRunning = wantsPlayback && demoVisible && !document.hidden && !promoDialog.open && !downloadDialog.open;
  demoFrame.contentWindow?.postMessage({type:'screentake-demo-playback',playing:demoRunning}, window.location.origin);
  demoToggle.textContent = demoRunning ? 'Pause demo' : 'Play demo';
  demoToggle.setAttribute('aria-pressed', String(demoRunning));
}
demoToggle.addEventListener('click', () => {
  demoUserIntent = !demoRunning;
  syncDemoPlayback();
});
window.addEventListener('message', event => {
  if (event.origin !== window.location.origin || event.source !== demoFrame.contentWindow) return;
  if (event.data?.type === 'screentake-demo-ready') syncDemoPlayback();
  if (event.data?.type === 'screentake-demo-interaction') {
    demoUserIntent = false;
    syncDemoPlayback();
  }
});
demoFrame.addEventListener('load', syncDemoPlayback);
new IntersectionObserver(entries => {
  demoVisible = entries[0].isIntersecting;
  syncDemoPlayback();
}, {threshold:.15}).observe(demoFrame);
document.addEventListener('visibilitychange', syncDemoPlayback);
reducedMotion.addEventListener('change', syncDemoPlayback);
[downloadDialog, promoDialog].forEach(dialog => dialog.addEventListener('close', syncDemoPlayback));


// Small product demonstrations share the page's visibility and motion preferences.
const focusStage = document.querySelector('.focus-visual');
const focusDocument = focusStage.querySelector('.focus-document');
const featurePointer = focusStage.querySelector('.feature-pointer');
const clickRing = featurePointer.querySelector('.pointer-click');
const zoomToggle = document.querySelector('.zoom-toggle');
const timelineStage = document.querySelector('.timeline-visual');
const timelineHead = timelineStage.querySelector('.timeline-playhead');
const timelineTime = timelineStage.querySelector('.timeline-time');
const timelineCursor = timelineStage.querySelector('.timeline-edit-cursor');
const trimGap = timelineStage.querySelector('.timeline-trim-gap');
const secondTake = timelineStage.querySelector('.narration-take:last-child');
const timelineNote = timelineStage.querySelector('.timeline-footnote');
function smoothBetween(t, start, end) {
  const p = Math.max(0, Math.min(1, (t - start) / (end - start)));
  return p * p * (3 - 2 * p);
}
function drawFocus(seconds) {
  const t = seconds % 8;
  const approach = smoothBetween(t, 0, 1.5);
  const moveToAction = smoothBetween(t, 3.5, 4.8);
  const reset = smoothBetween(t, 6.5, 8);
  const zoom = smoothBetween(t, 1.8, 2.7) * (1 - smoothBetween(t, 5.8, 6.8));
  const x = (78 - 21 * approach - 10 * moveToAction) * (1 - reset) + 78 * reset;
  const y = (61 - 15 * approach + 19 * moveToAction) * (1 - reset) + 61 * reset;
  focusStage.classList.add('motion-guided');
  focusStage.classList.toggle('is-zoomed', zoom > .5);
  focusDocument.style.transform = `scale(${1 + .28 * zoom}) translateY(${-3 * zoom}px)`;
  featurePointer.style.left = `${x}%`;
  featurePointer.style.top = `${y}%`;
  featurePointer.style.transform = 'none';
  const pulse = Math.max(0, 1 - Math.abs(t - 1.65) / .4, 1 - Math.abs(t - 5) / .4);
  clickRing.style.opacity = pulse;
  clickRing.style.transform = `scale(${2 - pulse})`;
  zoomToggle.setAttribute('aria-pressed', String(zoom > .5));
  zoomToggle.querySelector('span').textContent = zoom > .5 ? 'Smart zoom on' : 'Try smart zoom';
}
function drawTimeline(seconds) {
  const t = seconds % 18;
  const trim = smoothBetween(t, .8, 2);
  const move = smoothBetween(t, 2.5, 3.8);
  const reset = smoothBetween(t, 16.5, 18);
  const time = Math.max(0, Math.min(12, t - 4));
  const position = time / 12;
  timelineHead.style.left = `calc(17px + ${position * 100}% - ${position * 34}px)`;
  timelineTime.textContent = `00:${Math.floor(time).toString().padStart(2, '0')} / 00:12`;
  trimGap.style.width = `${24 * (1 - trim)}px`;
  trimGap.style.opacity = t > .3 && t < 2.2 ? '1' : '0';
  secondTake.style.transform = `translateX(${-22 * move * (1 - reset)}px)`;
  secondTake.classList.toggle('is-editing', t >= 2.3 && t < 4);
  timelineCursor.style.opacity = t < 4.3 ? String(smoothBetween(t, 0, .4) * (1 - smoothBetween(t, 3.8, 4.3))) : '0';
  timelineCursor.style.left = `${t < 2.2 ? 65 - 9 * smoothBetween(t, 0, .8) : 72 - 5 * move}%`;
  timelineCursor.style.top = t < 2.2 ? '48%' : '73%';
  timelineNote.textContent = t < 2.2 ? 'Trim a pause' : t < 4 ? 'Move your voiceover' : 'Preview your edit';
}
const featureMotions = [
  {name:'focus', stage:focusStage, draw:drawFocus, elapsed:0, intent:null, visible:false, frame:0, last:0},
  {name:'timeline', stage:timelineStage, draw:drawTimeline, elapsed:0, intent:null, visible:false, frame:0, last:0}
];
function tickFeature(motion, now) {
  if (motion.last) motion.elapsed += Math.min(100, now - motion.last) / 1000;
  motion.last = now;
  motion.draw(motion.elapsed);
  motion.frame = requestAnimationFrame(next => tickFeature(motion, next));
}
function syncFeatureMotion() {
  featureMotions.forEach(motion => {
    const wantsPlayback = motion.intent ?? !reducedMotion.matches;
    const playing = wantsPlayback && motion.visible && !document.hidden && !promoDialog.open && !downloadDialog.open;
    if (playing && !motion.frame) motion.frame = requestAnimationFrame(now => tickFeature(motion, now));
    if (!playing && motion.frame) {
      cancelAnimationFrame(motion.frame);
      motion.frame = 0;
      motion.last = 0;
    }
  });
}
function stopFocusGuide() {
  featureMotions[0].intent = false;
  syncFeatureMotion();
  focusStage.classList.remove('motion-guided');
  focusDocument.style.removeProperty('transform');
  featurePointer.style.removeProperty('transform');
  clickRing.style.opacity = '0';
}
const featureMotionObserver = new IntersectionObserver(entries => {
  entries.forEach(entry => {
    featureMotions.find(motion => motion.stage === entry.target).visible = entry.isIntersecting;
  });
  syncFeatureMotion();
}, {threshold:.2});
featureMotions.forEach(motion => featureMotionObserver.observe(motion.stage));
