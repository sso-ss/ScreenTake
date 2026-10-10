import React from "react";
import { AbsoluteFill } from "remotion";
import { AppWindow, WIN } from "../components/AppWindow";
import { Backdrop } from "../components/Backdrop";
import { Group, MotionBlur, Plane, Space } from "../components/Space";
import { FlyText } from "../components/Type";
import { C } from "../lib/theme";
import { easeInCubic, easeInOutCubic, easeOutExpo, lerp, prog } from "../lib/motion";
import { cues, useTime } from "../lib/time";

// The window recedes out of focus; the letters arrive from the near plane.
const T = cues("s02");
const World: React.FC = () => {
  const t=useTime();
  const drift=easeInOutCubic(prog(t,0,3.4));
  const drop=easeOutExpo(prog(t,0,.75));
  const fly=easeInCubic(prog(t,T.through,.6));
  const textOut=easeInCubic(prog(t,T.through+.25,.3));
  return <Space camera={{rx:lerp(5,-2,drift),ry:lerp(-7,5,drift),dolly:lerp(-80,160,drift)+1250*fly,focus:0,aperture:2.3}}>
    <Plane w={WIN.w} h={WIN.h} z={lerp(-60,-440,drop)} ry={-8} s={1.2} opacity={.36} blur={4}>
      <AppWindow wall="midnight" />
    </Plane>
    <Group y={-88}><FlyText text="Your screen." t={t} t0={T.line1} size={168} from={600} out={textOut*400} /></Group>
    <Group y={100}><FlyText text="A better take." t={t} t0={T.line2} size={168} from={600} color={C.accentLight} out={textOut*400} /></Group>
  </Space>;
};
export const S02Title: React.FC = () => {
  const t=useTime();
  const fade=1-easeInCubic(prog(t,3.75,.25));
  return <AbsoluteFill>
    <Backdrop wall="midnight" wallOpacity={.22} blur={55} glow={.8}/>
    <AbsoluteFill style={{opacity:fade}}>
      <MotionBlur under={<Backdrop wall="midnight" wallOpacity={.22} blur={55} glow={.8}/>} active={t>T.through+.05} samples={7} shutter={.022}><World/></MotionBlur>
    </AbsoluteFill>
  </AbsoluteFill>;
};
