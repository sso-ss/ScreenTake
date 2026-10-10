import React from 'react';
import {AbsoluteFill, Img, staticFile} from 'remotion';
import {C, FONT, MONO, type SceneID} from './theme';
import {arrive, clamp, during, mix, pulse} from './motion';
import {Caption, Demo, DetailCrop, NativeEditor, Plate, Pointer, WallpaperFrame, Wave} from './visuals';

const Chip:React.FC<{children:React.ReactNode;style?:React.CSSProperties}>=({children,style})=> <div style={{fontFamily:MONO,fontSize:18,letterSpacing:1.5,color:C.muted,...style}}>{children}</div>;

const Promise:React.FC<{t:number}>=({t})=> {
  const change=during(t,1.35,.55);
  const reveal=arrive(t,1.35,.7);
  return <AbsoluteFill>
    <Plate t={t} w={1340} h={790} motionBlur pose={s=>({x:mix(255,390,arrive(s,1.35,.7)),y:mix(130,80,arrive(s,1.35,.7)),scale:mix(1.9,.91,arrive(s,1.35,.7)),ry:mix(-3,-8,arrive(s,1.35,.7)),rx:mix(0,5,arrive(s,1.35,.7)),blur:mix(3,0,arrive(s,1.35,.7))})}>
      <WallpaperFrame t={t+.3} wallpaper="midnight"/>
      <AbsoluteFill style={{opacity:1-change,background:'#c9c4ce',display:'flex',alignItems:'center',justifyContent:'center'}}><Demo t={t} raw pointer/></AbsoluteFill>
    </Plate>
    <AbsoluteFill style={{background:'linear-gradient(90deg,rgba(9,9,14,.98) 0%,rgba(9,9,14,.93) 28%,rgba(9,9,14,.35) 46%,transparent 65%)'}}/>
    <Caption t={t} text={<>Your screen.</>} x={96} y={295} width={760} size={110}/>
    <div style={{position:'absolute',left:96,top:423,fontFamily:FONT,fontSize:110,fontWeight:650,lineHeight:1.02,letterSpacing:-4,color:C.light,opacity:reveal,transform:`translateY(${mix(25,0,reveal)}px)`}}>A better take.</div>
    <Chip style={{position:'absolute',left:100,top:580,opacity:reveal}}>RECORD. SHAPE. SHOW.</Chip>
  </AbsoluteFill>;
};

const Record:React.FC<{t:number}>=({t})=> {
  const click=2.1;
  return <AbsoluteFill>
    <Caption t={t} text="Start with a good take." tag="01 / Capture"/>
    <Plate t={t} w={1100} h={650} motionBlur pose={s=>({x:20,y:85,scale:mix(.8,1.12,arrive(s,.1,.9)),rx:mix(9,0,arrive(s,.1,.9)),ry:mix(-6,0,arrive(s,.1,.9)),blur:mix(5,0,arrive(s,.1,.6))})}>
      <Demo t={0} pointer={false}/>
    </Plate>
    <div style={{position:'absolute',left:714,top:864,transform:`translateY(${mix(32,0,arrive(t,.45,.5))}px)`,opacity:arrive(t,.45,.5),display:'flex',alignItems:'center',gap:20,
      borderRadius:20,background:'rgba(38,36,44,.96)',border:'1px solid #54505e',boxShadow:'0 20px 60px rgba(0,0,0,.5)',padding:'16px 20px',fontFamily:FONT}}>
      <span style={{fontSize:20,color:'#ccc5db',paddingRight:22,borderRight:'1px solid #5c5469'}}>Entire screen</span>
      <span style={{fontSize:20,color:'#ccc5db'}}>Window</span>
      <div style={{padding:'12px 26px',borderRadius:11,background:t<click?C.accent:'#453344',color:'white',fontSize:22,fontWeight:600,display:'flex',alignItems:'center',gap:9}}>
        <span style={{width:9,height:9,borderRadius:'50%',background:t<click?'white':'#ff657e'}}/>{t<click?'Record':'Recording'}
      </div>
    </div>
    <Pointer x={mix(1335,1116,during(t,.95,.65))} y={mix(906,902,during(t,.95,.65))} click={pulse(t,click)} scale={1.1}/>
    <Chip style={{position:'absolute',left:97,top:943}}>DISPLAY OR WINDOW · ON YOUR MAC</Chip>
  </AbsoluteFill>;
};

