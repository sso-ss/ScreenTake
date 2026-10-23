'use strict';
// A DOM port of the current native SettingsView, TextEditorPanel and design tokens.
// Guided playback and direct input call the same state/render functions.
const $ = selector => document.querySelector(selector);
const $$ = selector => [...document.querySelectorAll(selector)];
const root = $('#editor');
let scale = 1;
new ResizeObserver(() => {
  scale = window.innerWidth / 1280;
  root.style.transform = `scale(${scale})`;
}).observe(document.documentElement);
const icons = {
  canvas:'<rect x="3" y="4" width="18" height="16" rx="2"/><rect x="6" y="7" width="12" height="10" rx="1"/>',
  cursor:'<path d="M5 3v17l5-5 4 7 3-2-4-7h7Z"/>',
  camera:'<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-3v10l-5-3"/>',
  text:'<path d="m2 19 6-15 6 15M4 14h8m4-2c4-3 7-1 5 3-5-1-7 2-4 4 2 1 4-1 4-3v3"/>',
  audio:'<path d="M4 9v6m4-10v14m4-17v20m4-16v12m4-9v6"/>',
  output:'<path d="M5 10v11h14V10M12 16V2m-5 5 5-5 5 5"/>',
  reset:'<path d="M3 10a9 9 0 1 1 2 8M3 4v6h6"/>',
  undo:'<path d="m8 3-5 5 5 5M3 8h11a7 7 0 0 1 0 14"/>',
  redo:'<path d="m16 3 5 5-5 5m5-5H10a7 7 0 0 0 0 14"/>',
  folder:'<path d="M3 8V5a1 1 0 0 1 1-1h5l2 3h9a1 1 0 0 1 1 1v11H3L1 9h16l2 10"/>',
  record:'<circle cx="12" cy="12" r="7" fill="currentColor" stroke="none"/>',
  split:'<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M12 2v20m-4-10H5m11 0h3"/>',
  link:'<path d="m10 13 4-4m-5 7-1 1a4 4 0 0 1-6-6l4-4a4 4 0 0 1 6 0m0 10a4 4 0 0 0 6 0l4-4a4 4 0 0 0-6-6l-1 1"/>',
  snap:'<path d="M4 5v14m16-14v14M7 12h10m-3-3 3 3-3 3"/>',
  previous:'<path d="M5 5v14m14-14L8 12l11 7Z" fill="currentColor"/>',
  play:'<path d="m8 4 12 8-12 8Z" fill="currentColor" stroke="none"/>',
  pause:'<path d="M7 5h3v14H7zm7 0h3v14h-3z" fill="currentColor" stroke="none"/>',
  next:'<path d="M19 5v14M5 5l11 7-11 7Z" fill="currentColor"/>',
  ratio:'<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M7 11V9h3m7 4v2h-3"/>',
  chevrons:'<path d="m8 9 4-4 4 4m-8 6 4 4 4-4"/>',
  corners:'<path d="M3 10V7a4 4 0 0 1 4-4h3m4 0h3a4 4 0 0 1 4 4v3m0 4v3a4 4 0 0 1-4 4h-3m-4 0H7a4 4 0 0 1-4-4v-3"/>',
  crop:'<path d="M6 2v14a2 2 0 0 0 2 2h14M2 6h14a2 2 0 0 1 2 2v14"/>',
  browser:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M6 6.5h.1m3 0h.1"/>',
  image:'<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8" cy="8" r="1.5"/><path d="m3 17 5-5 4 4 4-6 5 7"/>',
  hand:'<path d="M8 13V4a2 2 0 0 1 4 0v7-4a2 2 0 0 1 4 0v5-3a2 2 0 0 1 4 0v6c0 4-2 7-6 7h-2c-2 0-4-1-5-3l-4-6a2 2 0 0 1 3-2l2 2Z"/>',
  circle:'<circle cx="12" cy="12" r="8"/>',
  target:'<circle cx="12" cy="12" r="7"/><path d="M12 2v5m0 10v5M2 12h5m10 0h5"/>',
  zoom:'<circle cx="10" cy="10" r="7"/><path d="m15 15 6 6M7 10h6m-3-3v6"/>',
  plusSquare:'<rect x="3" y="3" width="18" height="18" rx="3"/><path d="M7 12h10m-5-5v10"/>',
  plus:'<path d="M5 12h14M12 5v14"/>',
  minus:'<path d="M5 12h14"/>',
  close:'<path d="m6 6 12 12M6 18 18 6"/>',
  check:'<path d="m4 12 5 5L20 6"/>',
  download:'<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',
  settings:'<path d="m10 2-1 3-3 1-3-1-2 4 2 2v3l-2 2 2 4 3-1 3 1 1 3h4l1-3 3-1 3 1 2-4-2-2v-3l2-2-2-4-3 1-3-1-1-3Z" transform="translate(1 0) scale(.92)"/><circle cx="12" cy="12" r="3"/>'
};
function icon(name) { return `<svg class="ui-icon" data-icon="${name}" viewBox="0 0 24 24" aria-hidden="true">${icons[name]}</svg>`; }
$$('[data-icon]').forEach(svg=>svg.innerHTML=icons[svg.dataset.icon]);
$('#panel-buttons').innerHTML = ['canvas','cursor','camera','text','audio','output'].map(name => `<button data-panel-button="${name}" aria-label="${name[0].toUpperCase()+name.slice(1)}" aria-pressed="${name==='canvas'}">${icon(name)}${name[0].toUpperCase()+name.slice(1)}</button>`).join('');
const ratios = {original:'Original',landscape:'16:9 · Widescreen',desktop:'16:10 · Desktop',square:'1:1 · Square',portrait:'4:5 · Portrait',vertical:'9:16 · Stories / Reels'};
$('#ratio-menu').innerHTML = Object.entries(ratios).map(([value,label]) => `<button role="option" data-demo-ratio="${value}" aria-selected="false">${label}</button>`).join('');
const gradients = {
  sonoma:'linear-gradient(130deg,#1e1b4b,#6a3de8 30%,#f472b6 60%,#38bdf8)',
  aurora:'linear-gradient(130deg,#0c0a1a,#22d3ee 30%,#a78bfa 60%,#042f2e)',
  sunset:'linear-gradient(130deg,#1c1917,#ec4899 30%,#f97316 70%,#1e1b4b)',
  ocean:'linear-gradient(130deg,#020617,#0891b2 30%,#6366f1 60%,#064e3b)',
  blossom:'linear-gradient(130deg,#fdf2f8,#f9a8d4 40%,#c4b5fd 70%,#ede9fe)',
  nebula:'linear-gradient(130deg,#0a0a0f,#7c3aed 30%,#ec4899 60%,#0f0518)',
  moss:'linear-gradient(130deg,#052e16,#4ade80 40%,#22d3ee 70%,#022c22)',
  dusk:'linear-gradient(130deg,#1e1338,#f472b6 20%,#fda4af 60%,#4338ca)'
};
const wallpapers = [...Object.keys(gradients),'prism','lagoon','ember','midnight','silk','pastel','breeze','mint'];
const wallpaperStyle = name => gradients[name] || `url('${name}.png')`;
$('#wallpapers').innerHTML = wallpapers.map(name => `<button data-wallpaper="${name}" aria-label="${name[0].toUpperCase()+name.slice(1)} background" aria-pressed="false" style="--wallpaper:${wallpaperStyle(name)}"><span></span>${name[0].toUpperCase()+name.slice(1)}</button>`).join('');
$('.text-presets').innerHTML = ['Clean','Bold','Outline','Highlight','Label','Caption'].map(name=>`<button data-preset="${name.toLowerCase()}" aria-label="${name} text preset" aria-pressed="false"><b>Aa</b>${name}</button>`).join('');
const initial = {panel:'canvas',ratio:'landscape',layout:'desktop',wallpaper:'breeze',customBackground:null,background:true,corners:18,hideToolbar:false,crop:false,camera:true,cameraLayout:'overlay',cameraShape:'circle',cameraSize:'medium',mirror:false,follow:false,text:false,content:'Your next big idea.',preset:'bold',fontSize:48,font:'System',bold:true,italic:false,underline:false,textStart:0,textDuration:12,cursor:true,cursorShape:'arrow',cursorSize:100,zoom:false,zoomLevel:1.8,audio:true,volume:100,resolution:'Preserve source'};
let state = {...initial};
let history = [];
const screenVideo = $('#screen-video');
const cameraVideo = $('#camera-video');
const pointer = $('#demo-cursor');
let running = false;
let raf = 0;
let startTime = 0;
let stepIndex = 0;
let clipPlaying = false;
let latestClick = -10;
let lastTyped = '';
let userImageURL = null;
function notify(type) { parent.postMessage({type},window.location.origin); }
function render() {
  $$('.panel-rail button').forEach(b=>{const selected=b.dataset.panelButton===state.panel;b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',String(selected));});
  $$('[data-panel]').forEach(panel=>panel.hidden=panel.dataset.panel!==state.panel);
  const canvas = $('#video-canvas');
  canvas.dataset.ratio = state.ratio;
  canvas.dataset.layout = state.layout;
  canvas.style.backgroundImage = state.background ? state.customBackground || wallpaperStyle(state.wallpaper) : 'none';
  canvas.style.backgroundColor = state.background ? '#e9e9ed' : '#000';
  $('#ratio-label').textContent = ratios[state.ratio];
  $$('[data-demo-ratio]').forEach(b=>b.setAttribute('aria-selected',String(b.dataset.demoRatio===state.ratio)));
  $$('[data-device]').forEach(b=>{const selected=b.dataset.device===state.layout;b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',String(selected));});
  $$('[data-wallpaper]').forEach(b=>b.setAttribute('aria-pressed',String(!state.customBackground&&b.dataset.wallpaper===state.wallpaper)));
  const screen = $('#screen-content');
  screen.style.borderRadius = state.layout==='iPhone' ? '28px' : `${state.corners}px`;
  screen.style.transform = state.zoom ? `scale(${state.zoomLevel})` : 'none';
  screenVideo.style.transform = state.hideToolbar || state.crop ? 'scale(1.11) translateY(-3%)' : 'none';
  const camera = $('#camera-content');
  camera.hidden = !state.camera;
  camera.classList.toggle('full-screen',state.cameraLayout==='fullScreen');
  camera.style.borderRadius = state.cameraShape==='circle' ? '50%' : '12px';
  camera.style.width = {small:'15%',medium:'20%',large:'28%'}[state.cameraSize];
  cameraVideo.style.transform = `scale(${state.follow?1.15:1}) scaleX(${state.mirror?-1:1})`;
  for(const [attr,key] of [['camera','cameraLayout'],['shape','cameraShape'],['size','cameraSize'],['cursor','cursorShape']]) {
    $$(`[data-${attr}]`).forEach(b=>{const selected=b.dataset[attr]===state[key];b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',String(selected));});
  }
  $('#text-empty').hidden=state.text;
  $('#text-controls').hidden=!state.text;
  $('#add-another-text').hidden=!state.text;
  const overlay = $('#text-overlay');
  overlay.textContent=state.content;
  overlay.dataset.preset=state.preset;
  overlay.style.fontSize=`${state.fontSize*.58}px`;
  overlay.style.fontFamily={System:'inherit',Georgia:'Georgia,serif',Menlo:'Menlo,monospace'}[state.font];
  overlay.style.fontWeight=state.bold?700:400;
  overlay.style.fontStyle=state.italic?'italic':'normal';
  overlay.style.textDecoration=state.underline?'underline':'none';
  $('#layer-name').textContent=state.content||'Empty text';
  if($('#text-content').value!==state.content) $('#text-content').value=state.content;
  $$('.text-track').forEach(t=>{t.hidden=!state.text;t.style.marginLeft=`${state.textStart/12*100}%`;t.style.width=`${Math.min(state.textDuration,12-state.textStart)/12*100}%`;t.querySelector('span').textContent=`T  ${state.content}`;});
  $('.zoom-track').hidden=!state.zoom;
  $('.camera-track').hidden=!state.camera;
  $('.audio-track').style.opacity=state.audio?1:.35;
  $$('.text-presets button').forEach(b=>{const selected=b.dataset.preset===state.preset;b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',String(selected));});
  const checkboxes = {'background-enabled':'background','hide-toolbar':'hideToolbar','show-camera':'camera','mirror-camera':'mirror','follow-face':'follow','show-cursor':'cursor','zoom-enabled':'zoom','audio-enabled':'audio'};
  Object.entries(checkboxes).forEach(([id,key])=>$('#'+id).checked=state[key]);
  const fields={'corner-radius':'corners','font-size':'fontSize','cursor-size':'cursorSize','zoom-level':'zoomLevel','audio-volume':'volume','font-family':'font','export-resolution':'resolution'};
  Object.entries(fields).forEach(([id,key])=>$('#'+id).value=state[key]);
  $('#corner-value').textContent=`${state.corners} px`;
  $('#font-value').textContent=state.fontSize;
  $('#cursor-value').textContent=`${state.cursorSize}%`;
  $('#zoom-value').textContent=`${state.zoomLevel.toFixed(1)}×`;
  $('#volume-value').textContent=`${state.volume}%`;
  for(const name of ['bold','italic','underline']) $('#text-'+name).setAttribute('aria-pressed',String(state[name]));
  const recordedPointer = $('.recorded-pointer');
  recordedPointer.hidden=!state.cursor;
  if(recordedPointer.dataset.shape!==state.cursorShape) {
    recordedPointer.innerHTML=icon(state.cursorShape==='arrow'?'cursor':state.cursorShape);
    recordedPointer.dataset.shape=state.cursorShape;
  }
  recordedPointer.style.width=recordedPointer.style.height=`${20*state.cursorSize/100}px`;
  $('#apply-edits').disabled=!history.length;
  $('#undo-edit').disabled=!history.length;
  $('#export-size').textContent=state.resolution==='4K'?'3840 × 2160 · 30 FPS':state.resolution==='1080p'?'1920 × 1080 · 30 FPS':'1080 × 888 · 30 FPS';
  updateTime();
}
function commit(change) {history.push({...state});if(history.length>30)history.shift();Object.assign(state,change);render();}
function setPanel(panel) {state.panel=panel;$('#inspector-scroll').scrollTop=0;closeRatio();render();}
function openRatio() {$('#ratio-menu').hidden=false;$('#ratio-picker').setAttribute('aria-expanded','true');}
function closeRatio() {$('#ratio-menu').hidden=true;$('#ratio-picker').setAttribute('aria-expanded','false');}
function setRatio(ratio) {commit({ratio});closeRatio();}
function setText(content) {state.content=content;render();}
function setPreset(preset) {commit({preset,bold:!['clean','caption'].includes(preset)});}
function reset() {state={...initial};history=[];closeRatio();$('#inspector-scroll').scrollTop=0;$('#pause-result').hidden=true;render();}
function updateTime() {
  const t=screenVideo.currentTime;
  $('#timecode').textContent=`00:${Math.floor(t).toString().padStart(2,'0')}.${Math.floor(t*10)%10}`;
  $('#playhead').style.left=`${Math.min(100,t/12*100)}%`;
  $('#text-overlay').hidden=!state.text||t<state.textStart||t>=state.textStart+state.textDuration;
}
function setClipPlaying(playing) {
  clipPlaying=playing;
  $('#play-video').innerHTML=icon(playing?'pause':'play');
  $('#play-video').setAttribute('aria-label',playing?'Pause video':'Play video');
  [screenVideo,cameraVideo].forEach(v=>{if(playing)v.play().catch(()=>{});else v.pause();});
}
function pauseForInput() {if(!running)return;setRunning(false);notify('screentake-demo-interaction');}
document.addEventListener('pointerdown',pauseForInput,true);
document.addEventListener('keydown',event=>{if(event.key==='Tab'||event.key==='Enter'||event.key===' ')pauseForInput();});
$$('[data-panel-button]').forEach(b=>b.addEventListener('click',()=>setPanel(b.dataset.panelButton)));
$('#ratio-picker').addEventListener('click',()=>$('#ratio-menu').hidden?openRatio():closeRatio());
$$('[data-demo-ratio]').forEach(b=>b.addEventListener('click',()=>setRatio(b.dataset.demoRatio)));
$('#ratio-menu').addEventListener('keydown',event=>{const options=$$('[data-demo-ratio]');let index=options.indexOf(document.activeElement);if(event.key==='ArrowDown'||event.key==='ArrowUp'){event.preventDefault();options[(index+(event.key==='ArrowDown'?1:options.length-1))%options.length].focus();}if(event.key==='Escape'){closeRatio();$('#ratio-picker').focus();}});
$('#ratio-picker').addEventListener('keydown',event=>{if(event.key==='ArrowDown'){event.preventDefault();openRatio();$('[data-demo-ratio][aria-selected="true"]').focus();}});
document.addEventListener('click',event=>{if(!event.target.closest('.ratio-picker'))closeRatio();});
const choiceBindings=[['device','layout'],['wallpaper','wallpaper'],['camera','cameraLayout'],['shape','cameraShape'],['size','cameraSize'],['cursor','cursorShape']];
choiceBindings.forEach(([attr,key])=>$$(`[data-${attr}]`).forEach(b=>b.addEventListener('click',()=>commit({[key]:b.dataset[attr],...(attr==='wallpaper'?{customBackground:null,background:true}:{})}))));
const checkBindings={'background-enabled':'background','hide-toolbar':'hideToolbar','show-camera':'camera','mirror-camera':'mirror','follow-face':'follow','show-cursor':'cursor','zoom-enabled':'zoom','audio-enabled':'audio'};
Object.entries(checkBindings).forEach(([id,key])=>$('#'+id).addEventListener('change',event=>commit({[key]:event.target.checked})));
const rangeBindings={'corner-radius':'corners','font-size':'fontSize','cursor-size':'cursorSize','zoom-level':'zoomLevel','audio-volume':'volume'};
Object.entries(rangeBindings).forEach(([id,key])=>$('#'+id).addEventListener('input',event=>commit({[key]:Number(event.target.value)})));
$('#crop-screen').addEventListener('click',()=>commit({crop:!state.crop}));
$('#set-zoom-area').addEventListener('click',()=>commit({zoom:true,zoomLevel:1.8}));
$('#add-text').addEventListener('click',()=>commit({text:true}));
$('#add-another-text').addEventListener('click',()=>{commit({text:true,content:'Another great idea.'});$('#text-content').focus();});
$('#remove-text').addEventListener('click',()=>commit({text:false}));
$('#text-content').addEventListener('input',event=>commit({content:event.target.value}));
$$('[data-preset]').forEach(b=>b.addEventListener('click',()=>setPreset(b.dataset.preset)));
$('#font-family').addEventListener('change',event=>commit({font:event.target.value}));
for(const name of ['bold','italic','underline']) $('#text-'+name).addEventListener('click',()=>commit({[name]:!state[name]}));
$$('.timing-row input').forEach((field,index)=>field.addEventListener('change',()=>{const v=Number(field.value);commit(index===0?{textStart:Math.max(0,Math.min(11,v))}:{textDuration:Math.max(1,Math.min(12,v))});}));
$('#undo-edit').addEventListener('click',()=>{if(history.length){state=history.pop();render();}});
$('#reset-edit').addEventListener('click',reset);
$('#apply-edits').addEventListener('click',()=>{history=[];render();$('#preview-notice').hidden=false;$('#preview-notice').textContent='Changes applied';setTimeout(()=>$('#preview-notice').hidden=true,1800);});
$('#find-pauses').addEventListener('click',()=>$('#pause-result').hidden=false);
$('#export-resolution').addEventListener('change',event=>commit({resolution:event.target.value}));
$('#custom-background').addEventListener('change',event=>{const file=event.target.files[0];if(!file||!file.type.startsWith('image/'))return;if(userImageURL)URL.revokeObjectURL(userImageURL);userImageURL=URL.createObjectURL(file);commit({customBackground:`url('${userImageURL}')`,background:true});});
$('#play-video').addEventListener('click',()=>setClipPlaying(!clipPlaying));
function stepFrame(delta) {setClipPlaying(false);screenVideo.currentTime=Math.max(0,Math.min(11.99,screenVideo.currentTime+delta));cameraVideo.currentTime=screenVideo.currentTime;updateTime();}
$('#previous-frame').addEventListener('click',()=>stepFrame(-1/30));
$('#next-frame').addEventListener('click',()=>stepFrame(1/30));
screenVideo.addEventListener('timeupdate',updateTime);
$('[aria-label="Timeline zoom"]').addEventListener('input',event=>{
  $('#tracks').style.width=`${Number(event.target.value)*100}%`;
});
const steps = [
  {at:0, target:'#screen-content', action:()=>{}},
  {at:1.6,target:'#ratio-picker',action:openRatio},
  {at:2.7,target:'[data-demo-ratio="square"]',action:()=>setRatio('square')},
  {at:4.4,target:'[data-wallpaper="silk"]',action:()=>commit({wallpaper:'silk'})},
  {at:6.2,target:'[data-panel-button="text"]',action:()=>setPanel('text')},
  {at:7.5,target:'#add-text',action:()=>commit({text:true,content:''})},
  {at:8.2,target:'#text-content',action:()=>{}},
  {at:10.6,target:'[data-preset="label"]',action:()=>setPreset('label')},
  {at:12.6,target:'[data-panel-button="camera"]',action:()=>setPanel('camera')},
  {at:14,target:'[data-camera="fullScreen"]',action:()=>commit({cameraLayout:'fullScreen'})},
  {at:16.2,target:'[data-camera="overlay"]',action:()=>commit({cameraLayout:'overlay'})},
  {at:18,target:'[data-panel-button="cursor"]',action:()=>setPanel('cursor')},
  {at:19.4,target:'#zoom-enabled',action:()=>commit({zoom:true})},
  {at:21.8,target:'#zoom-enabled',action:()=>commit({zoom:false})},
  {at:23,target:'[data-panel-button="canvas"]',action:()=>setPanel('canvas')},
  {at:24.2,target:'#ratio-picker',action:openRatio},
  {at:25.2,target:'[data-demo-ratio="landscape"]',action:()=>setRatio('landscape')},
  {at:26.5,target:'[data-wallpaper="breeze"]',action:()=>commit({wallpaper:'breeze'})}
];
let cursorFrom={x:600,y:420};
function revealTarget(selector) {
  const target=$(selector);
  const scroll=$('#inspector-scroll');
  if(!target||!scroll.contains(target)||!target.getClientRects().length)return;
  const rect=target.getBoundingClientRect();
  const viewport=scroll.getBoundingClientRect();
  if(rect.bottom>viewport.bottom-12*scale)scroll.scrollTop+=(rect.bottom-viewport.bottom)/scale+20;
  if(rect.top<viewport.top+12*scale)scroll.scrollTop-=(viewport.top-rect.top)/scale+20;
}
function targetPoint(selector) {
  const target=$(selector);
  if(!target||!target.getClientRects().length)return cursorFrom;
  const rect=target.getBoundingClientRect();
  return {x:(rect.left+rect.width*.5)/scale,y:(rect.top+rect.height*.5)/scale};
}
function tick(now) {
  if(!running)return;
  const elapsed=(now-startTime)/1000;
  if(elapsed>29){startTime=now;stepIndex=0;lastTyped='';reset();cursorFrom={x:600,y:420};raf=requestAnimationFrame(tick);return;}
  while(stepIndex<steps.length&&elapsed>=steps[stepIndex].at){
    const step=steps[stepIndex];cursorFrom=targetPoint(step.target);step.action();
    pointer.classList.remove('is-clicking');void pointer.offsetWidth;pointer.classList.add('is-clicking');latestClick=elapsed;stepIndex++;
  }
  if(elapsed>=8.2&&elapsed<10.1){const content='Your next big idea.'.slice(0,Math.floor((elapsed-8.2)/1.45*19));if(content!==lastTyped){setText(content);lastTyped=content;}}
  if(elapsed>=10.1&&elapsed<10.6&&state.content!=='Your next big idea.')setText('Your next big idea.');
  const next=steps[stepIndex];
  let position=cursorFrom;
  if(next&&elapsed>next.at-1.1)revealTarget(next.target);
  if(next){const travelStart=Math.max(steps[Math.max(0,stepIndex-1)].at+.35,next.at-.85);const progress=Math.max(0,Math.min(1,(elapsed-travelStart)/(next.at-travelStart)));const ease=progress*progress*(3-2*progress);const to=targetPoint(next.target);position={x:cursorFrom.x+(to.x-cursorFrom.x)*ease,y:cursorFrom.y+(to.y-cursorFrom.y)*ease};}
  pointer.style.transform=`translate(${Math.min(1265,position.x)}px,${Math.min(760,position.y)}px)`;
  pointer.classList.toggle('on-right',position.x>1120);
  if(elapsed-latestClick>.6)pointer.classList.remove('is-clicking');
  updateTime();
  raf=requestAnimationFrame(tick);
}
function setRunning(playing) {
  if(running===playing){if(!playing)setClipPlaying(false);return;}
  running=playing;root.dataset.guidedPlaying=String(playing);pointer.classList.toggle('is-paused',!playing);
  if(playing){reset();stepIndex=0;lastTyped='';cursorFrom={x:600,y:420};startTime=performance.now();setClipPlaying(true);raf=requestAnimationFrame(tick);}else{cancelAnimationFrame(raf);setClipPlaying(false);closeRatio();}
}
window.addEventListener('message',event=>{if(event.origin!==window.location.origin||event.source!==parent)return;if(event.data?.type==='screentake-demo-playback')setRunning(Boolean(event.data.playing));});
window.addEventListener('pagehide',()=>{cancelAnimationFrame(raf);[screenVideo,cameraVideo].forEach(v=>v.pause());if(userImageURL)URL.revokeObjectURL(userImageURL);});
document.addEventListener('visibilitychange',()=>{if(document.hidden)setRunning(false);});
root.dataset.guidedPlaying='false';
pointer.classList.add('is-paused');
render();
notify('screentake-demo-ready');
