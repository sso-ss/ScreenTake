import React from 'react';
import {AbsoluteFill, Img, staticFile} from 'remotion';
import {C, FONT, MONO} from './theme';
import {arrive, clamp, during, mix, pulse} from './motion';

export const Background: React.FC<{t: number; warm?: number}> = ({t, warm = 0}) => <AbsoluteFill style={{
  background: `radial-gradient(ellipse at ${42 + Math.sin(t * 0.16) * 8}% ${60 + Math.cos(t * 0.12) * 6}%, ${warm > 0.5 ? '#38223a' : '#251737'} 0%, #101019 52%, #08090e 100%)`,
}}>
  <div style={{position: 'absolute', left: 620 + Math.sin(t * .2) * 65, top: 510, width: 1120, height: 210,
    borderRadius: '50%', background: 'linear-gradient(90deg, #432d6b, #a280b3, #345b70)',
    filter: 'blur(130px)', opacity: .28, transform: `rotate(-17deg) translateY(${Math.cos(t * .16) * 40}px)`}}/>
  <AbsoluteFill style={{background: 'radial-gradient(ellipse, transparent 30%, rgba(0,0,0,.4) 100%)'}}/>
</AbsoluteFill>;

export const Brand: React.FC<{opacity?: number}> = ({opacity = 1}) => <div style={{position:'absolute',left:90,top:58,display:'flex',gap:14,alignItems:'center',opacity}}>
  <Img src={staticFile('assets/mark.svg')} style={{width:42,height:42}}/>
  <span style={{fontFamily:FONT,fontSize:29,fontWeight:650,color:C.text,letterSpacing:-.6}}>ScreenTake</span>
</div>;

export const Caption: React.FC<{t: number; text: React.ReactNode; tag?: string; x?: number; y?: number; size?: number; width?: number}> = ({t,text,tag,x=96,y=141,size=80,width=1740}) => {
  const a = arrive(t,.08,.6);
  return <div style={{position:'absolute',left:x,top:y,width,opacity:a,transform:`translateY(${mix(30,0,a)}px)`,fontFamily:FONT}}>
    {tag && <div style={{fontSize:20,color:C.muted,letterSpacing:2.6,marginBottom:13,fontFamily:MONO,textTransform:'uppercase'}}>{tag}</div>}
    <div style={{fontSize:size,fontWeight:650,lineHeight:1.06,letterSpacing:-1.8,color:C.text}}>{text}</div>
  </div>;
};

export type Pose = {x?:number;y?:number;z?:number;rx?:number;ry?:number;rz?:number;scale?:number;blur?:number;opacity?:number};
export const Plate: React.FC<{t:number;w:number;h:number;pose:(t:number)=>Pose;children:React.ReactNode;motionBlur?:boolean}> = ({t,w,h,pose,children,motionBlur=false}) => {
  const now=pose(t), prev=pose(t-1/30);
  const velocity=Math.abs((now.x??0)-(prev.x??0))+Math.abs((now.y??0)-(prev.y??0))+Math.abs((now.scale??1)-(prev.scale??1))*500;
  const samples=motionBlur && velocity>7 ? 3 : 1;
  return <AbsoluteFill style={{perspective:1900,perspectiveOrigin:'50% 50%'}}>
    {Array.from({length:samples},(_,i)=>{
      const p=pose(t + (samples===1?0:(i/(samples-1)-.5)*.018));
      return <div key={i} style={{position:'absolute',left:'50%',top:'50%',width:w,height:h,
        transform:`translate(-50%,-50%) translate3d(${p.x??0}px,${p.y??0}px,${p.z??0}px) rotateX(${p.rx??0}deg) rotateY(${p.ry??0}deg) rotateZ(${p.rz??0}deg) scale(${p.scale??1})`,
        opacity:(p.opacity??1)/(i+1),filter:(p.blur??0)>.02?`blur(${p.blur}px)`:undefined,willChange:'transform',
      }}>{children}</div>;
    })}
  </AbsoluteFill>;
};

export const Focus:React.FC<{children:React.ReactNode;blur:number;cx?:number;cy?:number;radius?:number}>=({children,blur,cx=50,cy=50,radius=38})=> {
  if(blur<.1) return <>{children}</>;
  const mask=`radial-gradient(ellipse ${radius}% ${radius*.75}% at ${cx}% ${cy}%, black 36%, transparent 100%)`;
  return <AbsoluteFill>
    <AbsoluteFill style={{filter:`blur(${blur}px)`}}>{children}</AbsoluteFill>
    <AbsoluteFill style={{maskImage:mask,WebkitMaskImage:mask}}>{children}</AbsoluteFill>
  </AbsoluteFill>;
};

