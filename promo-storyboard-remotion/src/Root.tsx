import React from "react";
import { AbsoluteFill, Audio, Composition, Sequence, staticFile } from "remotion";
import { Grain } from "./components/Backdrop";
import { loadFonts } from "./fonts";
import { SCENES } from "./scenes";
import { FormatContext, TL, type Format } from "./lib/time";

loadFonts();
const f = (s: number) => Math.round(s * TL.fps);
const TOTAL = f(TL.scenes[TL.scenes.length - 1].start + TL.scenes[TL.scenes.length - 1].dur);
const VERTICAL = TL.vertical.map((id) => TL.scenes.find((s) => s.id === id)!);
const VERTICAL_TOTAL = TL.vertical_edit.reduce((a, s) => a + f(s.dur), 0);

const Film: React.FC<{ format: Format }> = ({ format }) => {
  const list = format === "wide" ? TL.scenes.map((s) => ({id:s.id,in:0,dur:s.dur})) : TL.vertical_edit;
  let at = 0;
  return <FormatContext.Provider value={format}>
    <AbsoluteFill style={{ background: "#0b0b0e" }}>
      {list.map((s) => {
        const Scene = SCENES[s.id];
        const original = TL.scenes.find((x) => x.id === s.id)!;
        const from = at;
        at += f(s.dur);
        return <Sequence key={s.id} from={from} durationInFrames={f(s.dur)} name={`${s.id} ${original.name}`}>
          <Sequence from={-f(s.in)} durationInFrames={f(original.dur)} layout="none">
            {Scene ? <Scene /> : null}
          </Sequence>
        </Sequence>;
      })}
      <Grain />
      <Audio src={staticFile(format === "wide" ? "audio/score.wav" : "audio/score-vertical.wav")} />
    </AbsoluteFill>
  </FormatContext.Provider>;
};

const SceneClip: React.FC<{ id: string; format?: Format }> = ({ id, format = "wide" }) => {
  const s = TL.scenes.find((x) => x.id === id)!;
  const Scene = SCENES[id];
  return <FormatContext.Provider value={format}>
    <AbsoluteFill style={{ background: "#0b0b0e" }}>
      {Scene && <Scene />}
      <Grain />
      <Audio src={staticFile("audio/score.wav")} startFrom={f(s.start)} />
    </AbsoluteFill>
  </FormatContext.Provider>;
};

export const RemotionRoot: React.FC = () => <>
  <Composition id="ScreenTakePromo" component={Film} defaultProps={{ format: "wide" as Format }} durationInFrames={TOTAL} fps={TL.fps} width={1920} height={1080} />
  <Composition id="ScreenTakeVertical" component={Film} defaultProps={{ format: "tall" as Format }} durationInFrames={VERTICAL_TOTAL} fps={TL.fps} width={1080} height={1920} />
  {TL.scenes.map((s) => <Composition key={s.id} id={`Scene-${s.id}-${s.name}`} component={SceneClip} defaultProps={{ id: s.id }} durationInFrames={f(s.dur)} fps={TL.fps} width={1920} height={1080} />)}
  {VERTICAL.map((s) => <Composition key={s.id} id={`Tall-${s.id}-${s.name}`} component={SceneClip} defaultProps={{ id: s.id, format: "tall" as Format }} durationInFrames={f(s.dur)} fps={TL.fps} width={1080} height={1920} />)}
</>;