const Zoom:React.FC<{t:number}>=({t})=> <AbsoluteFill>
  <Caption t={t} text={<>Give every click its <span style={{color:C.light}}>close-up.</span></>} tag="02 / Smart zoom"/>
  <Plate t={t} w={1340} h={790} pose={s=>({y:100,scale:mix(.9,.95,arrive(s,.05,.7)),blur:mix(2,0,arrive(s,0,.4))})}>
    <WallpaperFrame t={t} wallpaper="lagoon" zoom/>
  </Plate>
  <Chip style={{position:'absolute',left:1510,top:72,fontSize:17,color:'#b9b1c8'}}>SMART ZOOM · EXPERIMENTAL</Chip>
</AbsoluteFill>;

const Cursor:React.FC<{t:number}>=({t})=> {
  const bigger=mix(1,1.9,during(t,1.1,.6));
  return <AbsoluteFill>
    <Caption t={t} text={<>Make every click <span style={{color:C.light}}>clear.</span></>} tag="03 / Cursor + clicks"/>
    <Plate t={t} w={1340} h={790} pose={s=>({x:-120,y:118,scale:.82,ry:-6,blur:mix(2,0,arrive(s,0,.5))})}><WallpaperFrame t={t+1.1} cursorScale={bigger} wallpaper="prism"/></Plate>
    <Plate t={t} w={490} h={260} motionBlur pose={s=>({x:mix(580,480,arrive(s,.35,.6)),y:150,z:90,ry:4,opacity:arrive(s,.35,.5),blur:mix(4,0,arrive(s,.35,.6))})}>
      <div style={{width:490,height:260,borderRadius:20,background:'#27252e',border:'1px solid #534b62',boxShadow:'0 36px 85px rgba(0,0,0,.55)',fontFamily:FONT,padding:'29px 33px',boxSizing:'border-box',color:'white'}}>
        <div style={{fontSize:26,fontWeight:600,marginBottom:19}}>Cursor</div>
        <div style={{display:'flex',gap:14,alignItems:'center',height:65,marginBottom:18}}>
          <div style={{height:64,width:70,background:'#54447a',borderRadius:9,position:'relative'}}><Pointer x={17} y={6} scale={.7}/></div>
          <span style={{fontSize:24,color:'#b6a9c7',padding:'16px 12px'}}>Hand</span>
          <div style={{width:32,height:32,borderRadius:'50%',border:'2px solid #cec4de',marginLeft:15}}/>
        </div>
        <div style={{display:'flex',justifyContent:'space-between',fontSize:20,color:'#d3cadd',marginBottom:16}}><span>Size</span><span>{Math.round(bigger*100)}%</span></div>
        <div style={{height:5,background:'#4c4556',borderRadius:5,position:'relative'}}><div style={{width:`${24+25*during(t,1.1,.6)}%`,height:5,background:'#9c85ef',borderRadius:5}}/><div style={{position:'absolute',left:`${24+25*during(t,1.1,.6)}%`,top:-7,width:20,height:20,borderRadius:'50%',background:'#ddd7e8'}}/></div>
      </div>
    </Plate>
    <Chip style={{position:'absolute',left:100,top:969}}>STYLE · SIZE · CLICK HIGHLIGHTS</Chip>
  </AbsoluteFill>;
};