export const Pointer:React.FC<{x:number;y:number;scale?:number;click?:number;circle?:boolean}>=({x,y,scale=1,click=1,circle=false})=> <div style={{position:'absolute',left:x,top:y,width:50,height:60,transform:`scale(${scale})`,transformOrigin:'5px 4px',filter:'drop-shadow(0 4px 4px rgba(0,0,0,.35))'}}>
  {click<1 && <div style={{position:'absolute',left:-37*click,top:-37*click,width:74*click,height:74*click,borderRadius:'50%',border:`${3*(1-click)+1}px solid rgba(180,166,255,${1-click})`,background:`rgba(145,120,255,${.17*(1-click)})`,transform:'translate(5px,5px)'}}/>}
  {circle ? <div style={{width:30,height:30,background:'rgba(255,255,255,.34)',border:'2px solid white',borderRadius:'50%'}}/> :
  <svg width="46" height="58" viewBox="0 0 46 58"><path d="M6 3L6 43L17 33L25 51L33 47L24 30L40 29Z" fill="#fff" stroke="#18131f" strokeWidth="2.2" strokeLinejoin="round"/></svg>}
</div>;

export const Demo:React.FC<{t:number;zoom?:boolean;raw?:boolean;pointer?:boolean;cursorScale?:number;highlight?:boolean}>=({t,zoom=false,raw=false,pointer=true,cursorScale=1,highlight=true})=> {
  const movement=during(t,1.8,.7), back=during(t,5.0,.8);
  const k=zoom?1+.65*movement*(1-back):1;
  const x=mix(932,267,during(t,.8,.8)), y=mix(538,300,during(t,.8,.8))+70*during(t,2.7,.6);
  const at=t<3?1.9:3.5;
  const clicked=t>1.9;
  return <div style={{width:1100,height:650,borderRadius:raw?8:24,overflow:'hidden',background:'#fbfafc',border:'1px solid rgba(255,255,255,.75)',boxShadow:raw?'none':'0 30px 90px rgba(0,0,0,.48)',position:'relative',fontFamily:FONT,lineHeight:1.2}}>
    <div style={{position:'absolute',inset:0,transform:`translate(${zoom?-35*movement*(1-back):0}px,${zoom?-20*movement*(1-back):0}px) scale(${k})`,transformOrigin:'42% 56%'}}>
      <div style={{height:54,display:'flex',alignItems:'center',padding:'0 25px',gap:9,borderBottom:'1px solid #ece8f0',background:'#f3f1f6'}}>
        {['#fa635b','#ffbd43','#31c84a'].map(c=><span key={c} style={{width:12,height:12,borderRadius:'50%',background:c}}/>)}
        <span style={{color:'#756d80',fontSize:17,marginLeft:27}}>Horizon · Launch checklist</span>
      </div>
      <div style={{display:'flex',height:596}}>
        <div style={{width:208,background:'#f0edf5',padding:'34px 22px',boxSizing:'border-box',borderRight:'1px solid #e7e2ed'}}>
          <div style={{fontWeight:700,fontSize:22,color:'#322740',marginBottom:40}}>Horizon</div>
          {['Overview','Projects','Launch checklist'].map((s,i)=><div key={s} style={{fontSize:17,padding:'13px 11px',marginBottom:6,borderRadius:8,color:i===2?'#5c45c5':'#77707f',background:i===2?'#e2dbf6':'transparent',fontWeight:i===2?600:400}}>{s}</div>)}
          <div style={{marginTop:200,fontSize:15,color:'#8e8599'}}>Workspace</div>
        </div>
        <div style={{flex:1,padding:'48px 54px',color:'#251b35'}}>
          <div style={{fontSize:15,letterSpacing:1.5,color:'#847393',marginBottom:17}}>PROJECT / LAUNCH</div>
          <div style={{fontSize:46,letterSpacing:-1.5,fontWeight:650,marginBottom:12}}>A clearer launch.</div>
          <div style={{fontSize:21,color:'#82748f',marginBottom:39}}>One good demo makes the next step easy.</div>
          {['Polish the demo','Record the walkthrough','Ready to share'].map((s,i)=> <div key={s} style={{height:70,display:'flex',alignItems:'center',gap:17,borderBottom:'1px solid #ece7f1'}}>
            <div style={{width:22,height:22,border:'1.5px solid #b6a4d0',borderRadius:6,background:((i===0&&clicked)||(i===1&&t>3.5))?'#6c5ce7':'transparent',color:'white',display:'flex',alignItems:'center',justifyContent:'center',fontSize:17}}>{((i===0&&clicked)||(i===1&&t>3.5))?'✓':''}</div>
            <span style={{fontSize:21}}>{s}</span><span style={{marginLeft:'auto',fontSize:14,color:'#9b8cae'}}>0{i+1}</span>
          </div>)}
          <div style={{display:'flex',alignItems:'center',justifyContent:'space-between',marginTop:25}}>
            <span style={{fontSize:16,color:'#9687a4'}}>Everything in its place.</span>
            <div style={{background:'#6c5ce7',color:'white',borderRadius:9,padding:'15px 24px',fontSize:19,fontWeight:600}}>Open preview</div>
          </div>
        </div>
      </div>
      {pointer&&<Pointer x={x} y={y} scale={raw?.7:cursorScale} click={highlight?pulse(t,at):1}/>}
    </div>
  </div>;
};

