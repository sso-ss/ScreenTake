import type React from "react";
import { S01Open } from "./S01Open";
import { S02Title } from "./S02Title";
import { S03Record } from "./S03Record";
import { S04Zoom } from "./S04Zoom";
import { S05Cursor } from "./S05Cursor";
import { S06Camera } from "./S06Camera";
import { S07Edit } from "./S07Edit";
import { S08Frame } from "./S08Frame";
import { S09End } from "./S09End";

export const SCENES: Record<string, React.FC> = {
  s01: S01Open,
  s02: S02Title,
  s03: S03Record,
  s04: S04Zoom,
  s05: S05Cursor,
  s06: S06Camera,
  s07: S07Edit,
  s08: S08Frame,
  s09: S09End,
};