const TimelineEdit:React.FC<{t:number}>=({t})=> {
  const split=during(t,1.3,.12),remove=during(t,2.8,.6);
  const width=1370,first=480,gap=mix(205,0,remove),last=685;
  return <div style={{width:1480,height:294,background:'#2b2932',border:'1px solid #595165',borderRadius:18,padding:'24px 40px',boxSizing:'border-box',position:'relative',fontFamily:FONT,boxShadow:'0 36px 96px rgba(0,0,0,.65)'}}>
    <div style={{display:'flex',gap:22,color:'#bab1c9',fontSize:20,marginBottom:22}}><span style={{color:'#ede8f7'}}>Split</span><span>Undo</span><span>Redo</span><span style={{marginLeft:'auto',fontFamily:MONO}}>00:04.2 / 00:12.0</span></div>
    <div style={{position:'relative',height:29,display:'flex',justifyContent:'space-between',color:'#9d92ae',fontFamily:MONO,fontSize:16}}>{['00:00','00:03','00:06','00:09','00:12'].map(s=><span key={s}>{s}</span>)}</div>
    <div style={{position:'relative',height:80,width}}>
      {[{x:0,w:first},{x:first+gap,w:last}].map((s,i)=><div key={i} style={{position:'absolute',left:s.x,top:0,width:s.w,height:80,overflow:'hidden',borderRadius:7,border:'2px solid #9b85e8',background:'#d1c3ed'}}>
        {Array.from({length:10},(_,j)=><Img key={j} src={staticFile('assets/demo-thumb.jpg')} style={{position:'absolute',left:j*85,top:0,width:128,height:80,objectFit:'cover',borderRight:'1px solid #a592c6'}}/>)}
      </div>)}
      <div style={{position:'absolute',left:first,top:0,width:Math.max(0,gap),height:80,overflow:'hidden',border:'1px solid rgba(194,176,238,.6)',background:'#6c5267',opacity:1-remove,transform:`translateY(${-28*remove}px)`}}>
        <div style={{textAlign:'center',paddingTop:27,color:'#fff',fontSize:20}}>Pause</div>
      </div>
      <div style={{position:'absolute',left:first,top:-9,height:100,width:2,background:'#f1eaf8',opacity:split*(1-remove)}}/>
      <div style={{position:'absolute',left:first+205,top:-9,height:100,width:2,background:'#f1eaf8',opacity:split*(1-remove)}}/>
    </div>
    <div style={{marginTop:21,opacity:.8}}><Wave width={first+gap+last} height={31} color={C.teal}/></div>
    <Pointer x={mix(165,first+80,during(t,.3,.6))} y={mix(38,115,during(t,1.6,.5))} scale={.82} click={pulse(t,1.3)}/>
    <div style={{position:'absolute',left:first+40,top:114,width:22,height:120,opacity:split*(1-remove),borderLeft:'2px solid #e6d8fa'}}/>
  </div>;
};

const Edit:React.FC<{t:number}>=({t})=> {
  const detail=during(t,1.15,.8);
  return <AbsoluteFill>
    <Caption t={t} text={<>Keep the <span style={{color:C.light}}>good parts.</span></>} tag="04 / Timeline editing"/>
    <Plate t={t} w={1400} h={850} motionBlur pose={s=>({y:102-35*during(s,1.15,.8),x:0,scale:mix(.87,.72,during(s,1.15,.8)),rx:mix(17,3,arrive(s,0,1)),rz:mix(-5,0,arrive(s,0,1)),blur:mix(0,4,during(s,1.15,.8)),opacity:mix(1,.65,during(s,1.15,.8))})}><NativeEditor t={t}/></Plate>
    <Plate t={t} w={1480} h={294} motionBlur pose={s=>({y:mix(380,230,arrive(s,1.15,.8)),z:30,rx:mix(8,0,arrive(s,1.15,.8)),opacity:arrive(s,1.15,.6),blur:mix(8,0,arrive(s,1.15,.8))})}><TimelineEdit t={t-1.15}/></Plate>
    <Chip style={{position:'absolute',left:100,top:969,opacity:detail}}>SPLIT. REMOVE. KEEP THE STORY MOVING.</Chip>
  </AbsoluteFill>;
};

