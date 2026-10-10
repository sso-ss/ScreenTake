import React from 'react';
import {AbsoluteFill, Audio, Composition, Sequence, staticFile, useCurrentFrame} from 'remotion';
import {Scene} from './scenes';
import {Background, Brand} from './visuals';
import {FONT, scenes, type SceneID} from './theme';
import {loadFonts} from './fonts';
loadFonts();

const Shot:React.FC<{id:SceneID;start:number}>=({id,start})=>{
  const t=useCurrentFrame()/30;
  return <AbsoluteFill><Background t={start+t} warm={id==='Frame'?1:0}/><Scene id={id} t={t}/>{id!=='End'&&<Brand/>}</AbsoluteFill>;
};

const Film:React.FC=()=> <AbsoluteFill style={{background:'#09090e'}}>
  {scenes.map(s=><Sequence key={s.id} from={s.start*30} durationInFrames={s.duration*30} name={s.title}><Shot id={s.id} start={s.start}/></Sequence>)}
  <div style={{position:'absolute',bottom:20,left:32,fontFamily:FONT,fontSize:18,color:'rgba(222,211,240,.6)',letterSpacing:.2}}>Product visualization · native interface assets + illustrated workflow</div>
  <Audio src={staticFile('audio/score.wav')} volume={.86}/>
</AbsoluteFill>;

export const Root:React.FC=()=> <>
  <Composition id="ScreenTakePromo" component={Film} durationInFrames={1440} fps={30} width={1920} height={1080}/>
  {scenes.map(s=><Composition key={s.id} id={`Scene-${s.id}`} component={Shot} defaultProps={{id:s.id,start:s.start}} durationInFrames={s.duration*30} fps={30} width={1920} height={1080}/>)}
</>;