export const WallpaperFrame:React.FC<{t:number;wallpaper?:string;w?:number;h?:number;ratio?:string;zoom?:boolean;cursorScale?:number}>=({t,wallpaper='lagoon',w=1340,h=790,ratio,zoom=false,cursorScale=1})=> {
  const scale=Math.min((w-130)/1100,(h-120)/650);
  return <div style={{position:'relative',width:w,height:h,borderRadius:26,overflow:'hidden',boxShadow:'0 50px 110px rgba(0,0,0,.5)',border:'1px solid rgba(225,211,255,.18)'}}>
    <Img src={staticFile(`assets/${wallpaper}.png`)} style={{position:'absolute',width:'100%',height:'100%',objectFit:'cover'}}/>
    <div style={{position:'absolute',left:'50%',top:'50%',width:1100,height:650,transform:`translate(-50%,-50%) scale(${scale})`}}><Demo t={t} zoom={zoom} cursorScale={cursorScale}/></div>
    {ratio&&<div style={{position:'absolute',bottom:16,left:0,right:0,textAlign:'center',fontFamily:MONO,fontSize:16,color:'#f9f8fc',letterSpacing:2}}>{ratio}</div>}
  </div>;
};

export const NativeEditor:React.FC<{t:number;focus?:number;preview?:boolean}>=({t,focus=0,preview=true})=> {
  const contents=<AbsoluteFill>
    <Img src={staticFile('assets/editor.png')} style={{width:1400,height:850}}/>
    {preview&&<div style={{position:'absolute',left:129,top:118,width:773,height:483,overflow:'hidden',background:'#b7a3dd'}}>
      <div style={{position:'absolute',inset:0,background:'linear-gradient(130deg,#ded3f6,#8e77bf)'}}/>
      <div style={{position:'absolute',left:43,top:39,width:1100,height:650,transform:'scale(.624)',transformOrigin:'0 0'}}><Demo t={t+2} pointer/></div>
    </div>}
  </AbsoluteFill>;
  return <div style={{width:1400,height:850,position:'relative',borderRadius:14,overflow:'hidden',boxShadow:'0 48px 110px rgba(0,0,0,.55)',border:'1px solid rgba(255,255,255,.17)'}}>
    <Focus blur={focus} cx={42} cy={86} radius={57}>{contents}</Focus>
  </div>;
};

export const Wave:React.FC<{width:number;height:number;seed?:number;color?:string}> = ({width,height,seed=1,color=C.accent})=> <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
  {Array.from({length:Math.floor(width/5)},(_,i)=>{const a=.2+.8*Math.abs(Math.sin(i*.29+seed)*Math.cos(i*.13+seed));return <rect key={i} x={i*5} y={(height-height*a)/2} width={2.2} height={height*a} rx={1.1} fill={color}/>;})}
</svg>;

export const DetailCrop:React.FC<{file?:string;x:number;y:number;w:number;h:number;scale?:number;radius?:number}>=({file='editor.png',x,y,w,h,scale=1,radius=16})=> <div style={{width:w*scale,height:h*scale,overflow:'hidden',position:'relative',borderRadius:radius,background:'#262628',border:'1px solid rgba(255,255,255,.14)',boxShadow:'0 30px 80px rgba(0,0,0,.55)'}}>
  <Img src={staticFile(`assets/${file}`)} style={{position:'absolute',width:1400*scale,height:850*scale,left:-x*scale,top:-y*scale}}/>
</div>;

export const RevealLine:React.FC<{t:number;children:React.ReactNode}> = ({t,children})=> <div style={{opacity:clamp(t/.45),transform:`translateY(${mix(24,0,arrive(t,0,.55))}px)`}}>{children}</div>;