const NarrationTimeline:React.FC<{t:number}>=({t})=> {
  const grow=clamp((t-1.4)/2.0),move=during(t,4.6,.8);
  return <div style={{width:1320,height:263,position:'relative',borderRadius:16,background:'#2b2932',border:'1px solid #514958',boxShadow:'0 40px 90px rgba(0,0,0,.55)',padding:26,boxSizing:'border-box',fontFamily:FONT}}>
    <div style={{color:'#d3cadc',fontSize:18,marginBottom:16}}>Original audio</div>
    <div style={{width:1265,height:40,background:'rgba(84,186,200,.08)',borderRadius:6,padding:'2px 10px',boxSizing:'border-box'}}><Wave width={1245} height={36} color={C.teal}/></div>
    <div style={{color:'#d3cadc',fontSize:18,margin:'20px 0 12px'}}>Voiceover</div>
    <div style={{height:70,position:'relative'}}>
      <div style={{position:'absolute',left:mix(385,224,move),height:62,width:Math.max(0,730*grow),overflow:'hidden',border:'1px solid #b68cdb',borderRadius:7,background:'#42314f',boxSizing:'border-box'}}>
        <div style={{fontSize:16,color:'#e0c0fc',padding:'6px 13px 0'}}>Take 1</div><div style={{padding:'1px 10px'}}><Wave width={700} height={27} seed={2} color="#bd90ec"/></div>
      </div>
      {grow>0&&grow<1&&<div style={{position:'absolute',left:385+730*grow,top:-122,height:194,width:2,background:'#e9e0f1'}}/>}
      {move>.01&&<Pointer x={mix(704,543,move)} y={19} scale={.78} click={pulse(t,4.6)}/>}
    </div>
  </div>;
};

const Voiceover:React.FC<{t:number}>=({t})=> <AbsoluteFill>
  <Caption t={t} text={<>Add your voice <span style={{color:C.light}}>after.</span></>} tag="05 / Voiceover"/>
  <Plate t={t} w={1400} h={850} pose={s=>({x:-160,y:55,scale:.77,ry:-7,blur:mix(1.5,3,during(s,1,.6)),opacity:.75})}><NativeEditor t={t}/></Plate>
  <Plate t={t} w={456} h={414} motionBlur pose={s=>({x:610,y:40,z:25,scale:1,opacity:arrive(s,.25,.6),blur:mix(5,0,arrive(s,.25,.6))})}>
    <DetailCrop x={1034} y={132} w={285} h={259} scale={1.6}/>
    <Pointer x={234} y={175} scale={.8} click={pulse(t,1.4)}/>
  </Plate>
  <Plate t={t} w={1320} h={263} motionBlur pose={s=>({x:-25,y:mix(440,294,arrive(s,.75,.7)),z:60,opacity:arrive(s,.75,.6),blur:mix(6,0,arrive(s,.75,.7))})}><NarrationTimeline t={t}/></Plate>
</AbsoluteFill>;

const Frame:React.FC<{t:number}>=({t})=> {
  const state=t<2?0:t<4?1:2;
  const ratio=state===0?'16:9':state===1?'1:1':'9:16';
  const w=state===0?1100:state===1?735:438,h=state===0?619:state===1?735:780;
  const local=t-state*2;
  return <AbsoluteFill>
    <Caption t={t} text={<>Frame it<br/><span style={{color:C.light}}>your way.</span></>} tag="06 / Canvas" x={96} y={285} size={101} width={570}/>
    <Plate t={local} w={w} h={h} motionBlur pose={s=>({x:360,y:77,ry:mix(-7,0,arrive(s,0,.45)),scale:mix(.92,1,arrive(s,0,.45)),blur:mix(3,0,arrive(s,0,.35)),opacity:arrive(s,0,.22)})}>
      <WallpaperFrame t={4} wallpaper={state===0?'prism':state===1?'ember':'lagoon'} w={w} h={h} ratio={ratio}/>
    </Plate>
    <div style={{position:'absolute',left:101,top:643,display:'flex',gap:24,fontFamily:MONO,fontSize:25}}>{['16:9','1:1','9:16'].map((s,i)=><div key={s} style={{color:state===i?C.text:C.muted,borderBottom:`2px solid ${state===i?C.light:'transparent'}`,paddingBottom:11}}>{s}</div>)}</div>
    <Chip style={{position:'absolute',left:101,top:767}}>BACKGROUNDS. FORMATS. YOUR STYLE.</Chip>
  </AbsoluteFill>;
};

