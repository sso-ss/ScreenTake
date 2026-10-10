import {bundle} from '@remotion/bundler';
import {selectComposition,renderMedia,renderStill} from '@remotion/renderer';
import {mkdirSync} from 'node:fs';
import {resolve} from 'node:path';

const mode=process.argv[2]??'film';
const serveUrl=await bundle({entryPoint:resolve('src/index.ts'),webpackOverride:config=>({...config,cache:false})});
const composition=await selectComposition({serveUrl,id:'ScreenTakePromo'});
mkdirSync('out/stills',{recursive:true});
if(mode==='stills'){
  for(const seconds of [.5,2.6,5.8,9.3,12.5,17.2,20.0,23.2,27.0,30.5,34.0,36.8,38.2,41.0,44.3,46.8]){
    await renderStill({serveUrl,composition,frame:Math.round(seconds*30),output:resolve(`out/stills/${String(seconds).replace('.','-')}.png`),scale:.5,logLevel:'error'});
    console.log(`Still ${seconds}s`);
  }
}else{
  let last=-1;
  await renderMedia({serveUrl,composition,codec:'h264',outputLocation:resolve(mode==='preview'?'out/screentake-preview.mp4':'out/screentake-promo.mp4'),
    scale:mode==='preview'?.5:1,crf:mode==='preview'?23:18,pixelFormat:'yuv420p',audioCodec:'aac',audioBitrate:'320k',
    concurrency:3,logLevel:'error',onProgress:({progress})=>{const p=Math.floor(progress*100);if(p>=last+5){last=p;console.log(`Render ${p}%`);}}});
  console.log(`Finished ${mode}`);
}
