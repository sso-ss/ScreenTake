import {bundle} from '@remotion/bundler';
import {selectComposition,renderMedia,renderStill} from '@remotion/renderer';
import {mkdirSync} from 'node:fs';
import {resolve} from 'node:path';

const mode=process.argv[2]??'wide';
const compositionFilter=process.argv[3];
const serveUrl=await bundle({entryPoint:resolve('src/index.ts'),webpackOverride:config=>({...config,cache:false})});
mkdirSync('out/stills',{recursive:true});
if(mode==='stills'){
  const jobs=[['ScreenTakePromo',[.6,1.45,2.2,4.6,6.2,8.9,10.9,14.7,16.5,18.7,20.55,21.7,23.9,26.4,28.9,31.5,32.4,34.6,35.7,36.2,37.15,38.8,39.5,40.4,41.6,43.7,46.8,47.8]],['ScreenTakeVertical',[1.2,2.5,4.9,8.3,9.2,11.8,13.5,14.6,15.65,16.6,18.8,19.8]]];
  for(const [id,allSeconds] of jobs){
    const seconds=compositionFilter ? (id===compositionFilter ? (process.argv[4]??'').split(',').filter(Boolean).map(Number) : []) : allSeconds;
    if(!seconds.length)continue;
    const composition=await selectComposition({serveUrl,id});
    for(const sec of seconds){
      const file=resolve(`out/stills/${id==='ScreenTakePromo'?'wide':'tall'}-${sec.toFixed(2)}.png`);
      await renderStill({serveUrl,composition,frame:Math.round(sec*30),output:file,scale:.5,logLevel:'error',timeoutInMilliseconds:90000});
      console.log(`Still ${id} ${sec}s`);
    }
  }
}else{
  const id=mode==='tall'?'ScreenTakeVertical':'ScreenTakePromo';
  const composition=await selectComposition({serveUrl,id});
  let last=-1;
  const file=mode==='tall'?'out/screentake-storyboard-vertical.mp4':mode==='preview'?'out/screentake-storyboard-preview.mp4':'out/screentake-storyboard.mp4';
  await renderMedia({serveUrl,composition,codec:'h264',outputLocation:resolve(file),scale:mode==='preview'?.5:1,crf:mode==='preview'?23:18,pixelFormat:'yuv420p',colorSpace:'bt709',audioCodec:'aac',audioBitrate:'320k',concurrency:3,logLevel:'error',timeoutInMilliseconds:90000,onProgress:({progress})=>{const p=Math.floor(progress*100);if(p>=last+5){last=p;console.log(`Render ${id} ${p}%`);}}});
  console.log(`Finished ${file}`);
}