const Result:React.FC<{t:number}>=({t})=> {
  const done=during(t,.7,.3);
  return <AbsoluteFill>
    <Caption t={t} text="Ready to show." tag="07 / The finished take"/>
    <Plate t={t} w={1400} h={850} motionBlur pose={s=>({y:88,scale:.91,opacity:1-during(s,.65,.5),blur:4*during(s,.65,.5)})}><NativeEditor t={4}/></Plate>
    <Plate t={t} w={1340} h={790} motionBlur pose={s=>({y:96,scale:mix(.89,.95,arrive(s,.65,.8)),rx:mix(6,0,arrive(s,.65,.8)),opacity:arrive(s,.65,.5),blur:mix(4,0,arrive(s,.65,.6))})}><WallpaperFrame t={t+2.3} wallpaper="lagoon" zoom/></Plate>
    <div style={{position:'absolute',left:1248,top:814,opacity:1-done,padding:'19px 28px',background:C.accent,borderRadius:13,color:'white',fontFamily:FONT,fontSize:27,boxShadow:'0 18px 55px rgba(0,0,0,.4)'}}>Apply Changes</div>
    <Chip style={{position:'absolute',left:100,top:976}}>RECORD. EDIT. SAVE TO YOUR MAC.</Chip>
  </AbsoluteFill>;
};

const End:React.FC<{t:number}>=({t})=> {
  const name=arrive(t,.23,.6),tag=arrive(t,.6,.55);
  return <AbsoluteFill style={{alignItems:'center',justifyContent:'center',fontFamily:FONT}}>
    <div style={{position:'absolute',left:892,top:214,width:136,height:136,transform:`translateY(${mix(14,0,arrive(t,0,.6))}px) scale(${mix(.9,1,arrive(t,0,.6))})`,filter:`blur(${mix(9,0,arrive(t,0,.65))}px)`,opacity:arrive(t,0,.6)}}><Img src={staticFile('assets/mark.svg')} style={{width:136,height:136}}/></div>
    <div style={{position:'absolute',top:389,left:0,right:0,textAlign:'center',fontSize:110,letterSpacing:-4,fontWeight:650,color:C.text,opacity:name,filter:`blur(${mix(8,0,name)}px)`}}>ScreenTake</div>
    <div style={{position:'absolute',top:545,left:0,right:0,textAlign:'center',fontSize:48,letterSpacing:-1.6,color:C.light,opacity:tag}}>Your screen. A better take.</div>
    <div style={{position:'absolute',top:700,left:0,right:0,textAlign:'center',fontSize:30,fontWeight:550,color:C.text,opacity:arrive(t,.95,.5)}}>Download the Mac beta</div>
    <div style={{position:'absolute',top:761,left:0,right:0,textAlign:'center',fontSize:21,color:C.muted,opacity:arrive(t,.95,.5)}}>Experimental beta · Apple Silicon · macOS 13+</div>
    <div style={{position:'absolute',top:897,left:0,right:0,textAlign:'center',fontSize:23,color:'#c7bfd7',opacity:arrive(t,1.05,.4)}}>sso-ss.github.io/ScreenTake</div>
  </AbsoluteFill>;
};

export const Scene:React.FC<{id:SceneID;t:number}>=({id,t})=> {
  const components:Record<SceneID,React.FC<{t:number}>>={Promise,Record,Zoom,Cursor,Edit,Voiceover,Frame,Result,End};
  const Component=components[id];
  return <Component t={Math.max(0,t)}/>;
};
